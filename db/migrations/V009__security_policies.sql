-- VerityTick Migration V009
-- Row-Level Security and Tenant Isolation
--
-- Implements:
-- - Application role with restricted privileges
-- - Read-only reporting role
-- - Row-Level Security policies on tenant-scoped tables
-- - Tenant identity via session variable (app.current_tenant_id)
--
-- THREAT MODEL:
-- Tenant identity is propagated via SET LOCAL app.current_tenant_id.
-- This assumes the application layer establishes the correct tenant
-- context before executing queries. Direct database connections without
-- proper tenant context will see no rows (fail-closed).

-- =============================================================================
-- Roles
-- =============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vt_app') THEN
        CREATE ROLE vt_app LOGIN PASSWORD 'vt_app_dev_only';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vt_readonly') THEN
        CREATE ROLE vt_readonly LOGIN PASSWORD 'vt_readonly_dev_only';
    END IF;
END $$;

COMMENT ON ROLE vt_app IS 'Application role — restricted access via RLS';
COMMENT ON ROLE vt_readonly IS 'Read-only reporting role — restricted access via RLS';

-- =============================================================================
-- Schema and table grants
-- =============================================================================

-- Grant USAGE on schemas
GRANT USAGE ON SCHEMA core TO vt_app, vt_readonly;
GRANT USAGE ON SCHEMA trading TO vt_app, vt_readonly;
GRANT USAGE ON SCHEMA ledger TO vt_app, vt_readonly;
GRANT USAGE ON SCHEMA audit TO vt_app, vt_readonly;
GRANT USAGE ON SCHEMA risk TO vt_app, vt_readonly;
GRANT USAGE ON SCHEMA market_data TO vt_app, vt_readonly;

-- App role: SELECT + INSERT + UPDATE on most tables (no DELETE, no DDL)
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA core TO vt_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA trading TO vt_app;
GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA ledger TO vt_app;
GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA audit TO vt_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA risk TO vt_app;
GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA market_data TO vt_app;

-- Read-only role: SELECT only
GRANT SELECT ON ALL TABLES IN SCHEMA core TO vt_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA trading TO vt_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA ledger TO vt_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA audit TO vt_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA risk TO vt_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA market_data TO vt_readonly;

-- Function execution
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA trading TO vt_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ledger TO vt_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA audit TO vt_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA risk TO vt_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA market_data TO vt_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA core TO vt_app;

-- =============================================================================
-- Row-Level Security Policies
-- =============================================================================

-- Helper: get current tenant from session
CREATE OR REPLACE FUNCTION core.current_tenant_id()
RETURNS UUID AS $$
BEGIN
    RETURN current_setting('app.current_tenant_id', true)::UUID;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE;

-- ─── Tenants ────────────────────────────────────────────────────────────
ALTER TABLE core.tenants ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON core.tenants
    USING (tenant_id = core.current_tenant_id());

-- ─── Users ──────────────────────────────────────────────────────────────
ALTER TABLE core.users ENABLE ROW LEVEL SECURITY;

CREATE POLICY user_tenant_isolation ON core.users
    USING (tenant_id = core.current_tenant_id());

-- ─── Trading Accounts ──────────────────────────────────────────────────
ALTER TABLE core.trading_accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY account_tenant_isolation ON core.trading_accounts
    USING (tenant_id = core.current_tenant_id());

-- ─── Orders ─────────────────────────────────────────────────────────────
ALTER TABLE trading.orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY order_tenant_isolation ON trading.orders
    USING (tenant_id = core.current_tenant_id());

-- ─── Order Events ───────────────────────────────────────────────────────
ALTER TABLE trading.order_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY order_events_isolation ON trading.order_events
    USING (
        EXISTS (
            SELECT 1 FROM trading.orders o
            WHERE o.order_id = trading.order_events.order_id
              AND o.tenant_id = core.current_tenant_id()
        )
    );

-- ─── Trades ─────────────────────────────────────────────────────────────
ALTER TABLE trading.trades ENABLE ROW LEVEL SECURITY;

CREATE POLICY trade_isolation ON trading.trades
    USING (
        buy_account_id IN (
            SELECT account_id FROM core.trading_accounts
            WHERE tenant_id = core.current_tenant_id()
        )
        OR sell_account_id IN (
            SELECT account_id FROM core.trading_accounts
            WHERE tenant_id = core.current_tenant_id()
        )
    );

-- ─── Ledger Accounts ───────────────────────────────────────────────────
ALTER TABLE ledger.accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY ledger_account_isolation ON ledger.accounts
    USING (tenant_id = core.current_tenant_id());

-- ─── Ledger Journals ───────────────────────────────────────────────────
ALTER TABLE ledger.journals ENABLE ROW LEVEL SECURITY;

CREATE POLICY journal_isolation ON ledger.journals
    USING (tenant_id = core.current_tenant_id());

-- ─── Ledger Entries ─────────────────────────────────────────────────────
ALTER TABLE ledger.entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY entry_isolation ON ledger.entries
    USING (
        EXISTS (
            SELECT 1 FROM ledger.journals j
            WHERE j.journal_id = ledger.entries.journal_id
              AND j.tenant_id = core.current_tenant_id()
        )
    );

-- ─── Audit Events ──────────────────────────────────────────────────────
ALTER TABLE audit.events ENABLE ROW LEVEL SECURITY;

CREATE POLICY audit_tenant_isolation ON audit.events
    USING (tenant_id = core.current_tenant_id());

-- ─── Risk Alerts ────────────────────────────────────────────────────────
ALTER TABLE risk.alerts ENABLE ROW LEVEL SECURITY;

CREATE POLICY alert_tenant_isolation ON risk.alerts
    USING (tenant_id = core.current_tenant_id());

-- ─── Prevent ledger mutations via app role ──────────────────────────────
-- Revoke UPDATE and DELETE on posted ledger records for app role
REVOKE UPDATE, DELETE ON ledger.journals FROM vt_app;
REVOKE UPDATE, DELETE ON ledger.entries FROM vt_app;

-- Markets and assets are reference data — visible to all tenants
-- (no RLS on core.markets and core.assets)
