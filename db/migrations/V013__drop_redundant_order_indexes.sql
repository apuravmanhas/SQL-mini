-- VerityTick Migration V013
-- Remove redundant order-book indexes
--
-- V003 already defines partial indexes with the same keys and predicates:
--     idx_orders_sell_book (market_id, limit_price ASC,  priority_seq ASC)
--     idx_orders_buy_book  (market_id, limit_price DESC, priority_seq ASC)
--     WHERE status IN ('open', 'partially_filled') AND side = <side>
--
-- V010 added idx_orders_matching_sell_cov / idx_orders_matching_buy_cov with
-- the same keys and predicates plus INCLUDE columns. EXPLAIN (ANALYZE, BUFFERS)
-- on a 500,000-row book shows the planner using the V003 indexes, and the
-- matching query locks rows with FOR UPDATE, which needs the heap tuple anyway,
-- so the INCLUDE columns cannot enable an index-only scan. The V010 indexes only
-- add write cost to every order insert and status change.

DROP INDEX IF EXISTS trading.idx_orders_matching_sell_cov;
DROP INDEX IF EXISTS trading.idx_orders_matching_buy_cov;
