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

## Running Tests

```bash
# Full test suite (73 tests, ~2–4 seconds)
pytest tests/ -v

# Specific module
pytest tests/test_matching.py -v
pytest tests/test_audit.py -v
pytest tests/test_security.py -v

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
