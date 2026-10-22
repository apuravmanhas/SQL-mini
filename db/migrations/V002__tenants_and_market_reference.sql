-- VerityTick Migration V002
-- Tenants, Users, Assets, Markets, and Trading Accounts
--
-- Establishes the ownership and reference-data foundation.
-- All financial entities are scoped to a tenant.

-- =============================================================================
-- Tenants
-- =============================================================================

CREATE TABLE core.tenants (
    tenant_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'suspended', 'closed')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    metadata        JSONB DEFAULT '{}'::jsonb
);

COMMENT ON TABLE core.tenants IS 'Organizational tenant — top-level ownership boundary';

CREATE UNIQUE INDEX idx_tenants_name ON core.tenants (name);

-- =============================================================================
-- Users
-- =============================================================================

CREATE TABLE core.users (
    user_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES core.tenants(tenant_id),
    username        TEXT NOT NULL,
    display_name    TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'suspended', 'closed')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE core.users IS 'User within a tenant — can own trading accounts';

-- Username must be unique within a tenant
CREATE UNIQUE INDEX idx_users_tenant_username
    ON core.users (tenant_id, username);

-- =============================================================================
-- Assets
-- =============================================================================

CREATE TABLE core.assets (
    asset_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    symbol          TEXT NOT NULL UNIQUE,
    name            TEXT NOT NULL,
    asset_type      TEXT NOT NULL DEFAULT 'currency'
                    CHECK (asset_type IN ('currency', 'equity', 'commodity', 'crypto')),
    precision_scale SMALLINT NOT NULL DEFAULT 2
                    CHECK (precision_scale >= 0 AND precision_scale <= 18),
    status          TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'suspended', 'delisted')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE core.assets IS 'Tradeable asset definition with precision rules';
COMMENT ON COLUMN core.assets.precision_scale IS 'Number of decimal places for this asset';

-- =============================================================================
-- Markets (trading pairs)
-- =============================================================================

CREATE TABLE core.markets (
    market_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    symbol              TEXT NOT NULL UNIQUE,
    base_asset_id       UUID NOT NULL REFERENCES core.assets(asset_id),
    quote_asset_id      UUID NOT NULL REFERENCES core.assets(asset_id),
    price_precision     SMALLINT NOT NULL DEFAULT 2
                        CHECK (price_precision >= 0 AND price_precision <= 18),
    quantity_precision  SMALLINT NOT NULL DEFAULT 4
                        CHECK (quantity_precision >= 0 AND quantity_precision <= 18),
    min_quantity        NUMERIC(30, 18) NOT NULL DEFAULT 0.0001
                        CHECK (min_quantity > 0),
    min_notional        NUMERIC(30, 18) NOT NULL DEFAULT 0
                        CHECK (min_notional >= 0),
    status              TEXT NOT NULL DEFAULT 'open'
                        CHECK (status IN ('open', 'halted', 'closed')),
    -- Per-market priority sequence for order matching
    -- Atomically incremented when accepting orders
    next_priority_seq   BIGINT NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Base and quote must be different assets
    CONSTRAINT chk_different_assets
        CHECK (base_asset_id != quote_asset_id)
);

COMMENT ON TABLE core.markets IS
    'Trading pair definition. E.g., ACME/USDX means ACME is base, USDX is quote.';
COMMENT ON COLUMN core.markets.next_priority_seq IS
    'Monotonic counter for deterministic price-time priority within this market';

-- =============================================================================
-- Trading Accounts
-- =============================================================================

CREATE TABLE core.trading_accounts (
    account_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES core.tenants(tenant_id),
    user_id         UUID NOT NULL REFERENCES core.users(user_id),
    label           TEXT NOT NULL DEFAULT 'default',
    status          TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'frozen', 'closed')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE core.trading_accounts IS
    'Financial account owned by a user within a tenant. Holds asset balances.';

-- An account label must be unique per user
CREATE UNIQUE INDEX idx_accounts_user_label
    ON core.trading_accounts (user_id, label);

-- Enforce that the user belongs to the same tenant as the account
-- This is done via a trigger since cross-column FK checks aren't native

CREATE OR REPLACE FUNCTION core.verify_account_tenant()
RETURNS TRIGGER AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.users
        WHERE user_id = NEW.user_id
          AND tenant_id = NEW.tenant_id
    ) THEN
        RAISE EXCEPTION 'User % does not belong to tenant %',
            NEW.user_id, NEW.tenant_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_verify_account_tenant
    BEFORE INSERT OR UPDATE ON core.trading_accounts
    FOR EACH ROW
    EXECUTE FUNCTION core.verify_account_tenant();
