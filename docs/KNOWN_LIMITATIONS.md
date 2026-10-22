# VerityTick — Known Limitations

## Architectural

1. **Not a production exchange.** This is a simulated educational system demonstrating database engineering. It lacks the operational infrastructure (monitoring, failover, connection pooling, rate limiting) required for real financial systems.

2. **Single PostgreSQL instance.** No replication, no high-availability setup. Crash recovery relies entirely on PostgreSQL's own WAL and recovery mechanisms.

3. **No external authentication.** Tenant identity is propagated via session variables (`SET LOCAL`), not a real authentication service. The threat model documents what this means.

4. **No Docker environment.** The development setup uses a native PostgreSQL installation. Docker Compose configuration is provided for reference but untested in this environment.

## Implementation

5. **Hash chain trust model.** The audit hash chain is tamper-evident within its trust assumptions, but a sufficiently privileged database administrator can reconstruct a consistent alternative history. See docs/SECURITY_MODEL.md.

6. **Fraud detection is heuristic.** Circular transfer detection produces investigative leads, not proof of criminal activity. False positives are expected and documented.

7. **Performance numbers are environment-specific.** All benchmarks are measured on the development machine and are not transferable to different hardware or PostgreSQL configurations.

## Not Implemented (Yet)

Items listed here are planned but not yet built:

- Market orders (only limit orders supported)
- Stop orders
- Order replacement/amendment
- Multi-leg/complex orders
- Real-time streaming
- Web API layer
