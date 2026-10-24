# VerityTick Security Architecture & Threat Model

## 1. Roles and Privileges

| Role | Purpose | What it can do |
|---|---|---|
| `postgres` (owner) | Migrations, operations, batch jobs | Everything. Superusers bypass RLS and the tenant guard. |
| `vt_app` | Interactive trading API | Call `trading.place_order`, `trading.cancel_order`, `audit.append_event`; `SELECT` on business tables (RLS applies); triage updates on `risk.alerts`; manage `core.users` and `core.trading_accounts` rows |
| `vt_readonly` | Reporting and audit | `SELECT` only (RLS applies). No function execution on the engine API. |

### How `vt_app` reaches engine-owned tables

`vt_app` has no `INSERT`, `UPDATE` or `DELETE` on `trading`, `ledger`, `audit` or `market_data` tables. It
reaches them only through three `SECURITY DEFINER` functions (owned by the migration role, with a pinned
`search_path`). Each one calls `core.assert_tenant_access(tenant)` before doing anything, and that check
rejects the call unless the session's `app.current_tenant_id` equals the tenant argument.

Operator-only functions (`ledger.deposit`, `ledger.post_transfer`, `ledger.ensure_accounts`,
`risk.sync_trade_edges`, `risk.generate_alerts`, `market_data.ingest_trade_tick`,
`market_data.refresh_candles`, `market_data.ensure_tick_partition`, the `*_core` implementations and the
ledger reconciliation functions) are revoked from `PUBLIC`, `vt_app` and `vt_readonly`.

This closes the original gap where `vt_app` was granted table writes it could use to bypass validation, and
where it nevertheless could not call the engine at all. Both facts are covered by `tests/test_hardening.py`.

## 2. Row-Level Security

Policies exist on: `core.tenants`, `core.users`, `core.trading_accounts`, `trading.orders`,
`trading.order_events`, `trading.trades`, `ledger.accounts`, `ledger.journals`, `ledger.entries`,
`audit.events`, `audit.chain_state`, `risk.alerts`, `risk.transfer_edges`.

Not covered by RLS, by design: `core.assets`, `core.markets` (shared reference data) and `market_data.*`
(public market data).

### Session context

```sql
SET LOCAL app.current_tenant_id = 'a0000000-0000-0000-0000-000000000001';
```

### Fail-closed behaviour

If `app.current_tenant_id` is missing or malformed, `core.current_tenant_id()` returns `NULL`. `NULL = tenant_id`
is never true, so RLS returns no rows, and the tenant guard on the engine API raises `insufficient_privilege`.

## 3. Threat Model

| Threat | Vector | Mitigation | Residual risk |
|---|---|---|---|
| Cross-tenant read | Query or join another tenant's rows | RLS on all tenant-owned tables; negative tests in `test_security.py` and `test_hardening.py` | None known inside the modelled roles |
| Cross-tenant write | Call the engine with another tenant's id | Tenant guard on the `SECURITY DEFINER` API | **Session context is client-settable.** A connection that can run arbitrary SQL as `vt_app` can `SET app.current_tenant_id` to any value. The connection layer in front of the database must set it and must not hand raw SQL access to a tenant. |
| Minting funds | Call `ledger.deposit` or write `ledger.accounts` | Function revoked; no table write privilege | Anyone holding the owner credentials can still do both |
| Ledger tampering | Edit posted entries | No `UPDATE`/`DELETE` for `vt_app`; `ledger.reconcile_balances()` and `ledger.check_conservation()` detect drift between `ledger.accounts.balance` and `ledger.entries` | The owner role can edit rows. There is no trigger-level immutability, so detection (reconciliation, audit chain) is the control for that role. |
| Audit erasure or forgery | Modify or insert audit events | Hash chain verified by `audit.verify_chain()`; `vt_app` cannot write the tables and can only append through the guarded function | An owner who rewrites the whole chain and its head can produce a consistent history unless an earlier checkpoint was exported elsewhere |
| Wash trading | Same account on both sides of a trade | Orders that would cross the account's own resting order are rejected before matching; `chk_different_accounts` remains as a backstop | Two accounts controlled by one party are not detected here; that is what `risk.detect_cycles` is for |
| Credential leakage | Password committed to git | `.env` is gitignored and was checked against git history; CI uses a throwaway service-container password | See "Development role passwords" below |

## 4. Development role passwords

Migration `V009` creates `vt_app` and `vt_readonly` with fixed development passwords
(`vt_app_dev_only`, `vt_readonly_dev_only`). These exist so a local clone works out of the box. They are
**not secrets** and must be changed before any shared or networked deployment:

```sql
ALTER ROLE vt_app PASSWORD '...';
ALTER ROLE vt_readonly PASSWORD '...';
```

Nothing in the test suite connects as these roles by password; tests use `SET ROLE` from the owner session.
