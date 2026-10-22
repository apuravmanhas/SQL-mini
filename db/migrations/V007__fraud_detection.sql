-- VerityTick Migration V007
-- Recursive Fraud-Ring Detection
--
-- Implements:
-- - Transfer graph representation for cycle detection
-- - Recursive CTE-based circular transfer detection
-- - Time-bounded, depth-bounded graph traversal
-- - Alert model with evidence tracking
-- - Idempotent alert generation

-- =============================================================================
-- Transfer Graph (materialized edges for efficient traversal)
-- =============================================================================

CREATE TABLE risk.transfer_edges (
    edge_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES core.tenants(tenant_id),
    source_account_id   UUID NOT NULL REFERENCES core.trading_accounts(account_id),
    dest_account_id     UUID NOT NULL REFERENCES core.trading_accounts(account_id),
    asset_id            UUID NOT NULL REFERENCES core.assets(asset_id),
    amount              NUMERIC(30, 18) NOT NULL CHECK (amount > 0),
    reference_type      TEXT NOT NULL,
    reference_id        UUID NOT NULL,
    transferred_at      TIMESTAMPTZ NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_different_accounts CHECK (source_account_id != dest_account_id)
);

CREATE INDEX idx_transfer_edges_source ON risk.transfer_edges (source_account_id, transferred_at);
CREATE INDEX idx_transfer_edges_dest ON risk.transfer_edges (dest_account_id, transferred_at);
CREATE INDEX idx_transfer_edges_tenant ON risk.transfer_edges (tenant_id, transferred_at);
CREATE INDEX idx_transfer_edges_time ON risk.transfer_edges (transferred_at);

COMMENT ON TABLE risk.transfer_edges IS
    'Directed graph edges representing value transfers between accounts.
     Built from trade settlements for cycle detection.';

-- =============================================================================
-- Risk Alerts
-- =============================================================================

CREATE TABLE risk.alerts (
    alert_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES core.tenants(tenant_id),
    rule_name           TEXT NOT NULL,
    rule_version        SMALLINT NOT NULL DEFAULT 1,
    severity            TEXT NOT NULL DEFAULT 'medium'
                        CHECK (severity IN ('low', 'medium', 'high', 'critical')),

    -- Cycle details
    cycle_accounts      UUID[] NOT NULL,
    cycle_edges         UUID[] NOT NULL,
    cycle_length        INTEGER NOT NULL CHECK (cycle_length >= 2),
    total_amount        NUMERIC(30, 18),
    asset_id            UUID REFERENCES core.assets(asset_id),

    -- Time window
    window_start        TIMESTAMPTZ NOT NULL,
    window_end          TIMESTAMPTZ NOT NULL,

    -- Evidence
    evidence_summary    TEXT NOT NULL,
    edge_details        JSONB NOT NULL DEFAULT '[]'::jsonb,

    -- Investigation
    status              TEXT NOT NULL DEFAULT 'open'
                        CHECK (status IN ('open', 'investigating', 'confirmed',
                                          'false_positive', 'dismissed')),
    analyst_notes       TEXT,
    resolved_at         TIMESTAMPTZ,
    resolved_by         UUID,

    -- Idempotency: prevent duplicate alerts for same cycle
    cycle_fingerprint   TEXT NOT NULL,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_alerts_fingerprint ON risk.alerts (cycle_fingerprint);
CREATE INDEX idx_alerts_tenant ON risk.alerts (tenant_id, status);
CREATE INDEX idx_alerts_status ON risk.alerts (status, created_at);

COMMENT ON TABLE risk.alerts IS
    'Suspicious pattern alerts with traceable evidence. Investigative leads, not accusations.';

-- =============================================================================
-- Populate transfer edges from trades
-- =============================================================================

CREATE OR REPLACE FUNCTION risk.sync_trade_edges(
    p_tenant_id UUID DEFAULT NULL
) RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER := 0;
BEGIN
    -- Insert edges for trades not yet in the graph
    -- A trade creates two transfers:
    --   1. Quote asset: buyer → seller
    --   2. Base asset: seller → buyer
    INSERT INTO risk.transfer_edges (
        tenant_id, source_account_id, dest_account_id,
        asset_id, amount, reference_type, reference_id, transferred_at
    )
    SELECT
        COALESCE(ba.tenant_id, sa.tenant_id),
        t.buy_account_id, t.sell_account_id,
        m.quote_asset_id, t.price * t.quantity,
        'trade', t.trade_id, t.executed_at
    FROM trading.trades t
    JOIN core.markets m ON t.market_id = m.market_id
    JOIN core.trading_accounts ba ON t.buy_account_id = ba.account_id
    JOIN core.trading_accounts sa ON t.sell_account_id = sa.account_id
    WHERE (p_tenant_id IS NULL OR ba.tenant_id = p_tenant_id OR sa.tenant_id = p_tenant_id)
      AND NOT EXISTS (
          SELECT 1 FROM risk.transfer_edges e
          WHERE e.reference_id = t.trade_id
            AND e.reference_type = 'trade'
            AND e.source_account_id = t.buy_account_id
      )
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    -- Base asset: seller → buyer
    INSERT INTO risk.transfer_edges (
        tenant_id, source_account_id, dest_account_id,
        asset_id, amount, reference_type, reference_id, transferred_at
    )
    SELECT
        COALESCE(sa.tenant_id, ba.tenant_id),
        t.sell_account_id, t.buy_account_id,
        m.base_asset_id, t.quantity,
        'trade', t.trade_id, t.executed_at
    FROM trading.trades t
    JOIN core.markets m ON t.market_id = m.market_id
    JOIN core.trading_accounts ba ON t.buy_account_id = ba.account_id
    JOIN core.trading_accounts sa ON t.sell_account_id = sa.account_id
    WHERE (p_tenant_id IS NULL OR ba.tenant_id = p_tenant_id OR sa.tenant_id = p_tenant_id)
      AND NOT EXISTS (
          SELECT 1 FROM risk.transfer_edges e
          WHERE e.reference_id = t.trade_id
            AND e.reference_type = 'trade'
            AND e.source_account_id = t.sell_account_id
      )
    ON CONFLICT DO NOTHING;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- Detect circular transfers (recursive CTE)
-- =============================================================================

CREATE OR REPLACE FUNCTION risk.detect_cycles(
    p_tenant_id UUID DEFAULT NULL,
    p_window_start TIMESTAMPTZ DEFAULT now() - INTERVAL '24 hours',
    p_window_end TIMESTAMPTZ DEFAULT now(),
    p_max_depth INTEGER DEFAULT 6,
    p_min_amount NUMERIC DEFAULT 0,
    p_asset_id UUID DEFAULT NULL
) RETURNS TABLE (
    cycle_path UUID[],
    cycle_edges UUID[],
    cycle_length INTEGER,
    total_amount NUMERIC,
    asset_id UUID,
    earliest_transfer TIMESTAMPTZ,
    latest_transfer TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE paths AS (
        -- Anchor: start from each account that has outgoing transfers
        SELECT
            e.source_account_id AS start_account,
            e.dest_account_id AS current_account,
            ARRAY[e.source_account_id, e.dest_account_id] AS path,
            ARRAY[e.edge_id] AS edges,
            e.amount AS total_amt,
            e.asset_id AS edge_asset,
            e.transferred_at AS earliest,
            e.transferred_at AS latest,
            1 AS depth
        FROM risk.transfer_edges e
        WHERE e.transferred_at >= p_window_start
          AND e.transferred_at <= p_window_end
          AND (p_tenant_id IS NULL OR e.tenant_id = p_tenant_id)
          AND (p_asset_id IS NULL OR e.asset_id = p_asset_id)
          AND e.amount >= p_min_amount

        UNION ALL

        -- Recursive: extend path to next hop
        SELECT
            p.start_account,
            e.dest_account_id,
            p.path || e.dest_account_id,
            p.edges || e.edge_id,
            p.total_amt + e.amount,
            p.edge_asset,
            LEAST(p.earliest, e.transferred_at),
            GREATEST(p.latest, e.transferred_at),
            p.depth + 1
        FROM paths p
        JOIN risk.transfer_edges e ON e.source_account_id = p.current_account
        WHERE p.depth < p_max_depth
          AND e.transferred_at >= p_window_start
          AND e.transferred_at <= p_window_end
          AND e.asset_id = p.edge_asset  -- same asset throughout cycle
          AND e.amount >= p_min_amount
          -- Prevent revisiting intermediate nodes (but allow returning to start)
          AND (e.dest_account_id = p.start_account
               OR NOT (e.dest_account_id = ANY(p.path)))
    )
    -- Select only completed cycles (returned to start)
    SELECT
        p.path,
        p.edges,
        p.depth,
        p.total_amt,
        p.edge_asset,
        p.earliest,
        p.latest
    FROM paths p
    WHERE p.current_account = p.start_account
      AND p.depth >= 2;  -- minimum 2 hops for a meaningful cycle
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- Generate alerts from detected cycles
-- =============================================================================

CREATE OR REPLACE FUNCTION risk.generate_alerts(
    p_tenant_id UUID DEFAULT NULL,
    p_window_start TIMESTAMPTZ DEFAULT now() - INTERVAL '24 hours',
    p_window_end TIMESTAMPTZ DEFAULT now(),
    p_max_depth INTEGER DEFAULT 6,
    p_min_amount NUMERIC DEFAULT 0
) RETURNS INTEGER AS $$
DECLARE
    v_cycle RECORD;
    v_fingerprint TEXT;
    v_evidence TEXT;
    v_edge_details JSONB;
    v_count INTEGER := 0;
    v_severity TEXT;
BEGIN
    -- Sync latest trades into transfer graph
    PERFORM risk.sync_trade_edges(p_tenant_id);

    FOR v_cycle IN
        SELECT * FROM risk.detect_cycles(
            p_tenant_id, p_window_start, p_window_end, p_max_depth, p_min_amount
        )
    LOOP
        -- Generate fingerprint for idempotency (sorted accounts + asset)
        v_fingerprint := md5(
            array_to_string(
                (SELECT array_agg(x ORDER BY x) FROM unnest(v_cycle.cycle_path[1:array_length(v_cycle.cycle_path,1)-1]) x),
                ','
            ) || ':' || v_cycle.asset_id::TEXT
        );

        -- Build evidence summary
        v_evidence := format(
            'Circular transfer detected: %s accounts, %s edges, total %s in asset %s, window %s to %s',
            v_cycle.cycle_length,
            array_length(v_cycle.cycle_edges, 1),
            v_cycle.total_amount,
            v_cycle.asset_id,
            v_cycle.earliest_transfer,
            v_cycle.latest_transfer
        );

        -- Build edge details
        SELECT jsonb_agg(jsonb_build_object(
            'edge_id', e.edge_id,
            'from', e.source_account_id,
            'to', e.dest_account_id,
            'amount', e.amount,
            'time', e.transferred_at
        ) ORDER BY e.transferred_at)
        INTO v_edge_details
        FROM risk.transfer_edges e
        WHERE e.edge_id = ANY(v_cycle.cycle_edges);

        -- Determine severity
        IF v_cycle.cycle_length >= 4 OR v_cycle.total_amount > 10000 THEN
            v_severity := 'high';
        ELSIF v_cycle.cycle_length >= 3 OR v_cycle.total_amount > 1000 THEN
            v_severity := 'medium';
        ELSE
            v_severity := 'low';
        END IF;

        -- Use tenant from first account if not specified
        DECLARE
            v_alert_tenant UUID;
        BEGIN
            IF p_tenant_id IS NOT NULL THEN
                v_alert_tenant := p_tenant_id;
            ELSE
                SELECT tenant_id INTO v_alert_tenant
                FROM core.trading_accounts
                WHERE account_id = v_cycle.cycle_path[1];
            END IF;

            INSERT INTO risk.alerts (
                tenant_id, rule_name, rule_version, severity,
                cycle_accounts, cycle_edges, cycle_length,
                total_amount, asset_id,
                window_start, window_end,
                evidence_summary, edge_details,
                cycle_fingerprint
            ) VALUES (
                v_alert_tenant, 'circular_transfer', 1, v_severity,
                v_cycle.cycle_path, v_cycle.cycle_edges, v_cycle.cycle_length,
                v_cycle.total_amount, v_cycle.asset_id,
                v_cycle.earliest_transfer, v_cycle.latest_transfer,
                v_evidence, COALESCE(v_edge_details, '[]'::jsonb),
                v_fingerprint
            )
            ON CONFLICT (cycle_fingerprint) DO NOTHING;

            IF FOUND THEN
                v_count := v_count + 1;
            END IF;
        END;
    END LOOP;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql;
