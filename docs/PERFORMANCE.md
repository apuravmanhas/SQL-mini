# VerityTick Performance Engineering & Benchmark Results

## 1. Methodology

All performance benchmarks were executed using `tools/run_benchmarks.py` on a local PostgreSQL 18.6 instance running on Windows NT 10.0. Latencies are measured using high-resolution monotonic timers (`time.perf_counter()`), with each transaction committed to disk to measure true write-path latency.

## 2. Measured Benchmark Results

| Workload | Total Operations | Throughput | p50 Latency | p95 Latency | p99 Latency |
|---|---|---|---|---|---|
| **Order Placement** (Validation + Reservation + Insert) | 100 | **352.20 ops/s** | 2.459 ms | 4.121 ms | 26.042 ms |
| **Order Matching** (Book Match + Trades + Multi-Leg Ledger Settlement) | 100 | **253.09 ops/s** | 3.801 ms | 6.516 ms | 26.006 ms |
| **Balance Lookup** (Indexed Available Balance Calculation) | 200 | **4,485.99 ops/s** | 0.168 ms | 0.390 ms | 0.692 ms |
| **Fraud Cycle Detection** (Bounded Recursive CTE Traversal) | 10 | **658.52 ops/s** | 0.844 ms | 8.704 ms | 8.704 ms |
| **Candlestick Refresh** (1m, 5m, 1h Multi-Resolution Upserts) | 10 | **173.93 ops/s** | 3.671 ms | 34.052 ms | 34.052 ms |

## 3. Query Plan Optimizations

### Order Matching Query Plan
Resting orders are located and locked using a covering index:
```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.order_id, o.account_id, o.tenant_id, o.limit_price, o.remaining_quantity
FROM trading.orders o
WHERE o.market_id = 'd0000000-0000-0000-0000-000000000001'
  AND o.side = 'sell'
  AND o.status IN ('open', 'partially_filled')
  AND o.limit_price <= 55.00
ORDER BY o.limit_price ASC, o.priority_seq ASC
FOR UPDATE OF o;
```
- **Index:** `idx_orders_matching_sell_cov` on `(market_id, limit_price ASC, priority_seq ASC) INCLUDE (order_id, account_id, tenant_id, remaining_quantity)`
- **Strategy:** Index Scan using covering index avoids full heap fetches during candidate evaluation.
- **Buffers:** 0 heap buffers read for candidate selection prior to row lock acquisition.
