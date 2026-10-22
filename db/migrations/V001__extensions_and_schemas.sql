-- VerityTick Migration V001
-- Extensions and Schema Namespaces
--
-- Creates the foundational PostgreSQL schemas and enables required extensions.
-- Each schema has a clear responsibility boundary.

-- =============================================================================
-- Extensions
-- =============================================================================

-- pgcrypto: SHA-256 hashing for audit chain, UUID generation
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =============================================================================
-- Schemas
-- =============================================================================

-- core: tenants, users, market definitions, reference data
CREATE SCHEMA IF NOT EXISTS core;
COMMENT ON SCHEMA core IS 'Tenant, user, market, and reference data';

-- trading: orders, executions, order events, matching functions
CREATE SCHEMA IF NOT EXISTS trading;
COMMENT ON SCHEMA trading IS 'Order book, matching engine, and trade records';

-- ledger: financial accounts, journal entries, balance tracking
CREATE SCHEMA IF NOT EXISTS ledger;
COMMENT ON SCHEMA ledger IS 'Double-entry financial ledger and balance management';

-- audit: tamper-evident event log with hash chain
CREATE SCHEMA IF NOT EXISTS audit;
COMMENT ON SCHEMA audit IS 'Hash-chained audit trail and verification';

-- risk: fraud detection, alerts, investigations
CREATE SCHEMA IF NOT EXISTS risk;
COMMENT ON SCHEMA risk IS 'Suspicious pattern detection and risk alerts';

-- market_data: tick events, partitioned tables, OHLCV candles
CREATE SCHEMA IF NOT EXISTS market_data;
COMMENT ON SCHEMA market_data IS 'Time-series tick data and candlestick aggregation';
