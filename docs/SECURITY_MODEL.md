# VerityTick Security Architecture & Threat Model

## 1. Principle of Least Privilege

VerityTick strictly separates administrative schema management from operational workloads:

- **`postgres` (Migration & Schema Owner):**
  Owns DDL definitions, runs versioned forward migrations, bypasses RLS for system-level maintenance.
- **`vt_app` (Application Execution Role):**
  Restricted to executing PL/pgSQL routines, inserting and updating orders, and creating audit entries. Explicitly denied `UPDATE` and `DELETE` on posted financial ledger records (`ledger.journals`, `ledger.entries`).
- **`vt_readonly` (Reporting & Audit Role):**
  Strictly `SELECT`-only privileges across all business namespaces.

## 2. Row-Level Security (RLS) Policy Design

Tenant isolation is enforced by the PostgreSQL query planner using Row-Level Security:

$$\text{Visible Rows} = \{ r \in \text{Table} \mid r.\text{tenant\_id} = \text{core.current\_tenant\_id}() \}$$

### Session Context Propagation
The application pool establishes tenant identity at connection checkout:
```sql
SET LOCAL app.current_tenant_id = 'a0000000-0000-0000-0000-000000000001';
```

### Fail-Closed Behavior
If `app.current_tenant_id` is missing, malformed, or unset, `core.current_tenant_id()` evaluates to `NULL`. Since `NULL = tenant_id` yields `UNKNOWN`, the policy evaluates to false, returning zero rows.

## 3. Threat Model & Mitigations

| Threat | Attack Vector | Mitigation in VerityTick |
|---|---|---|
| Cross-Tenant Leakage | Malicious tenant queries or joins another tenant's data | Database-enforced Row-Level Security policies active on all tenant-owned tables. Tested with negative automated test suites. |
| Ledger Tampering | Modifying posted historical balances or erasing audit entries | `vt_app` role has `REVOKE UPDATE, DELETE ON ledger.journals, ledger.entries`. Financial postings are append-only. |
| Self-Trading Wash Manipulation | Submitting matching buy/sell orders between the same account | Exclusion and check constraint `chk_different_accounts` (`buy_account_id != sell_account_id`) on `trading.trades`. |
| Audit Trail Erasure | Modifying audit events to cover unauthorized transactions | Cryptographic SHA-256 hash chaining via `pgcrypto`. Modification breaks sequence hash and causes `audit.verify_chain()` to fail. |
| Stored Credential Leakage | Committing database passwords to version control | `.env` is strictly gitignored. Passwords passed via environment variables only. |
