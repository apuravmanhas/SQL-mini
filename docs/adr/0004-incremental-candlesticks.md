# ADR 0004: Incremental Time-Bucket Aggregation for OHLCV Candlesticks

## Context
Market data consumers require 1-minute, 5-minute, and 1-hour OHLCV candles. Materialized views in PostgreSQL require full refreshes, which become unacceptably slow as tick tables grow to millions of rows.

## Decision
We maintain physical candlestick tables (`market_data.candles_1m`, `candles_5m`, `candles_1h`) and implement an incremental upsert routine (`market_data.refresh_candles`) restricted to time buckets impacted by newly arrived or corrected ticks. Open/close prices are determined deterministically using `(event_time, tick_seq)`.

## Consequences
- Fast updates (~170+ bucket rollups/second) without scanning historical data.
- Gracefully accommodates late-arriving trade corrections by re-aggregating only the affected time buckets.
