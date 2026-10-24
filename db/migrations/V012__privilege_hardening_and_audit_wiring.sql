-- VerityTick Migration V012
-- Privilege model hardening, engine-level audit trail, reconciliation,
-- self-trade prevention and on-demand tick partitions.
--
-- Background
-- ----------
-- Before this migration the restricted application role (vt_app) could not
-- actually use the engine: place_order() ran with the caller's privileges and
-- vt_app has no UPDATE on ledger.accounts. At the same time vt_app held direct
-- INSERT/UPDATE grants on ledger, order and audit tables, which would have let
-- it bypass the engine and write records that never passed validation.
--
-- Model after this migration
-- --------------------------
--   * vt_app may call a small, audited API:
--       trading.place_order, trading.cancel_order, audit.append_event
--     These are SECURITY DEFINER wrappers. Each one first verifies that the
--     session's tenant context matches the tenant argument (superusers and
--     operators are exempt), then delegates to the *_core implementation.
--   * vt_app has SELECT only on engine-owned tables (RLS still applies).
--   * Batch and maintenance functions (deposit, edge sync, alert generation,
--     tick ingestion, candle refresh) are operator-only.
--   * The tenant context is a session setting. A connection that can run
--     arbitrary SQL as vt_app can set it to any value, so the connection layer
--     in front of the database must be trusted to set it. See SECURITY_MODEL.md.

-- =============================================================================
-- 1. Tenant access guard
-- =============================================================================

CREATE OR REPLACE FUNCTION core.assert_tenant_access(p_tenant_id UUID)
RETURNS void AS $$
DECLARE
    v_caller TEXT;
    v_super  BOOLEAN;
BEGIN
    -- SET ROLE changes the effective caller without changing session_user.
    v_caller := CASE WHEN current_setting('role') <> 'none'
                     THEN current_setting('role')
                     ELSE session_user::TEXT END;

    SELECT r.rolsuper INTO v_super FROM pg_roles r WHERE r.rolname = v_caller;
    IF COALESCE(v_super, FALSE) THEN
        RETURN;
    END IF;

    IF core.current_tenant_id() IS DISTINCT FROM p_tenant_id THEN
        RAISE EXCEPTION 'Tenant context does not match requested tenant'
            USING ERRCODE = '42501';
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;

-- =============================================================================
-- 2. Move existing implementations behind *_core names
-- =============================================================================

ALTER FUNCTION trading.place_order(UUID, UUID, UUID, TEXT, NUMERIC, NUMERIC, TEXT)
    RENAME TO place_order_core;
ALTER FUNCTION trading.cancel_order(UUID, UUID)
    RENAME TO cancel_order_core;
ALTER FUNCTION audit.append_event(UUID, TEXT, TEXT, UUID, UUID, JSONB)
    RENAME TO append_event_core;

-- =============================================================================
-- 3. Public API wrappers
-- =============================================================================

CREATE OR REPLACE FUNCTION audit.append_event(
    p_tenant_id UUID,
    p_event_type TEXT,
    p_entity_type TEXT DEFAULT NULL,
    p_entity_id UUID DEFAULT NULL,
    p_actor_id UUID DEFAULT NULL,
    p_payload JSONB DEFAULT '{}'::jsonb
) RETURNS UUID AS $$
BEGIN
    PERFORM core.assert_tenant_access(p_tenant_id);
    RETURN audit.append_event_core(
        p_tenant_id, p_event_type, p_entity_type, p_entity_id, p_actor_id, p_payload
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public;

CREATE OR REPLACE FUNCTION trading.place_order(
    p_tenant_id UUID,
    p_account_id UUID,
    p_market_id UUID,
    p_side TEXT,
    p_limit_price NUMERIC(30, 18),
    p_quantity NUMERIC(30, 18),
    p_idempotency_key TEXT DEFAULT NULL
) RETURNS TABLE (
    order_id UUID,
    status TEXT,
    remaining_quantity NUMERIC(30, 18),
    trades_executed INTEGER,
    message TEXT
) AS $$
DECLARE
    v_res RECORD;
BEGIN
    PERFORM core.assert_tenant_access(p_tenant_id);

    -- Take the per-market lock first so the self-trade check and the matching
    -- loop inside place_order_core observe the same order book.
    PERFORM 1 FROM core.markets m WHERE m.market_id = p_market_id FOR UPDATE;

    -- Self-trade prevention: reject an order that would cross a resting order
    -- from the same account instead of failing on chk_different_accounts.
    IF p_side IN ('buy', 'sell') AND p_limit_price > 0
       AND NOT EXISTS (
           SELECT 1 FROM trading.orders d
           WHERE d.account_id = p_account_id
             AND d.idempotency_key = p_idempotency_key)
       AND EXISTS (
           SELECT 1 FROM trading.orders o
           WHERE o.market_id = p_market_id
             AND o.tenant_id = p_tenant_id
             AND o.account_id = p_account_id
             AND o.status IN ('open', 'partially_filled')
             AND ((p_side = 'buy'  AND o.side = 'sell' AND o.limit_price <= p_limit_price)
               OR (p_side = 'sell' AND o.side = 'buy'  AND o.limit_price >= p_limit_price)))
    THEN
        PERFORM audit.append_event_core(
            p_tenant_id, 'order_rejected', 'account', p_account_id, NULL,
            jsonb_build_object('market_id', p_market_id, 'side', p_side,
                               'limit_price', p_limit_price, 'quantity', p_quantity,
                               'reason', 'self_trade_prevention'));
        RETURN QUERY SELECT NULL::UUID, 'rejected'::TEXT, 0::NUMERIC(30,18), 0,
            'Order would cross the account''s own resting order'::TEXT;
        RETURN;
    END IF;

    SELECT * INTO v_res FROM trading.place_order_core(
        p_tenant_id, p_account_id, p_market_id, p_side,
        p_limit_price, p_quantity, p_idempotency_key
    );

    -- Duplicate idempotent requests are not new events. Requests naming an
    -- unknown tenant have no audit chain to attach to.
    IF (v_res.message IS NULL OR v_res.message NOT LIKE 'Duplicate request%')
       AND EXISTS (SELECT 1 FROM core.tenants t WHERE t.tenant_id = p_tenant_id) THEN
        PERFORM audit.append_event_core(
            p_tenant_id,
            CASE WHEN v_res.order_id IS NULL THEN 'order_rejected' ELSE 'order_placed' END,
            CASE WHEN v_res.order_id IS NULL THEN 'account' ELSE 'order' END,
            COALESCE(v_res.order_id, p_account_id),
            NULL,
            jsonb_build_object(
                'account_id', p_account_id, 'market_id', p_market_id,
                'side', p_side, 'limit_price', p_limit_price, 'quantity', p_quantity,
                'status', v_res.status, 'trades_executed', v_res.trades_executed,
                'message', v_res.message));
    END IF;

    RETURN QUERY SELECT v_res.order_id, v_res.status, v_res.remaining_quantity,
                        v_res.trades_executed, v_res.message;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public;

CREATE OR REPLACE FUNCTION trading.cancel_order(
    p_tenant_id UUID,
    p_order_id UUID
) RETURNS TABLE (
    order_id UUID,
    status TEXT,
    released_quantity NUMERIC(30, 18),
    message TEXT
) AS $$
DECLARE
    v_res RECORD;
BEGIN
    PERFORM core.assert_tenant_access(p_tenant_id);

    SELECT * INTO v_res FROM trading.cancel_order_core(p_tenant_id, p_order_id);

    IF v_res.status = 'cancelled' THEN
        PERFORM audit.append_event_core(
            p_tenant_id, 'order_cancelled', 'order', p_order_id, NULL,
            jsonb_build_object('released_quantity', v_res.released_quantity));
    END IF;

    RETURN QUERY SELECT v_res.order_id, v_res.status, v_res.released_quantity, v_res.message;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public;

-- =============================================================================
-- 4. Privileges
-- =============================================================================

-- Internal and operator-only functions
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS sig
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE (n.nspname, p.proname) IN (
            ('trading', 'place_order_core'),
            ('trading', 'cancel_order_core'),
            ('audit', 'append_event_core'),
            ('core', 'assert_tenant_access'),
            ('ledger', 'deposit'),
            ('ledger', 'post_transfer'),
            ('ledger', 'ensure_accounts'),
            ('risk', 'sync_trade_edges'),
            ('risk', 'generate_alerts'),
            ('market_data', 'ingest_trade_tick'),
            ('market_data', 'refresh_candles')
        )
    LOOP
        EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, vt_app, vt_readonly', r.sig);
    END LOOP;
END $$;

-- Public API: callable by the application role only
REVOKE EXECUTE ON FUNCTION trading.place_order(UUID, UUID, UUID, TEXT, NUMERIC, NUMERIC, TEXT)
    FROM PUBLIC, vt_readonly;
REVOKE EXECUTE ON FUNCTION trading.cancel_order(UUID, UUID) FROM PUBLIC, vt_readonly;
REVOKE EXECUTE ON FUNCTION audit.append_event(UUID, TEXT, TEXT, UUID, UUID, JSONB)
    FROM PUBLIC, vt_readonly;
GRANT EXECUTE ON FUNCTION trading.place_order(UUID, UUID, UUID, TEXT, NUMERIC, NUMERIC, TEXT) TO vt_app;
GRANT EXECUTE ON FUNCTION trading.cancel_order(UUID, UUID) TO vt_app;
GRANT EXECUTE ON FUNCTION audit.append_event(UUID, TEXT, TEXT, UUID, UUID, JSONB) TO vt_app;

-- Engine-owned tables are written only through the functions above.
REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA trading FROM vt_app;
REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ledger FROM vt_app;
REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA audit FROM vt_app;
REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA market_data FROM vt_app;
REVOKE INSERT, DELETE ON ALL TABLES IN SCHEMA risk FROM vt_app;
REVOKE UPDATE ON risk.transfer_edges FROM vt_app;
-- Reference data and tenant records are administered by the operator.
REVOKE INSERT, UPDATE, DELETE ON core.markets, core.assets, core.tenants FROM vt_app;

-- =============================================================================
-- 5. Row-level security for the two tables that had none
-- =============================================================================

ALTER TABLE audit.chain_state ENABLE ROW LEVEL SECURITY;
CREATE POLICY chain_state_tenant_isolation ON audit.chain_state
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE risk.transfer_edges ENABLE ROW LEVEL SECURITY;
CREATE POLICY transfer_edges_tenant_isolation ON risk.transfer_edges
    USING (tenant_id = core.current_tenant_id());

-- =============================================================================
-- 6. Ledger reconciliation
-- =============================================================================

-- Returns every ledger account whose stored balance differs from the balance
-- recomputed from ledger.entries. An empty result means the ledger reconciles.
CREATE OR REPLACE FUNCTION ledger.reconcile_balances(p_tenant_id UUID DEFAULT NULL)
RETURNS TABLE (
    ledger_account_id UUID,
    asset_id UUID,
    stored_balance NUMERIC(30, 18),
    computed_balance NUMERIC(30, 18),
    difference NUMERIC(30, 18)
) AS $$
    WITH movements AS (
        SELECT e.credit_account_id AS acct, e.amount AS delta FROM ledger.entries e
        UNION ALL
        SELECT e.debit_account_id, -e.amount FROM ledger.entries e
    )
    SELECT a.ledger_account_id,
           a.asset_id,
           a.balance,
           COALESCE(SUM(m.delta), 0)::NUMERIC(30, 18),
           (a.balance - COALESCE(SUM(m.delta), 0))::NUMERIC(30, 18)
    FROM ledger.accounts a
    LEFT JOIN movements m ON m.acct = a.ledger_account_id
    WHERE p_tenant_id IS NULL OR a.tenant_id = p_tenant_id
    GROUP BY a.ledger_account_id, a.asset_id, a.balance
    HAVING a.balance <> COALESCE(SUM(m.delta), 0);
$$ LANGUAGE sql STABLE;

-- Double-entry conservation: balances of each asset must sum to zero across
-- all accounts. Returns only the assets that violate this.
CREATE OR REPLACE FUNCTION ledger.check_conservation()
RETURNS TABLE (
    asset_id UUID,
    net_balance NUMERIC(30, 18)
) AS $$
    SELECT a.asset_id, SUM(a.balance)::NUMERIC(30, 18)
    FROM ledger.accounts a
    GROUP BY a.asset_id
    HAVING SUM(a.balance) <> 0;
$$ LANGUAGE sql STABLE;

REVOKE EXECUTE ON FUNCTION ledger.reconcile_balances(UUID) FROM PUBLIC, vt_app, vt_readonly;
REVOKE EXECUTE ON FUNCTION ledger.check_conservation() FROM PUBLIC, vt_app, vt_readonly;

-- =============================================================================
-- 7. Tick partitions on demand
-- =============================================================================

-- Partition boundaries follow the session time zone, matching V008. Run
-- maintenance from sessions that use the same time zone as the migrations.
CREATE OR REPLACE FUNCTION market_data.ensure_tick_partition(p_ts TIMESTAMPTZ)
RETURNS TEXT AS $$
DECLARE
    v_start DATE := date_trunc('month', p_ts)::DATE;
    v_end   DATE := (date_trunc('month', p_ts) + INTERVAL '1 month')::DATE;
    v_name  TEXT := 'ticks_' || to_char(date_trunc('month', p_ts), 'YYYY_MM');
BEGIN
    IF to_regclass(format('market_data.%I', v_name)) IS NULL THEN
        BEGIN
            EXECUTE format(
                'CREATE TABLE market_data.%I PARTITION OF market_data.ticks
                 FOR VALUES FROM (%L) TO (%L)', v_name, v_start, v_end);
        EXCEPTION WHEN duplicate_table THEN
            NULL;  -- created concurrently by another session
        END;
    END IF;
    RETURN v_name;
END;
$$ LANGUAGE plpgsql;

REVOKE EXECUTE ON FUNCTION market_data.ensure_tick_partition(TIMESTAMPTZ)
    FROM PUBLIC, vt_app, vt_readonly;

CREATE OR REPLACE FUNCTION market_data.ingest_trade_tick(
    p_trade_id UUID
) RETURNS UUID AS $$
DECLARE
    v_trade RECORD;
    v_tick_id UUID;
BEGIN
    SELECT t.trade_id, t.market_id, t.price, t.quantity, t.executed_at
    INTO v_trade
    FROM trading.trades t
    WHERE t.trade_id = p_trade_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Trade not found: %', p_trade_id;
    END IF;

    PERFORM market_data.ensure_tick_partition(v_trade.executed_at);

    INSERT INTO market_data.ticks (
        market_id, source_event_id, event_time, price, quantity, trade_id, source
    ) VALUES (
        v_trade.market_id,
        'trade:' || v_trade.trade_id::TEXT,
        v_trade.executed_at,
        v_trade.price,
        v_trade.quantity,
        v_trade.trade_id,
        'internal'
    )
    ON CONFLICT (market_id, source_event_id, event_time) DO NOTHING
    RETURNING tick_id INTO v_tick_id;

    RETURN v_tick_id;
END;
$$ LANGUAGE plpgsql;

REVOKE EXECUTE ON FUNCTION market_data.ingest_trade_tick(UUID) FROM PUBLIC, vt_app, vt_readonly;
