# VerityTick — Test Strategy

## Test Layers

### Layer 1: Schema Validation
- **What:** Constraints, foreign keys, nullability, uniqueness, migration correctness
- **How:** SQL tests executed via psycopg2, attempting invalid inserts/updates
- **Location:** `tests/test_schema.py`

### Layer 2: SQL Function Tests
- **What:** Direct calls to PL/pgSQL functions, verifying return values and state changes
- **How:** pytest with psycopg2, each test in a transaction that rolls back
- **Location:** `tests/test_functions.py`

### Layer 3: Integration Tests
- **What:** Multi-table operations — order → match → trade → ledger → audit
- **How:** pytest with real PostgreSQL, deterministic fixtures
- **Location:** `tests/integration/`

### Layer 4: Concurrency Tests
- **What:** Multiple database connections with overlapping transactions
- **How:** Python threading/multiprocessing with separate psycopg2 connections
- **Location:** `tests/concurrency/`

### Layer 5: Security Tests
- **What:** RLS policies, role restrictions, cross-tenant isolation
- **How:** Connect as restricted roles, attempt forbidden operations
- **Location:** `tests/security/`

### Layer 6: Recovery Tests
- **What:** Transaction rollback on failure, state consistency after errors
- **How:** Inject failures mid-transaction, verify clean rollback
- **Location:** `tests/recovery/`

### Layer 7: Performance Tests
- **What:** Reproducible benchmarks with measured latency and throughput
- **How:** Python workload generators with timing instrumentation
- **Location:** `tests/benchmarks/`

### Layer 8: End-to-End Demo
- **What:** Complete scenarios from order placement through fraud detection
- **How:** Scripted demo with visible output
- **Location:** `tools/demo.py`

## Test Conventions

- Each test uses a fresh transaction that rolls back (unless testing committed state)
- Deterministic seeds for reproducibility
- Tests must not depend on prior test execution order
- Failed tests must produce actionable error messages
- Skipped tests are explicitly marked with reasons

## Running Tests

```bash
# All tests
pytest tests/ -v

# Specific layer
pytest tests/test_schema.py -v
pytest tests/integration/ -v
pytest tests/concurrency/ -v

# With coverage
pytest tests/ --cov=tools --cov-report=term-missing
```
