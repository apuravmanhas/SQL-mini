# VerityTick — Known Limitations

## Architectural

1. **Not a production exchange.** This is a simulated educational system demonstrating database engineering. It lacks the operational infrastructure (monitoring, failover, connection pooling, rate limiting) required for real financial systems.

2. **Single PostgreSQL instance.** No replication, no high-availability setup. Crash recovery relies entirely on PostgreSQL's own WAL and recovery mechanisms.

3. **No external authentication.** Tenant identity is propagated through the `app.current_tenant_id` session setting, which a connection with raw SQL access can change. The database enforces isolation given a trustworthy connection layer; it does not authenticate tenants itself. See docs/SECURITY_MODEL.md.

4. **No container setup.** There is no Dockerfile or Compose file. Development uses a native PostgreSQL install; CI uses a GitHub Actions service container.

5. **Development role passwords are fixed.** `vt_app` and `vt_readonly` are created with well-known passwords in migration V009. Change them outside local development.

## Implementation

6. **Hash chain trust model.** The audit hash chain is tamper-evident within its trust assumptions, but a sufficiently privileged database administrator can reconstruct a consistent alternative history unless a checkpoint was exported earlier. See docs/SECURITY_MODEL.md.

7. **The owner role is not constrained.** Ledger and audit immutability is enforced by privileges (`vt_app` cannot write) and detected by reconciliation and chain verification. There are no triggers that block the table owner from editing rows.

8. **Audit writes serialize per tenant.** Every `place_order` / `cancel_order` appends an audit event, which takes a row lock on the tenant's `audit.chain_state`. Orders in different markets for the same tenant therefore commit one at a time. Per-market locking alone would allow more parallelism.

9. **Ledger balance is a maintained value.** `ledger.accounts.balance` is updated alongside each entry. `ledger.reconcile_balances()` and `ledger.check_conservation()` verify it, but they are run on demand, not enforced by a constraint.

10. **Self-trade prevention is conservative.** An order is rejected if it would cross any resting order from the same account, even when better-priced orders from other accounts would have filled it first.

11. **Fraud detection is heuristic.** Circular transfer detection produces investigative leads, not proof of wrongdoing. False positives are expected.

12. **Tick partitions are created on demand by `market_data.ingest_trade_tick`.** Partition boundaries follow the session time zone. Direct inserts into `market_data.ticks` outside existing partitions will fail.

13. **Performance numbers are environment-specific.** All benchmarks are measured on a single development machine and are not transferable to other hardware or PostgreSQL configurations.

14. **CI coverage is unverified here.** The GitHub Actions workflow targets PostgreSQL 17 and 18. The full test suite has only been run locally against PostgreSQL 18.

## Not Implemented

- Market orders (only limit orders)
- Stop orders
- Order replacement or amendment
- Multi-leg or complex orders
- Fees
- Real-time streaming
- Web API layer
