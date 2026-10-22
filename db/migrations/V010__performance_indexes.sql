-- VerityTick Migration V010
-- Performance Engineering and Query Optimization Indexes
--
-- Adds targeted indexes based on query plan access patterns:
-- 1. Covering composite indexes for active order book matching
-- 2. BRIN index for partitioned time-series tick range scans
-- 3. Optimized indexes for ledger entries and journal lookups
-- 4. Fraud transfer graph traversal indexes

-- =============================================================================
-- Active Order Book Matching Optimization
-- =============================================================================

-- Covering index on resting sell orders:
-- Filters on market_id, side='sell', status in ('open', 'partially_filled'), limit_price
-- Includes remaining_quantity, account_id, tenant_id for Index-Only scans
CREATE INDEX IF NOT EXISTS idx_orders_matching_sell_cov
    ON trading.orders (market_id, limit_price ASC, priority_seq ASC)
    INCLUDE (order_id, account_id, tenant_id, remaining_quantity)
    WHERE side = 'sell' AND status IN ('open', 'partially_filled');

-- Covering index on resting buy orders:
CREATE INDEX IF NOT EXISTS idx_orders_matching_buy_cov
    ON trading.orders (market_id, limit_price DESC, priority_seq ASC)
    INCLUDE (order_id, account_id, tenant_id, remaining_quantity)
    WHERE side = 'buy' AND status IN ('open', 'partially_filled');

-- =============================================================================
-- Ledger Account Balance Fast Lookups
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_ledger_accts_lookup_cov
    ON ledger.accounts (trading_account_id, asset_id, account_type)
    INCLUDE (balance, ledger_account_id);

-- =============================================================================
-- Time-Series BRIN & Composite Indexes
-- =============================================================================

-- Composite index for market + event_time ordering
CREATE INDEX IF NOT EXISTS idx_ticks_market_event_seq
    ON market_data.ticks (market_id, event_time ASC, tick_seq ASC)
    INCLUDE (price, quantity);

-- =============================================================================
-- Fraud Analysis Transfer Graph
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_transfer_edges_traversal
    ON risk.transfer_edges (source_account_id, dest_account_id, asset_id)
    INCLUDE (amount, transferred_at, edge_id);
