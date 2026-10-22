# ADR 0001: Per-Market Serialization for Order Book Concurrency

## Context
A financial matching engine must guarantee strict price-time priority. If two buyers simultaneously match against the best resting ask, concurrent updates without synchronization can lead to overfills, race conditions, or violation of time priority.

## Decision
We implement transactional per-market serialization by acquiring an exclusive row-level lock on `core.markets` (`SELECT ... FOR UPDATE`) at the start of `trading.place_order` and `trading.cancel_order`.

## Consequences
- **Correctness:** 100% price-time priority preservation without phantom fills.
- **Independence:** Distinct markets (e.g. `ACME/USDX` and `BOLT/USDX`) operate completely in parallel without blocking each other.
- **Throughput:** Serializes orders within a single market to ~250–350 ops/second on standard hardware.
