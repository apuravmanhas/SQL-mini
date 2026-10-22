# ADR 0003: Cryptographic Audit Hash Chain and Trust Boundaries

## Context
Regulators and risk officers require verification that audit logs have not been retroactively altered or deleted after the fact.

## Decision
We implement a SHA-256 hash chain per tenant using PostgreSQL's `pgcrypto` extension. Each audit event hashes its canonicalized payload concatenated with the hash of the preceding event (`previous_hash`). An external checkpoint export function allows anchoring the chain head outside the database.

## Trust Boundaries
The audit chain is tamper-evident within the operational trust model:
1. An application role cannot alter historical entries without detection.
2. A superuser with direct table access who rewrites events will break hash linkage, detectable by `audit.verify_chain()`.
3. An adversary who rewrites the entire chain and recalculates all hashes can only be detected if an independent verifier retains an earlier external checkpoint digest.
