-- VerityTick Migration V004
-- Ledger Accounts and Financial Entries
--
-- Double-entry accounting system:
-- - Ledger accounts hold balances per asset
-- - Journal transactions group balanced entries
-- - Each entry is a transfer between two accounts
-- - Posted entries are immutable for application roles

-- =============================================================================
-- Ledger Accounts
-- =============================================================================

CREATE TABLE ledger.accounts (
    ledger_account_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES core.tenants(tenant_id),
    -- Links to trading account (NULL for system/fee accounts)
    trading_account_id  UUID REFERENCES core.trading_accounts(account_id),
    asset_id            UUID NOT NULL REFERENCES core.assets(asset_id),
    account_type        TEXT NOT NULL
                        CHECK (account_type IN (
                            'trading',      -- normal user trading balance
                            'reservation',  -- funds reserved for open orders
                            'fee',          -- fee collection account
                            'system'        -- system/clearing account
                        )),
    label               TEXT NOT NULL DEFAULT 'main',
    -- Maintained balance (must reconcile with ledger entries)
    balance             NUMERIC(30, 18) NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Each trading account has one ledger account per asset per type
    CONSTRAINT uq_ledger_account
        UNIQUE (trading_account_id, asset_id, account_type, label)
);

CREATE INDEX idx_ledger_accounts_tenant ON ledger.accounts (tenant_id);
CREATE INDEX idx_ledger_accounts_trading ON ledger.accounts (trading_account_id);

COMMENT ON TABLE ledger.accounts IS
    'Financial accounts that hold balances. Each trading account gets one per asset.';

-- =============================================================================
-- Journal Transactions (headers)
-- =============================================================================

CREATE TABLE ledger.journals (
    journal_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES core.tenants(tenant_id),
    journal_type    TEXT NOT NULL
                    CHECK (journal_type IN (
                        'deposit', 'withdrawal', 'trade_settlement',
                        'fee', 'reservation', 'release', 'correction'
                    )),
    -- Reference to business event
    reference_type  TEXT,
    reference_id    UUID,
    description     TEXT,
    status          TEXT NOT NULL DEFAULT 'posted'
                    CHECK (status IN ('posted')),
    posted_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_journals_tenant ON ledger.journals (tenant_id);
CREATE INDEX idx_journals_reference ON ledger.journals (reference_type, reference_id);

COMMENT ON TABLE ledger.journals IS
    'Journal header grouping balanced ledger entries. Once posted, immutable.';

-- =============================================================================
-- Ledger Entries (transfer legs)
-- =============================================================================

CREATE TABLE ledger.entries (
    entry_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    journal_id          UUID NOT NULL REFERENCES ledger.journals(journal_id),
    -- Transfer: from debit_account to credit_account
    debit_account_id    UUID NOT NULL REFERENCES ledger.accounts(ledger_account_id),
    credit_account_id   UUID NOT NULL REFERENCES ledger.accounts(ledger_account_id),
    asset_id            UUID NOT NULL REFERENCES core.assets(asset_id),
    amount              NUMERIC(30, 18) NOT NULL CHECK (amount > 0),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Cannot transfer to yourself
    CONSTRAINT chk_different_accounts
        CHECK (debit_account_id != credit_account_id)
);

CREATE INDEX idx_entries_journal ON ledger.entries (journal_id);
CREATE INDEX idx_entries_debit ON ledger.entries (debit_account_id);
CREATE INDEX idx_entries_credit ON ledger.entries (credit_account_id);

COMMENT ON TABLE ledger.entries IS
    'Individual transfer leg. Debit removes from one account, credit adds to another.';
COMMENT ON COLUMN ledger.entries.amount IS
    'Strictly positive. Debit account decreases, credit account increases by this amount.';
