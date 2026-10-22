# VerityTick

**PostgreSQL Market Integrity, Transactional Trading & Fraud Analytics Engine**

*Every order accounted for. Every ledger movement balanced. Every suspicious pattern explainable. Every performance claim measurable.*

---

## What This Is

VerityTick is a PostgreSQL-centered simulation of a financial-market data platform. It demonstrates serious database engineering — not just CRUD, but transactional order matching, double-entry accounting, tamper-evident audit trails, recursive fraud detection, time-series analytics, and tenant-isolated security.

**This is a simulated educational engineering system, not a live financial exchange.**

### Core Capabilities

| Module | What It Does |
|--------|-------------|
| **Trading Engine** | Accept limit orders, match them under price-time priority, handle partial fills and cancellations — all inside PostgreSQL transactions |
| **Financial Ledger** | Immutable double-entry accounting with atomic postings, balance reservations, and independent reconciliation |
| **Audit Chain** | Hash-chained event history using pgcrypto with tamper detection and external checkpoint verification |
| **Fraud Analytics** | Recursive SQL cycle detection for suspicious circular transfers with explainable alerts |
| **Market Data** | Partitioned tick ingestion, OHLCV candlestick aggregation (1m/5m/1h), incremental updates with late-data handling |
| **Security** | Row-Level Security, tenant isolation, least-privilege roles — tested with negative cases |

### Key Engineering Challenges

- Concurrent order matching that preserves price-time priority (per-market serialization)
- Financial ledger immutability enforced at the database level, not just application convention
- Recursive CTEs with bounded depth, time-window constraints, and cycle detection
- Time-series partitioning with correct incremental vs. full recomputation
- Multi-tenant security tested under actual restricted database roles

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Database | PostgreSQL 18 |
| Core Logic | SQL + PL/pgSQL |
| Crypto | pgcrypto extension |
| Migrations | Versioned forward-only SQL |
| Testing | Python + pytest + psycopg2 |
| Data Generation | Deterministic Python tools |

## Prerequisites

- PostgreSQL 18 (running locally or via Docker)
- Python 3.12+
- Git

## Quick Start

```bash
# Clone
git clone https://github.com/apuravmanhas/SQL-mini.git
cd SQL-mini

# Configure
cp .env.example .env
# Edit .env with your PostgreSQL credentials

# Install Python dependencies
pip install -e ".[dev]"

# Create database and apply migrations
python tools/setup_db.py

# Run tests
pytest tests/ -v

# Run demo
python tools/demo.py
```

## Project Structure

```
├── db/
│   ├── migrations/       # Versioned SQL migrations
│   ├── seed/             # Development fixtures
│   └── tests/            # SQL-level tests
├── tools/                # Python utilities
├── tests/                # Integration & concurrency tests
└── docs/                 # Architecture, decisions, status
```

## Current Status

See [docs/PROJECT_STATUS.md](docs/PROJECT_STATUS.md) for detailed implementation status.

## Known Limitations

See [docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md).

## License

MIT — see [LICENSE](LICENSE).
