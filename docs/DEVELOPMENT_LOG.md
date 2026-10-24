# VerityTick — Development Log

## 2026-10-22 — Project Initialization & Complete Architecture Delivery

### Environment Discovery
- Windows 11, PostgreSQL 18.6 native install, Python 3.12.6.
- GitHub repository cloned and verified empty.
- Verified credentials and kept local connection string isolated strictly in `.env`.

### Key Architectural Decisions
1. **Identity & Scope:** Named **VerityTick** — "Verity" (truth/integrity) + "Tick" (market data unit). Built as a portfolio-grade systems project.
2. **Per-Market Serialization:** Implemented row-level lock on `core.markets` for atomic priority sequencing and race-condition prevention across concurrent order submissions.
3. **Double-Entry Financial Ledger:** Every trade execution atomizes into balanced transfer legs between buyer and seller reservation/trading accounts.
4. **Audit Hash Chain:** Leveraged PostgreSQL `pgcrypto` to calculate SHA-256 event digests linked by sequence.
5. **Recursive Graph CTEs:** Traversed transfer edges using bounded recursive queries to detect circular money laundering rings.
6. **Partitioned Time-Series:** Range partitioned ticks by month with deterministic identity sequences for exact OHLCV rollups.
7. **Database Role Boundaries:** Enforced Row-Level Security with fail-closed behavior for `vt_app` and `vt_readonly`.

### Engineering Iteration Summary
- V001..V002: Initial schemas, extensions, tenant foundations, 23 constraint tests.
- V003..V005c: Order matching engine with price-time priority, double-entry settlement, 24 tests.
- V006..V007: Cryptographic audit log and recursive CTE fraud detection, 8 audit tests + 7 fraud tests.
- V008..V008b: Monthly partitioned ticks, deterministic tick sequences, 1m/5m/1h candle aggregations, 5 market data tests.
- V009: Row-level security and restricted database roles, 6 security tests.
- V010: Covering indexes for matching and time-series traversal.
- Benchmark and demo tools (`tools/run_benchmarks.py`, `tools/demo.py`).
- Automated CI pipeline (`.github/workflows/ci.yml`).
- Full test suite: **73/73 tests passing**.
- Automated test suite isolation: Configured `veritytick_test` database provisioning in `tools/setup_db.py` and `tests/conftest.py` so benchmark workloads and interactive demos on `veritytick` run independently without state pollution.

## 2026-10-24 — Deep Verification Audit & Hardening (V011–V013)

### Findings & Fixes
1. **Sequence Privileges (`V011`):** Granted `USAGE` on all sequences in `core`, `trading`, `ledger`, `audit`, `risk`, and `market_data` to `vt_app`.
2. **Execution Boundary & Privilege Hardening (`V012`):**
   - `vt_app` previously lacked `UPDATE` on `ledger.accounts` while calling `SECURITY INVOKER` functions, yet had direct `INSERT`/`UPDATE` on engine tables.
   - Wrapped `trading.place_order`, `trading.cancel_order`, and `audit.append_event` as `SECURITY DEFINER` entrypoints (`SET search_path = pg_catalog, public`) guarded by `core.assert_tenant_access(p_tenant_id)`.
   - Revoked direct `INSERT, UPDATE, DELETE` on engine-owned tables from `vt_app` and revoked `EXECUTE` on operator/internal functions (`ledger.deposit`, `ledger.post_transfer`, `*_core`, etc.) from `PUBLIC, vt_app, vt_readonly`.
3. **Automatic Audit Chain Wiring (`V012`):** Connected `trading.place_order` and `trading.cancel_order` to `audit.append_event_core` so every order placement, rejection, and cancellation is automatically hash-chained.
4. **Self-Trade Prevention (`V012`):** Added pre-match check in `trading.place_order_core` to reject orders that would cross the same trading account's resting orders (`status = 'rejected'`), preventing raw `chk_different_accounts` constraint exceptions.
5. **Independent Ledger Reconciliation (`V012`):** Implemented `ledger.reconcile_balances(p_tenant_id)` and `ledger.check_conservation()` to verify account balances against immutable journal entries and verify zero-sum asset conservation.
6. **Dynamic Tick Partitioning & RLS Completion (`V012`):** Added `market_data.ensure_tick_partition(p_ts)` so `ingest_trade_tick` auto-provisions monthly partitions outside the initial window; enabled RLS on `audit.chain_state` and `risk.transfer_edges`.
7. **Query Plan Verification & Redundant Index Cleanup (`V013`):** Verified `EXPLAIN (ANALYZE, BUFFERS)` on a 500,000-row order book. Because `FOR UPDATE` locks heap rows, PostgreSQL uses the partial index `idx_orders_sell_book` / `idx_orders_buy_book` (`V003`) rather than `V010`'s covering indexes. Dropped the redundant `idx_orders_matching_sell_cov` and `idx_orders_matching_buy_cov` indexes in `V013` and updated `docs/PERFORMANCE.md` with exact measured buffer counts.
8. **Expanded Verification Suite:** Added `tests/test_hardening.py` (34 tests) and `tests/test_concurrency.py` (7 multi-threaded concurrency tests), bringing the total suite to **114/114 tests passing**.
