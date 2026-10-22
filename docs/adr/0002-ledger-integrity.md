# ADR 0002: Immutable Double-Entry Ledger Representation

## Context
Authoritative account balances in financial systems cannot rely on mutable `UPDATE accounts SET balance = balance + x` columns without traceable historical proof of transfer legs.

## Decision
We implement a double-entry financial ledger consisting of immutable journals (`ledger.journals`) and transfer entries (`ledger.entries`). Each entry specifies a debit account, a credit account, an explicit asset, and a strictly positive quantity. Application roles (`vt_app`) have revoked `UPDATE` and `DELETE` privileges on posted entries.

## Consequences
- Every balance mutation is permanently attributed to an underlying trade, deposit, or fee.
- Reconciliation functions can verify balance integrity from genesis entries at any time.
