-- VerityTick Migration V008b
-- Fix: Fraud recursive CTE types and tick deterministic sequence ordering
--
-- 1. Ensure risk.detect_cycles casts numeric amounts consistently across
--    anchor and recursive terms to prevent Postgres DatatypeMismatch error.
-- 2. Add monotonic tick_seq to market_data.ticks and tie-break candle open/close
--    using (event_time, tick_seq) rather than random UUID.

-- =============================================================================
-- 1. Fix risk.detect_cycles recursive CTE
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
    total_amount NUMERIC(30, 18),
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
            CAST(e.amount AS NUMERIC(30, 18)) AS total_amt,
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
            CAST(p.total_amt + e.amount AS NUMERIC(30, 18)),
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
      AND p.depth >= 2;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- 2. Add sequence to market_data.ticks and update refresh_candles
-- =============================================================================

ALTER TABLE market_data.ticks
    ADD COLUMN IF NOT EXISTS tick_seq BIGINT GENERATED ALWAYS AS IDENTITY;

CREATE OR REPLACE FUNCTION market_data.refresh_candles(
    p_market_id UUID DEFAULT NULL,
    p_from TIMESTAMPTZ DEFAULT now() - INTERVAL '1 hour',
    p_to TIMESTAMPTZ DEFAULT now()
) RETURNS TABLE (
    interval_name TEXT,
    buckets_updated INTEGER
) AS $$
DECLARE
    v_1m_count INTEGER := 0;
    v_5m_count INTEGER := 0;
    v_1h_count INTEGER := 0;
BEGIN
    -- 1-minute candles
    INSERT INTO market_data.candles_1m (
        market_id, bucket, open_price, high_price, low_price, close_price,
        volume, tick_count, first_tick_time, last_tick_time, updated_at
    )
    SELECT
        t.market_id,
        date_trunc('minute', t.event_time) AS bucket,
        (array_agg(t.price ORDER BY t.event_time ASC, t.tick_seq ASC))[1] AS open_price,
        MAX(t.price) AS high_price,
        MIN(t.price) AS low_price,
        (array_agg(t.price ORDER BY t.event_time DESC, t.tick_seq DESC))[1] AS close_price,
        SUM(t.quantity) AS volume,
        COUNT(*)::INTEGER AS tick_count,
        MIN(t.event_time) AS first_tick_time,
        MAX(t.event_time) AS last_tick_time,
        now()
    FROM market_data.ticks t
    WHERE t.event_time >= date_trunc('minute', p_from)
      AND t.event_time < date_trunc('minute', p_to) + INTERVAL '1 minute'
      AND (p_market_id IS NULL OR t.market_id = p_market_id)
    GROUP BY t.market_id, date_trunc('minute', t.event_time)
    ON CONFLICT (market_id, bucket)
    DO UPDATE SET
        open_price = EXCLUDED.open_price,
        high_price = EXCLUDED.high_price,
        low_price = EXCLUDED.low_price,
        close_price = EXCLUDED.close_price,
        volume = EXCLUDED.volume,
        tick_count = EXCLUDED.tick_count,
        first_tick_time = EXCLUDED.first_tick_time,
        last_tick_time = EXCLUDED.last_tick_time,
        updated_at = now();

    GET DIAGNOSTICS v_1m_count = ROW_COUNT;

    -- 5-minute candles
    INSERT INTO market_data.candles_5m (
        market_id, bucket, open_price, high_price, low_price, close_price,
        volume, tick_count, first_tick_time, last_tick_time, updated_at
    )
    SELECT
        t.market_id,
        date_trunc('hour', t.event_time) +
            (EXTRACT(minute FROM t.event_time)::integer / 5 * 5) * INTERVAL '1 minute' AS bucket,
        (array_agg(t.price ORDER BY t.event_time ASC, t.tick_seq ASC))[1],
        MAX(t.price),
        MIN(t.price),
        (array_agg(t.price ORDER BY t.event_time DESC, t.tick_seq DESC))[1],
        SUM(t.quantity),
        COUNT(*)::INTEGER,
        MIN(t.event_time),
        MAX(t.event_time),
        now()
    FROM market_data.ticks t
    WHERE t.event_time >= date_trunc('hour', p_from) +
            (EXTRACT(minute FROM p_from)::integer / 5 * 5) * INTERVAL '1 minute'
      AND t.event_time < date_trunc('hour', p_to) +
            (EXTRACT(minute FROM p_to)::integer / 5 * 5 + 5) * INTERVAL '1 minute'
      AND (p_market_id IS NULL OR t.market_id = p_market_id)
    GROUP BY t.market_id,
             date_trunc('hour', t.event_time) +
                (EXTRACT(minute FROM t.event_time)::integer / 5 * 5) * INTERVAL '1 minute'
    ON CONFLICT (market_id, bucket)
    DO UPDATE SET
        open_price = EXCLUDED.open_price,
        high_price = EXCLUDED.high_price,
        low_price = EXCLUDED.low_price,
        close_price = EXCLUDED.close_price,
        volume = EXCLUDED.volume,
        tick_count = EXCLUDED.tick_count,
        first_tick_time = EXCLUDED.first_tick_time,
        last_tick_time = EXCLUDED.last_tick_time,
        updated_at = now();

    GET DIAGNOSTICS v_5m_count = ROW_COUNT;

    -- 1-hour candles
    INSERT INTO market_data.candles_1h (
        market_id, bucket, open_price, high_price, low_price, close_price,
        volume, tick_count, first_tick_time, last_tick_time, updated_at
    )
    SELECT
        t.market_id,
        date_trunc('hour', t.event_time) AS bucket,
        (array_agg(t.price ORDER BY t.event_time ASC, t.tick_seq ASC))[1],
        MAX(t.price),
        MIN(t.price),
        (array_agg(t.price ORDER BY t.event_time DESC, t.tick_seq DESC))[1],
        SUM(t.quantity),
        COUNT(*)::INTEGER,
        MIN(t.event_time),
        MAX(t.event_time),
        now()
    FROM market_data.ticks t
    WHERE t.event_time >= date_trunc('hour', p_from)
      AND t.event_time < date_trunc('hour', p_to) + INTERVAL '1 hour'
      AND (p_market_id IS NULL OR t.market_id = p_market_id)
    GROUP BY t.market_id, date_trunc('hour', t.event_time)
    ON CONFLICT (market_id, bucket)
    DO UPDATE SET
        open_price = EXCLUDED.open_price,
        high_price = EXCLUDED.high_price,
        low_price = EXCLUDED.low_price,
        close_price = EXCLUDED.close_price,
        volume = EXCLUDED.volume,
        tick_count = EXCLUDED.tick_count,
        first_tick_time = EXCLUDED.first_tick_time,
        last_tick_time = EXCLUDED.last_tick_time,
        updated_at = now();

    GET DIAGNOSTICS v_1h_count = ROW_COUNT;

    RETURN QUERY VALUES
        ('1m'::TEXT, v_1m_count),
        ('5m'::TEXT, v_5m_count),
        ('1h'::TEXT, v_1h_count);
END;
$$ LANGUAGE plpgsql;
