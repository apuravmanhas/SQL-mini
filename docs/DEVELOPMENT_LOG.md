# VerityTick — Development Log

## 2026-10-22 — Project Initialization

### Environment Discovery
- Windows 11, PostgreSQL 18.6 native install, Python 3.12.6
- No Docker, no make, no GitHub CLI
- Repository was empty (freshly created on GitHub)

### Decisions
1. **Name: VerityTick** — "Verity" (truth/integrity) + "Tick" (market data unit). Clean, meaningful, not generic.
2. **No Docker dependency** — PostgreSQL runs natively, so Docker is unnecessary overhead for this setup.
3. **Python scripts instead of Makefile** — `make` is unavailable on this Windows system. Using `tools/setup_db.py` and pytest as the primary developer interface.
4. **PostgreSQL 18** — Latest stable release, already installed. Using native features including PL/pgSQL, pgcrypto, RLS, declarative partitioning.

### Work Completed
- Repository cloned and inspected (empty)
- Environment verified: Git, Python, PostgreSQL all functional
- Created .gitignore, .editorconfig, .env.example
- Created README.md, LICENSE
- Created documentation structure
- Installed psycopg2-binary and pytest
