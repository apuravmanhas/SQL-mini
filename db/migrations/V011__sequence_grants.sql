-- VerityTick Migration V011
-- Sequence Usage Grants for Application Role
--
-- V009 granted table privileges to vt_app but omitted sequence usage.
-- Tables with GENERATED ALWAYS AS IDENTITY columns (e.g. market_data.ticks.tick_seq)
-- require USAGE on the underlying sequence for INSERT operations.

GRANT USAGE ON ALL SEQUENCES IN SCHEMA core TO vt_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA trading TO vt_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA ledger TO vt_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA audit TO vt_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA risk TO vt_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA market_data TO vt_app;
