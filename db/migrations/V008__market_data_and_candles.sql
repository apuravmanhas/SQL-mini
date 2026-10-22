-- VerityTick Migration V008
-- Market Data: Tick Ingestion and OHLCV Candlesticks
--
-- Implements:
-- - Partitioned tick data table (by month)
-- - Source event deduplication
-- - OHLCV candle tables for 1m, 5m, 1h intervals
-- - Incremental candle refresh function
-- - Late-arriving data handling

-- =============================================================================
-- Tick Events (partitioned by month)
-- =============================================================================

CREATE TABLE market_data.ticks (
    tick_id             UUID NOT NULL DEFAULT gen_random_uuid(),
    market_id           UUID NOT NULL REFERENCES core.markets(market_id),
    source_event_id     TEXT NOT NULL,
    event_time          TIMESTAMPTZ NOT NULL,
    ingestion_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    price               NUMERIC(30, 18) NOT NULL CHECK (price > 0),
    quantity            NUMERIC(30, 18) NOT NULL CHECK (quantity > 0),
    trade_id            UUID REFERENCES trading.trades(trade_id),
    source              TEXT DEFAULT 'internal',

    PRIMARY KEY (event_time, tick_id)
) PARTITION BY RANGE (event_time);

-- Deduplication index (must include partition key)
CREATE UNIQUE INDEX idx_ticks_source_dedup
    ON market_data.ticks (market_id, source_event_id, event_time);

-- Query index
CREATE INDEX idx_ticks_market_time
    ON market_data.ticks (market_id, event_time);

COMMENT ON TABLE market_data.ticks IS
    'Time-series tick data, partitioned by month. Deduplicated by source_event_id.';
COMMENT ON COLUMN market_data.ticks.source_event_id IS
    'Unique identifier from the source. Repeated source events are rejected.';

-- =============================================================================
-- Create partitions for current and next months
-- =============================================================================

DO $$
DECLARE
    v_start DATE;
    v_end DATE;
    v_partition_name TEXT;
BEGIN
    -- Create partitions for 3 months back through 3 months forward
    FOR i IN -3..3 LOOP
        v_start := date_trunc('month', CURRENT_DATE + (i || ' months')::interval)::date;
        v_end := date_trunc('month', CURRENT_DATE + ((i + 1) || ' months')::interval)::date;
        v_partition_name := 'ticks_' || to_char(v_start, 'YYYY_MM');

        -- Check if partition exists
        IF NOT EXISTS (
            SELECT 1 FROM pg_class c
            JOIN pg_namespace n ON c.relnamespace = n.oid
            WHERE n.nspname = 'market_data'
              AND c.relname = v_partition_name
        ) THEN
            EXECUTE format(
                'CREATE TABLE market_data.%I PARTITION OF market_data.ticks
                 FOR VALUES FROM (%L) TO (%L)',
                v_partition_name, v_start, v_end
            );
        END IF;
    END LOOP;
END $$;

-- =============================================================================
-- OHLCV Candle Tables
-- =============================================================================

CREATE TABLE market_data.candles_1m (
    market_id       UUID NOT NULL REFERENCES core.markets(market_id),
    bucket          TIMESTAMPTZ NOT NULL,
    open_price      NUMERIC(30, 18) NOT NULL,
    high_price      NUMERIC(30, 18) NOT NULL,
    low_price       NUMERIC(30, 18) NOT NULL,
    close_price     NUMERIC(30, 18) NOT NULL,
    volume          NUMERIC(30, 18) NOT NULL DEFAULT 0,
    tick_count      INTEGER NOT NULL DEFAULT 0,
    first_tick_time TIMESTAMPTZ NOT NULL,
    last_tick_time  TIMESTAMPTZ NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (market_id, bucket)
);

CREATE TABLE market_data.candles_5m (
    market_id       UUID NOT NULL REFERENCES core.markets(market_id),
    bucket          TIMESTAMPTZ NOT NULL,
    open_price      NUMERIC(30, 18) NOT NULL,
    high_price      NUMERIC(30, 18) NOT NULL,
    low_price       NUMERIC(30, 18) NOT NULL,
    close_price     NUMERIC(30, 18) NOT NULL,
    volume          NUMERIC(30, 18) NOT NULL DEFAULT 0,
    tick_count      INTEGER NOT NULL DEFAULT 0,
    first_tick_time TIMESTAMPTZ NOT NULL,
    last_tick_time  TIMESTAMPTZ NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (market_id, bucket)
);

CREATE TABLE market_data.candles_1h (
    market_id       UUID NOT NULL REFERENCES core.markets(market_id),
    bucket          TIMESTAMPTZ NOT NULL,
    open_price      NUMERIC(30, 18) NOT NULL,
    high_price      NUMERIC(30, 18) NOT NULL,
    low_price       NUMERIC(30, 18) NOT NULL,
    close_price     NUMERIC(30, 18) NOT NULL,
    volume          NUMERIC(30, 18) NOT NULL DEFAULT 0,
    tick_count      INTEGER NOT NULL DEFAULT 0,
    first_tick_time TIMESTAMPTZ NOT NULL,
    last_tick_time  TIMESTAMPTZ NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (market_id, bucket)
);

COMMENT ON TABLE market_data.candles_1m IS '1-minute OHLCV candlesticks';
COMMENT ON TABLE market_data.candles_5m IS '5-minute OHLCV candlesticks';
COMMENT ON TABLE market_data.candles_1h IS '1-hour OHLCV candlesticks';

-- =============================================================================
-- Ingest a tick from a trade
-- =============================================================================

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

-- =============================================================================
-- Refresh candles for affected buckets (incremental)
-- =============================================================================

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
        (array_agg(t.price ORDER BY t.event_time ASC, t.tick_id ASC))[1] AS open_price,
        MAX(t.price) AS high_price,
        MIN(t.price) AS low_price,
        (array_agg(t.price ORDER BY t.event_time DESC, t.tick_id DESC))[1] AS close_price,
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
        (array_agg(t.price ORDER BY t.event_time ASC, t.tick_id ASC))[1],
        MAX(t.price),
        MIN(t.price),
        (array_agg(t.price ORDER BY t.event_time DESC, t.tick_id DESC))[1],
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
        (array_agg(t.price ORDER BY t.event_time ASC, t.tick_id ASC))[1],
        MAX(t.price),
        MIN(t.price),
        (array_agg(t.price ORDER BY t.event_time DESC, t.tick_id DESC))[1],
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
