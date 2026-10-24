# VerityTick — Test Strategy

## Test Architecture

All automated tests live in the `tests/` directory and run against a dedicated, isolated
`veritytick_test` database that is automatically provisioned, migrated, and seeded at the
start of each test session. Each test runs inside a transaction savepoint that rolls back
after completion, preventing state leakage between tests.

## Test Coverage by Module

### Schema Validation (23 tests) — `tests/test_schema.py`
- Constraints, foreign keys, nullability, uniqueness, tenant ownership enforcement
- Negative tests: invalid status values, duplicate unique keys, cross-tenant FK mismatches

### Order Matching Engine (24 tests) — `tests/test_matching.py`
- Order validation: rejected for bad market, halted market, wrong tenant, zero price/qty, insufficient balance
- Matching mechanics: exact match, partial fill, multiple counterparties, no-match scenarios
- Price-time priority: best price filled first, FIFO at same price, execution at resting price
- Cancellation: cancel open, cancel partial, cannot cancel filled, cancelled orders excluded from matching
- Idempotency: duplicate idempotency key rejection
- Ledger integrity: post-trade balance verification, reservation release on cancel, negative balance prevention

### Cryptographic Audit Chain (8 tests) — `tests/test_audit.py`
- Append event, chain growth, hash linkage between consecutive events
- Verification of valid chain, tampered event detection, broken link detection
- External checkpoint export, tenant chain separation

### Fraud Detection (7 tests) — `tests/test_fraud.py`
- Transfer edge syncing from executed trades
- Recursive cycle detection: circular trades, no false positives on non-circular trades
- Depth limit enforcement on recursive CTE traversal
- Alert generation, idempotency, and evidence payload verification

### Market Data & Candlesticks (5 tests) — `tests/test_market_data.py`
- Trade tick ingestion and deduplication
- 1-minute OHLCV candle computation from raw ticks
- Refresh idempotency (re-running produces same result)
- Empty period produces no spurious candle

### Row-Level Security (6 tests) — `tests/test_security.py`
- Fail-closed: no rows visible without tenant context
- Tenant isolation: Apex sees own accounts, Meridian cannot see Apex data
- Cross-tenant order hiding
- Ledger immutability: app role cannot UPDATE posted journals or DELETE ledger entries

### Privilege Hardening, Audit Wiring & Reconciliation (34 tests) — `tests/test_hardening.py`
- `vt_app` execution boundary: `vt_app` can call `trading.place_order`, `trading.cancel_order`, and `audit.append_event` for its active tenant, and is rejected on cross-tenant or unset-tenant calls
- Direct table write revocation: `vt_app` cannot directly `INSERT`/`UPDATE`/`DELETE` on `trading.orders`, `trading.trades`, `ledger.accounts`, `ledger.journals`, `ledger.entries`, `audit.events`, `audit.chain_state`, `risk.transfer_edges`, or `market_data` tables
- Operator function revocation: `vt_app` cannot call `ledger.deposit`, `ledger.post_transfer`, `risk.sync_trade_edges`, `risk.generate_alerts`, `market_data.ingest_trade_tick`, `market_data.refresh_candles`, or `*_core` internal functions
- Automatic audit chain wiring: placing, rejecting, and cancelling orders automatically append cryptographic hash-chained events (`order_placed`, `order_rejected`, `order_cancelled`) verified by `audit.verify_chain`
- Self-trade prevention: crossing one's own resting order returns `status = 'rejected'` and logs `order_rejected` without crashing or altering the resting order
- Independent ledger reconciliation: `ledger.reconcile_balances()` detects balance drift and `ledger.check_conservation()` verifies zero-sum asset conservation across all accounts
- Dynamic tick partitioning: `market_data.ingest_trade_tick` automatically provisions future/past monthly partitions via `market_data.ensure_tick_partition`
- Complete RLS coverage on `audit.chain_state` and `risk.transfer_edges`

### Multi-Threaded Concurrency (7 tests) — `tests/test_concurrency.py`
- Resting order race: 2 concurrent threads competing for a single 10-share resting order result in exactly 10 shares filled, zero negative balances, and reconciled ledger state
- 8-thread 200-order concurrent storm: random buy/sell orders across 4 accounts verified for:
  - Ledger balance reconciliation (`ledger.reconcile_balances()`)
  - Asset conservation across all accounts (`ledger.check_conservation()`)
  - Exact reservation matching against open order remaining quantities
  - Valid trade execution prices within buyer/seller limit bounds
  - Uncrossed final order book (`best_bid < best_ask`)
  - Intact SHA-256 audit hash chain under concurrent appends (`audit.verify_chain()`)

## Running Tests

```bash
# Full test suite (114 tests, ~11 seconds)
pytest tests/ -v

# Specific module
pytest tests/test_matching.py -v
pytest tests/test_hardening.py -v
pytest tests/test_concurrency.py -v

# With short traceback
pytest tests/ --tb=short
```

## Test Isolation Mechanism

```
┌─────────────────────────────────────────────────┐
│  pytest session start                           │
│  ├─ conftest.setup_test_database (session)      │
│  │   └─ run_setup(veritytick_test, reset, seed) │
│  ├─ db_connection (session) → veritytick_test   │
│  └─ per-test:                                   │
│      ├─ SAVEPOINT test_savepoint                │
│      ├─ test execution                          │
│      └─ ROLLBACK (to savepoint)                 │
└─────────────────────────────────────────────────┘
```

Benchmarks and demos operate on the `veritytick` development database and never interfere
with the test database.
