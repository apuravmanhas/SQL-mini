-- VerityTick Migration V003
-- Trading Orders Schema
--
-- Implements the order book with:
-- - Limit buy/sell orders
-- - Price-time priority via atomic market sequence
-- - Lifecycle states: open, partially_filled, filled, cancelled
-- - Idempotency keys for safe retries
-- - Append-only order event history

-- =============================================================================
-- Orders
-- =============================================================================

CREATE TABLE trading.orders (
    order_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES core.tenants(tenant_id),
    account_id          UUID NOT NULL REFERENCES core.trading_accounts(account_id),
    market_id           UUID NOT NULL REFERENCES core.markets(market_id),

    -- Order parameters
    side                TEXT NOT NULL CHECK (side IN ('buy', 'sell')),
    order_type          TEXT NOT NULL DEFAULT 'limit' CHECK (order_type IN ('limit')),
    limit_price         NUMERIC(30, 18) NOT NULL CHECK (limit_price > 0),
    original_quantity   NUMERIC(30, 18) NOT NULL CHECK (original_quantity > 0),
    remaining_quantity  NUMERIC(30, 18) NOT NULL CHECK (remaining_quantity >= 0),

    -- Lifecycle
    status              TEXT NOT NULL DEFAULT 'open'
                        CHECK (status IN ('open', 'partially_filled', 'filled', 'cancelled')),

    -- Priority: assigned atomically from market.next_priority_seq
    priority_seq        BIGINT NOT NULL,

    -- Idempotency: client-provided key to prevent duplicate submissions
    idempotency_key     TEXT,

    -- Timestamps
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    cancelled_at        TIMESTAMPTZ,

    -- Invariant: remaining can never exceed original
    CONSTRAINT chk_remaining_lte_original
        CHECK (remaining_quantity <= original_quantity),

    -- Invariant: filled orders have zero remaining
    CONSTRAINT chk_filled_zero_remaining
        CHECK (status != 'filled' OR remaining_quantity = 0),

    -- Invariant: cancelled orders record cancellation time
    CONSTRAINT chk_cancelled_has_timestamp
        CHECK (status != 'cancelled' OR cancelled_at IS NOT NULL),

    -- Invariant: open orders have positive remaining
    CONSTRAINT chk_open_has_remaining
        CHECK (status NOT IN ('open', 'partially_filled') OR remaining_quantity > 0)
);

-- Idempotency: unique per account
CREATE UNIQUE INDEX idx_orders_idempotency
    ON trading.orders (account_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

-- Matching queries: find eligible resting orders by market, side, price, priority
CREATE INDEX idx_orders_buy_book
    ON trading.orders (market_id, limit_price DESC, priority_seq ASC)
    WHERE side = 'buy' AND status IN ('open', 'partially_filled');

CREATE INDEX idx_orders_sell_book
    ON trading.orders (market_id, limit_price ASC, priority_seq ASC)
    WHERE side = 'sell' AND status IN ('open', 'partially_filled');

-- Tenant lookup
CREATE INDEX idx_orders_tenant ON trading.orders (tenant_id);

-- Account lookup
CREATE INDEX idx_orders_account ON trading.orders (account_id);

COMMENT ON TABLE trading.orders IS
    'Limit orders in the order book. Matched by the trading engine under price-time priority.';
COMMENT ON COLUMN trading.orders.priority_seq IS
    'Market-specific monotonic sequence for deterministic time priority';
COMMENT ON COLUMN trading.orders.idempotency_key IS
    'Client-provided key. Same key + account = same order (no duplicate).';

-- =============================================================================
-- Order Events (append-only history)
-- =============================================================================

CREATE TABLE trading.order_events (
    event_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id        UUID NOT NULL REFERENCES trading.orders(order_id),
    event_type      TEXT NOT NULL
                    CHECK (event_type IN (
                        'accepted', 'rejected', 'partially_filled',
                        'filled', 'cancelled', 'cancel_rejected'
                    )),
    -- For fill events: trade details
    trade_id        UUID,
    fill_quantity   NUMERIC(30, 18),
    fill_price      NUMERIC(30, 18),
    remaining_after NUMERIC(30, 18),

    -- Context
    details         JSONB DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_order_events_order ON trading.order_events (order_id, created_at);

COMMENT ON TABLE trading.order_events IS
    'Immutable event log tracking every order state transition';

-- =============================================================================
-- Trades
-- =============================================================================

CREATE TABLE trading.trades (
    trade_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    market_id           UUID NOT NULL REFERENCES core.markets(market_id),

    -- Buyer side
    buy_order_id        UUID NOT NULL REFERENCES trading.orders(order_id),
    buy_account_id      UUID NOT NULL REFERENCES core.trading_accounts(account_id),

    -- Seller side
    sell_order_id       UUID NOT NULL REFERENCES trading.orders(order_id),
    sell_account_id     UUID NOT NULL REFERENCES core.trading_accounts(account_id),

    -- Execution
    price               NUMERIC(30, 18) NOT NULL CHECK (price > 0),
    quantity            NUMERIC(30, 18) NOT NULL CHECK (quantity > 0),

    -- Timestamps
    executed_at         TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Both orders must be in the same market (enforced by logic, FK gives base check)
    CONSTRAINT chk_different_orders
        CHECK (buy_order_id != sell_order_id),
    CONSTRAINT chk_different_accounts
        CHECK (buy_account_id != sell_account_id)
);

CREATE INDEX idx_trades_market ON trading.trades (market_id, executed_at);
CREATE INDEX idx_trades_buy_order ON trading.trades (buy_order_id);
CREATE INDEX idx_trades_sell_order ON trading.trades (sell_order_id);

COMMENT ON TABLE trading.trades IS
    'Executed trade between a buy and sell order. Both sides at same price and quantity.';
