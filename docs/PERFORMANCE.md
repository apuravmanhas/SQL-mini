# VerityTick Performance Notes

Everything here was measured on one Windows development machine with a native PostgreSQL 18.6 instance,
default configuration, client and server on the same host. Treat the numbers as relative, not portable.

## 1. Method

`tools/run_benchmarks.py --orders 100` drives the engine through the public functions with one connection,
committing after every call, and times each call with `time.perf_counter()`. Throughput is
`operations / sum(latencies)`, so it reflects a single sequential client, not peak server capacity.

Order placement and matching include the audit-chain append that `place_order` performs.

## 2. Results

Run on a freshly reset database (`python tools/setup_db.py --reset --seed`), one run:

| Workload | Operations | Throughput | p50 | p95 | p99 |
|---|---|---|---|---|---|
| Order placement (validate, reserve, insert, audit) | 100 | 326 ops/s | 2.50 ms | 5.21 ms | 38.10 ms |
| Order matching (match, trades, multi-leg settlement, audit) | 100 | 276 ops/s | 3.52 ms | 5.33 ms | 15.60 ms |
| Balance lookup | 200 | 3,734 ops/s | 0.25 ms | 0.42 ms | 0.63 ms |
| Fraud cycle detection | 10 | 630 ops/s | 0.81 ms | 9.66 ms | 9.66 ms |
| Candle refresh (1m, 5m, 1h) | 10 | 140 ops/s | 4.43 ms | 41.37 ms | 41.37 ms |

Run-to-run variation is large. Across several runs on the same machine, placement ranged from about 240
to 400 ops/s and p99 from 17 ms to 60 ms. With 10 samples, the p95 and p99 of the last two rows are just
the slowest one or two calls.

### What these numbers do not show

- **Fraud detection ran on a near-empty graph.** The benchmark does not build a large transfer graph, so
  the figure says nothing about how the recursive CTE scales. Depth and time-window bounds are tested for
  correctness in `tests/test_fraud.py`, not for performance.
- **Candle refresh** was run over a handful of ticks.
- **Concurrency throughput is not measured.** `tests/test_concurrency.py` checks correctness under
  contention (8 threads, 200 orders) but does not report throughput.

## 3. Order-book lookup plan

The matching loop picks resting orders with a query shaped like this (shown with `LIMIT 5` so it
reflects what a fill needs):

```sql
SELECT o.order_id, o.account_id, o.tenant_id, o.limit_price, o.remaining_quantity
FROM trading.orders o
WHERE o.market_id = :market
  AND o.side = 'sell'
  AND o.status IN ('open', 'partially_filled')
  AND o.limit_price <= :price
ORDER BY o.limit_price ASC, o.priority_seq ASC
LIMIT 5
FOR UPDATE OF o;
```

Checked with `EXPLAIN (ANALYZE, BUFFERS)` on a scratch database holding 500,000 orders (300,000 resting
sells, 200,000 filled buys):

| Limit price | Plan | Buffers | Execution |
|---|---|---|---|
| 50.05 | `LockRows` over `Index Scan using idx_orders_sell_book` | hit 10, read 3 | 0.20 ms |
| 55.00 | `LockRows` over `Index Scan using idx_orders_sell_book` | hit 13 | 0.06 ms |

Two things follow from that:

- The planner uses the partial indexes from V003 (`idx_orders_sell_book`, `idx_orders_buy_book`). The
  lookup reads heap pages, as it must: `FOR UPDATE` needs the tuple, so an index-only scan is not possible.
- V010 had added `idx_orders_matching_*_cov` indexes with the same key columns and predicates. They were
  never chosen and only added write cost, so V013 drops them.

On the 116-row dev database the same query uses a sequential scan, which is the correct choice at that size.

## 4. Reproducing

```powershell
python tools/setup_db.py --reset --seed
python tools/run_benchmarks.py --orders 100
```

For the plan check, load synthetic rows into a scratch database and run the query above under
`EXPLAIN (ANALYZE, BUFFERS)`. Rows must satisfy the `orders` check constraints (a `filled` order must have
`remaining_quantity = 0`).
