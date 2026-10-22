# Security Policy

## Scope

VerityTick is an educational simulation project. It is **not** a production financial system and should not be used to process real financial transactions.

## Reporting Vulnerabilities

If you discover a security issue in the project's educational code, please open a GitHub issue describing the problem. Since this is not a production system, there is no need for private disclosure.

## What We Care About

Even as an educational project, we take these seriously:

- **No credentials in the repository** — `.env` files are gitignored
- **SQL injection prevention** — parameterized queries only
- **Database role separation** — least-privilege access patterns
- **Tenant isolation** — tested with negative cases

## What This Project Does NOT Provide

- Production-grade authentication or authorization
- Encrypted connections (configure at the PostgreSQL level)
- Rate limiting or DDoS protection
- Regulatory compliance
- Financial data protection beyond database-level access controls
