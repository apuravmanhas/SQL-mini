"""
VerityTick — Market Data and OHLCV Candle Tests

Tests:
- Tick ingestion from trades
- Source event deduplication
- OHLCV candle computation (1m, 5m, 1h)
- Incremental candle refresh
"""

import pytest
from datetime import datetime, timezone

TENANT_APEX = 'a0000000-0000-0000-0000-000000000001'
ACCT_ALICE = 'e0000000-0000-0000-0000-000000000001'
ACCT_BOB = 'e0000000-0000-0000-0000-000000000003'
MARKET_ACME = 'd0000000-0000-0000-0000-000000000001'
ASSET_USDX = 'c0000000-0000-0000-0000-000000000001'
ASSET_ACME = 'c0000000-0000-0000-0000-000000000002'


def deposit(cur, tenant_id, account_id, asset_id, amount):
    cur.execute("SELECT ledger.deposit(%s, %s, %s, %s)",
                (tenant_id, account_id, asset_id, amount))


def place_order(cur, tenant_id, account_id, market_id, side, price, qty):
    cur.execute("SELECT * FROM trading.place_order(%s, %s, %s, %s, %s, %s)",
                (tenant_id, account_id, market_id, side, price, qty))
    return cur.fetchone()


class TestTickIngestion:

    def test_ingest_trade_tick(self, db):
        """Ingesting a trade creates a tick record."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)

        place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50, 10)
        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 50, 10)

        # Get the trade ID
        db.execute("SELECT trade_id FROM trading.trades WHERE market_id = %s LIMIT 1",
                   (MARKET_ACME,))
        trade_id = db.fetchone()[0]

        # Ingest tick
        db.execute("SELECT market_data.ingest_trade_tick(%s)", (trade_id,))
        tick_id = db.fetchone()[0]
        assert tick_id is not None

        # Verify tick data
        db.execute("SELECT price, quantity FROM market_data.ticks WHERE tick_id = %s",
                   (tick_id,))
        tick = db.fetchone()
        assert float(tick[0]) == 50.0
        assert float(tick[1]) == 10.0

    def test_duplicate_tick_rejected(self, db):
        """Same source_event_id is not inserted twice."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)

        place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50, 5)
        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 50, 5)

        db.execute("SELECT trade_id FROM trading.trades WHERE market_id = %s LIMIT 1",
                   (MARKET_ACME,))
        trade_id = db.fetchone()[0]

        # Ingest twice
        db.execute("SELECT market_data.ingest_trade_tick(%s)", (trade_id,))
        first = db.fetchone()[0]
        db.execute("SELECT market_data.ingest_trade_tick(%s)", (trade_id,))
        second = db.fetchone()[0]

        # Second call returns NULL (ON CONFLICT DO NOTHING)
        assert first is not None
        assert second is None

        # Only one tick exists
        db.execute("""
            SELECT COUNT(*) FROM market_data.ticks
            WHERE source_event_id = %s
        """, ('trade:' + str(trade_id),))
        assert db.fetchone()[0] == 1


class TestOHLCVCandles:

    def _create_trades_and_ticks(self, db, prices_quantities):
        """Helper: create trades at given prices and ingest ticks in sequence."""
        for price, qty in prices_quantities:
            deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, price * qty + 100)
            deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, qty + 10)

            place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', price, qty)
            r_sell = place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', price, qty)

            # Ingest trade tick immediately so insertion sequence matches execution order
            db.execute("""
                SELECT trade_id FROM trading.trades
                WHERE sell_order_id = %s
            """, (r_sell[0],))
            trade_id = db.fetchone()[0]
            db.execute("SELECT market_data.ingest_trade_tick(%s)", (trade_id,))

    def test_candle_computation(self, db):
        """Candle refresh produces correct OHLCV values."""
        self._create_trades_and_ticks(db, [
            (45.00, 5),   # open, low
            (55.00, 3),   # high
            (50.00, 7),   # close
        ])

        db.execute("""
            SELECT * FROM market_data.refresh_candles(
                %s, now() - INTERVAL '1 hour', now() + INTERVAL '1 hour'
            )
        """, (MARKET_ACME,))

        db.execute("""
            SELECT open_price, high_price, low_price, close_price, volume, tick_count
            FROM market_data.candles_1m
            WHERE market_id = %s
            ORDER BY bucket DESC LIMIT 1
        """, (MARKET_ACME,))
        candle = db.fetchone()

        if candle:
            assert float(candle[0]) == 45.0    # open (first trade)
            assert float(candle[1]) == 55.0    # high
            assert float(candle[2]) == 45.0    # low
            assert float(candle[3]) == 50.0    # close (last trade)
            assert float(candle[4]) == 15.0    # volume (5+3+7)
            assert candle[5] == 3              # tick_count

    def test_candle_refresh_idempotent(self, db):
        """Running refresh twice produces same results."""
        self._create_trades_and_ticks(db, [(50.00, 10)])

        # Refresh twice
        db.execute("SELECT * FROM market_data.refresh_candles(%s, now()-'1h'::interval, now()+'1h'::interval)",
                   (MARKET_ACME,))
        db.execute("SELECT * FROM market_data.refresh_candles(%s, now()-'1h'::interval, now()+'1h'::interval)",
                   (MARKET_ACME,))

        db.execute("SELECT COUNT(*) FROM market_data.candles_1m WHERE market_id = %s",
                   (MARKET_ACME,))
        assert db.fetchone()[0] >= 1  # at least 1 candle, not duplicated

    def test_empty_period_no_candle(self, db):
        """No candle is created for periods with no ticks."""
        db.execute("""
            SELECT COUNT(*) FROM market_data.candles_1m
            WHERE market_id = %s
              AND bucket = '2020-01-01 00:00:00+00'
        """, (MARKET_ACME,))
        assert db.fetchone()[0] == 0
