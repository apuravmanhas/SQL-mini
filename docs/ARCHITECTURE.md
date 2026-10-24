# VerityTick Architecture Specification

## 1. System Overview

VerityTick is an engineered PostgreSQL database engine simulating a high-integrity financial trading and market data platform. Core transactional logic, ledger balancing, tamper-evident audit hashing, recursive graph fraud analysis, and time-series aggregation run directly inside PostgreSQL using declarative schemas, constraints, indexes, and PL/pgSQL functions.

```mermaid
flowchart TD
    Client["Client / Application Layer"] -->|Place Order / Cancel| TradingEngine["trading.place_order() / cancel_order()"]
    Client -->|Query Candles| MarketData["market_data.candles_1m/5m/1h"]
    Client -->|Audit Verification| AuditVerification["audit.verify_chain()"]
    Client -->|Fraud Analysis| RiskAnalytics["risk.detect_cycles() / generate_alerts()"]

    subgraph PostgreSQL Database Boundaries
        TradingEngine -->|1. Market Row Lock| CoreMarket["core.markets (FOR UPDATE)"]
        TradingEngine -->|2. Balance Check & Lock| LedgerReserve["ledger.accounts (reservation)"]
        TradingEngine -->|3. Match Resting Orders| OrderBook["trading.orders (Priority Sequence)"]
        TradingEngine -->|4. Create Trade| Trades["trading.trades"]
        TradingEngine -->|5. Settle Trade| LedgerEntries["ledger.journals & ledger.entries"]
        TradingEngine -->|6. Record Events| OrderEvents["trading.order_events"]

        Trades -->|Ingest Ticks| TickStore["market_data.ticks (Monthly Range Partitioned)"]
        TickStore -->|Incremental Refresh| MarketData

        Trades -->|Transfer Graph Projection| TransferEdges["risk.transfer_edges"]
        TransferEdges -->|Recursive CTE Traversal| RiskAnalytics
        RiskAnalytics -->|Idempotent Alerts| RiskAlerts["risk.alerts"]

        TradingEngine -->|Append Audit Event| AuditEvents["audit.events (SHA-256 Hash Chained)"]
        AuditEvents -->|Head State Update| AuditState["audit.chain_state"]
    end
```

## 2. Namespace & Schema Separation

| Schema | Responsibility | Key Tables & Interfaces |
|---|---|---|
| `core` | Multi-tenant definitions, users, assets, market parameters, priority sequences, tenant context guard | `tenants`, `users`, `assets`, `markets`, `trading_accounts`, `assert_tenant_access()` |
| `trading` | Limit order book, execution events, trade settlements, matching engine | `orders`, `order_events`, `trades`, `place_order()`, `cancel_order()` |
| `ledger` | Double-entry accounting, immutable journals, balanced transfer legs, reconciliation | `accounts`, `journals`, `entries`, `post_transfer()`, `available_balance()`, `reconcile_balances()`, `check_conservation()` |
| `audit` | Cryptographic SHA-256 hash-chained event trail, checkpoint verification | `chain_state`, `events`, `append_event()`, `verify_chain()`, `export_checkpoint()` |
| `risk` | Materialized transfer graph, recursive cycle analysis, alert generation | `transfer_edges`, `alerts`, `detect_cycles()`, `generate_alerts()` |
| `market_data` | Time-series tick ingestion, dynamic range partitioning, OHLCV rollups | `ticks` (partitioned), `candles_1m`, `candles_5m`, `candles_1h`, `ensure_tick_partition()`, `refresh_candles()` |

## 3. Concurrency & Transactional Invariants

### Per-Market Serialization Protocol
To guarantee strict price-time priority without race conditions or skipping resting orders, `trading.place_order()` and `trading.cancel_order()` acquire an exclusive row lock on the corresponding row in `core.markets` (`SELECT ... FOR UPDATE`).
- **Granularity:** Per market (e.g., `ACME/USDX` locks independently of `BOLT/USDX`).
- **Advantage:** Guarantees deterministic atomic priority sequence assignment (`next_priority_seq`) and prevents phantom fills or crossed book anomalies without global database lock bottlenecks.
- **Settlement:** All matching executions and double-entry ledger transfers occur synchronously within the same atomic transaction. Failure at any point rolls back order placement, matching, and fund reservations entirely.
