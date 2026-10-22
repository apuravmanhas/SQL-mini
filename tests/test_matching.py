"""
VerityTick — Matching Engine Tests

Tests the core trading.place_order() and trading.cancel_order() functions:
- Order placement and validation
- Price-time priority matching
- Partial fills and multiple counterparties
- Cancellation
- Idempotency
- Balance reservation and settlement
- Ledger integrity after trades
"""

import pytest
import psycopg2

# ─── Seed data IDs ──────────────────────────────────────────────────────
TENANT_APEX = 'a0000000-0000-0000-0000-000000000001'
TENANT_MERIDIAN = 'a0000000-0000-0000-0000-000000000002'
ACCT_ALICE = 'e0000000-0000-0000-0000-000000000001'   # Apex
ACCT_BOB = 'e0000000-0000-0000-0000-000000000003'     # Apex
ACCT_CHARLIE = 'e0000000-0000-0000-0000-000000000004' # Apex
ACCT_DIANA = 'e0000000-0000-0000-0000-000000000005'   # Meridian
ACCT_EVAN = 'e0000000-0000-0000-0000-000000000006'    # Meridian
MARKET_ACME = 'd0000000-0000-0000-0000-000000000001'  # ACME/USDX
MARKET_BOLT = 'd0000000-0000-0000-0000-000000000002'  # BOLT/USDX
ASSET_USDX = 'c0000000-0000-0000-0000-000000000001'
ASSET_ACME = 'c0000000-0000-0000-0000-000000000002'


def deposit(cur, tenant_id, account_id, asset_id, amount):
    """Helper: deposit funds into a trading account."""
    cur.execute(
        "SELECT ledger.deposit(%s, %s, %s, %s)",
        (tenant_id, account_id, asset_id, amount)
    )


def place_order(cur, tenant_id, account_id, market_id, side, price, qty, idem_key=None):
    """Helper: place an order and return result row."""
    cur.execute(
        "SELECT * FROM trading.place_order(%s, %s, %s, %s, %s, %s, %s)",
        (tenant_id, account_id, market_id, side, price, qty, idem_key)
    )
    return cur.fetchone()


def cancel_order(cur, tenant_id, order_id):
    """Helper: cancel an order and return result row."""
    cur.execute(
        "SELECT * FROM trading.cancel_order(%s, %s)",
        (tenant_id, order_id)
    )
    return cur.fetchone()


class TestOrderValidation:

    def test_reject_nonexistent_market(self, db):
        """Order to a nonexistent market must be rejected."""
        result = place_order(db, TENANT_APEX, ACCT_ALICE,
                             'ffffffff-ffff-ffff-ffff-ffffffffffff', 'buy', 100, 1)
        assert result[1] == 'rejected'
        assert 'not found' in result[4].lower()

    def test_reject_halted_market(self, db):
        """Order to a halted market must be rejected."""
        db.execute("UPDATE core.markets SET status = 'halted' WHERE market_id = %s",
                   (MARKET_ACME,))
        result = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 100, 1)
        assert result[1] == 'rejected'
        assert 'halted' in result[4].lower()

    def test_reject_wrong_tenant_account(self, db):
        """Order with account not belonging to tenant must be rejected."""
        result = place_order(db, TENANT_APEX, ACCT_DIANA, MARKET_ACME, 'buy', 100, 1)
        assert result[1] == 'rejected'
        assert 'not found' in result[4].lower() or 'not belong' in result[4].lower()

    def test_reject_zero_price(self, db):
        """Zero price must be rejected."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)
        result = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 0, 1)
        assert result[1] == 'rejected'

    def test_reject_zero_quantity(self, db):
        """Zero quantity must be rejected."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)
        result = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 100, 0)
        assert result[1] == 'rejected'

    def test_reject_below_min_quantity(self, db):
        """Quantity below market minimum must be rejected."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)
        result = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 100, 0.00001)
        assert result[1] == 'rejected'

    def test_reject_insufficient_balance(self, db):
        """Order exceeding available balance must be rejected."""
        # Alice has no USDX, trying to buy
        result = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 100, 10)
        assert result[1] == 'rejected'
        assert 'insufficient' in result[4].lower()


class TestBasicMatching:

    def test_buy_no_seller(self, db):
        """Buy order with no seller rests on book."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)
        result = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50.00, 10)
        assert result[1] == 'open'
        assert float(result[2]) == 10.0
        assert result[3] == 0  # no trades

    def test_sell_no_buyer(self, db):
        """Sell order with no buyer rests on book."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_ACME, 100)
        result = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'sell', 50.00, 10)
        assert result[1] == 'open'
        assert float(result[2]) == 10.0
        assert result[3] == 0

    def test_exact_match(self, db):
        """A buy and sell at the same price and quantity fully fill each other."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 5000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)

        # Alice places buy
        r1 = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50.00, 10)
        assert r1[1] == 'open'

        # Bob places sell — should match Alice
        r2 = place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 50.00, 10)
        assert r2[1] == 'filled'
        assert r2[3] == 1  # one trade

        # Verify Alice's order is now filled too
        db.execute("SELECT status, remaining_quantity FROM trading.orders WHERE order_id = %s",
                   (r1[0],))
        alice_order = db.fetchone()
        assert alice_order[0] == 'filled'
        assert float(alice_order[1]) == 0

        # Verify trade exists
        db.execute("SELECT price, quantity FROM trading.trades WHERE market_id = %s", (MARKET_ACME,))
        trade = db.fetchone()
        assert float(trade[0]) == 50.00
        assert float(trade[1]) == 10.0

    def test_partial_fill(self, db):
        """Incoming order partially fills against smaller resting order."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)

        # Bob sells 5 ACME
        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 50.00, 5)

        # Alice buys 10 ACME — should fill 5, rest on book
        result = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50.00, 10)
        assert result[1] == 'partially_filled'
        assert float(result[2]) == 5.0
        assert result[3] == 1

    def test_multiple_counterparties(self, db):
        """Incoming order matches multiple resting orders."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 20000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)
        deposit(db, TENANT_APEX, ACCT_CHARLIE, ASSET_ACME, 100)

        # Bob sells 5 at 48
        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 48.00, 5)
        # Charlie sells 5 at 49
        place_order(db, TENANT_APEX, ACCT_CHARLIE, MARKET_ACME, 'sell', 49.00, 5)

        # Alice buys 10 at 50 — should match both (lowest price first)
        result = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50.00, 10)
        assert result[1] == 'filled'
        assert result[3] == 2  # two trades

        # Verify trade prices
        db.execute("""
            SELECT price, quantity FROM trading.trades
            WHERE market_id = %s ORDER BY price ASC
        """, (MARKET_ACME,))
        trades = db.fetchall()
        assert float(trades[0][0]) == 48.00  # Bob's price
        assert float(trades[1][0]) == 49.00  # Charlie's price


class TestPriceTimePriority:

    def test_best_price_first_for_buy(self, db):
        """Buy order matches lowest-priced sell first."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)
        deposit(db, TENANT_APEX, ACCT_CHARLIE, ASSET_ACME, 100)

        # Charlie sells at 52 (placed first)
        place_order(db, TENANT_APEX, ACCT_CHARLIE, MARKET_ACME, 'sell', 52.00, 5)
        # Bob sells at 50 (placed second, but better price)
        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 50.00, 5)

        # Alice buys 5 — should match Bob (lower price), not Charlie
        result = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 55.00, 5)
        assert result[1] == 'filled'

        db.execute("SELECT sell_account_id, price FROM trading.trades WHERE market_id = %s",
                   (MARKET_ACME,))
        trade = db.fetchone()
        assert str(trade[0]) == ACCT_BOB
        assert float(trade[1]) == 50.00

    def test_time_priority_at_same_price(self, db):
        """At same price, earlier order (lower priority_seq) is matched first."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)
        deposit(db, TENANT_APEX, ACCT_CHARLIE, ASSET_ACME, 100)

        # Bob sells first at 50
        r_bob = place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 50.00, 5)
        # Charlie sells second at 50
        r_charlie = place_order(db, TENANT_APEX, ACCT_CHARLIE, MARKET_ACME, 'sell', 50.00, 5)

        # Alice buys 5 — should match Bob (earlier)
        result = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50.00, 5)
        assert result[1] == 'filled'

        db.execute("SELECT sell_account_id FROM trading.trades WHERE market_id = %s",
                   (MARKET_ACME,))
        trade = db.fetchone()
        assert str(trade[0]) == ACCT_BOB

    def test_execution_price_is_resting(self, db):
        """Trade executes at the resting order's price, not the incoming order's."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)

        # Bob rests a sell at 45
        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 45.00, 5)

        # Alice buys at 50 (willing to pay more) — executes at 45 (resting)
        place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50.00, 5)

        db.execute("SELECT price FROM trading.trades WHERE market_id = %s", (MARKET_ACME,))
        assert float(db.fetchone()[0]) == 45.00


class TestCancellation:

    def test_cancel_open_order(self, db):
        """Open order can be cancelled."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 5000)

        r = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50.00, 10)
        assert r[1] == 'open'

        cr = cancel_order(db, TENANT_APEX, r[0])
        assert cr[1] == 'cancelled'

        # Verify order status in DB
        db.execute("SELECT status, cancelled_at FROM trading.orders WHERE order_id = %s",
                   (r[0],))
        order = db.fetchone()
        assert order[0] == 'cancelled'
        assert order[1] is not None

    def test_cancel_partially_filled(self, db):
        """Partially filled order can be cancelled."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)

        # Alice buys 10
        r = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50.00, 10)

        # Bob sells 3 — partially fills Alice
        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 50.00, 3)

        db.execute("SELECT status FROM trading.orders WHERE order_id = %s", (r[0],))
        assert db.fetchone()[0] == 'partially_filled'

        # Cancel remaining
        cr = cancel_order(db, TENANT_APEX, r[0])
        assert cr[1] == 'cancelled'

    def test_cannot_cancel_filled(self, db):
        """Filled order cannot be cancelled."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 5000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)

        r = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50.00, 10)
        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 50.00, 10)

        cr = cancel_order(db, TENANT_APEX, r[0])
        assert 'cannot cancel' in cr[3].lower() or cr[1] == 'filled'

    def test_cancelled_order_not_matched(self, db):
        """Cancelled order must not be matched by a new incoming order."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 5000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)
        deposit(db, TENANT_APEX, ACCT_CHARLIE, ASSET_ACME, 100)

        # Alice places buy
        r = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50.00, 10)
        # Cancel it
        cancel_order(db, TENANT_APEX, r[0])

        # Bob sells — should NOT match cancelled Alice order
        r2 = place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 50.00, 5)
        assert r2[1] == 'open'
        assert r2[3] == 0  # no trades


class TestIdempotency:

    def test_duplicate_idempotency_key(self, db):
        """Same idempotency key returns existing order without creating duplicate."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)

        r1 = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50.00, 10, 'key-001')
        r2 = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50.00, 10, 'key-001')

        assert r1[0] == r2[0]  # same order_id
        assert 'duplicate' in r2[4].lower() or 'existing' in r2[4].lower()

        # Verify only one order exists
        db.execute("""
            SELECT COUNT(*) FROM trading.orders
            WHERE account_id = %s AND idempotency_key = 'key-001'
        """, (ACCT_ALICE,))
        assert db.fetchone()[0] == 1


class TestLedgerIntegrity:

    def test_balance_after_trade(self, db):
        """After a trade, balances reflect the settlement correctly."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 5000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)

        # Alice buys 10 ACME at 50 from Bob
        place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50.00, 10)
        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 50.00, 10)

        # Alice should have: USDX 5000 - 500 = 4500, ACME 0 + 10 = 10
        db.execute("""
            SELECT balance FROM ledger.accounts
            WHERE trading_account_id = %s AND asset_id = %s AND account_type = 'trading'
        """, (ACCT_ALICE, ASSET_USDX))
        assert float(db.fetchone()[0]) == 4500.0

        db.execute("""
            SELECT balance FROM ledger.accounts
            WHERE trading_account_id = %s AND asset_id = %s AND account_type = 'trading'
        """, (ACCT_ALICE, ASSET_ACME))
        assert float(db.fetchone()[0]) == 10.0

        # Bob should have: ACME 100 - 10 = 90, USDX 0 + 500 = 500
        db.execute("""
            SELECT balance FROM ledger.accounts
            WHERE trading_account_id = %s AND asset_id = %s AND account_type = 'trading'
        """, (ACCT_BOB, ASSET_ACME))
        assert float(db.fetchone()[0]) == 90.0

        db.execute("""
            SELECT balance FROM ledger.accounts
            WHERE trading_account_id = %s AND asset_id = %s AND account_type = 'trading'
        """, (ACCT_BOB, ASSET_USDX))
        assert float(db.fetchone()[0]) == 500.0

    def test_reservation_released_on_cancel(self, db):
        """Cancelling an order releases the reserved funds."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 5000)

        db.execute("SELECT ledger.available_balance(%s, %s)", (ACCT_ALICE, ASSET_USDX))
        avail_before = float(db.fetchone()[0])

        # Place order (reserves 500)
        r = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50.00, 10)

        db.execute("SELECT ledger.available_balance(%s, %s)", (ACCT_ALICE, ASSET_USDX))
        avail_during = float(db.fetchone()[0])
        assert avail_during == avail_before - 500

        # Cancel
        cancel_order(db, TENANT_APEX, r[0])

        db.execute("SELECT ledger.available_balance(%s, %s)", (ACCT_ALICE, ASSET_USDX))
        avail_after = float(db.fetchone()[0])
        assert avail_after == avail_before

    def test_no_negative_balance(self, db):
        """Cannot place order exceeding available balance."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 100)

        result = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50.00, 10)
        # 50 * 10 = 500, but only 100 available
        assert result[1] == 'rejected'

    def test_order_events_recorded(self, db):
        """Order events are recorded for each state transition."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 5000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)

        r = place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50.00, 10)
        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 50.00, 10)

        db.execute("""
            SELECT event_type FROM trading.order_events
            WHERE order_id = %s ORDER BY created_at
        """, (r[0],))
        events = [row[0] for row in db.fetchall()]
        assert 'accepted' in events
        assert 'filled' in events
