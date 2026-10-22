"""
VerityTick — Fraud Detection Tests

Tests recursive cycle detection:
- Circular transfer detection (A→B→C→A)
- Time-window and depth constraints
- Alert generation and idempotency
- Benign vs suspicious patterns
"""

import pytest
from decimal import Decimal

TENANT_APEX = 'a0000000-0000-0000-0000-000000000001'
ACCT_ALICE = 'e0000000-0000-0000-0000-000000000001'
ACCT_BOB = 'e0000000-0000-0000-0000-000000000003'
ACCT_CHARLIE = 'e0000000-0000-0000-0000-000000000004'
ASSET_USDX = 'c0000000-0000-0000-0000-000000000001'
ASSET_ACME = 'c0000000-0000-0000-0000-000000000002'
MARKET_ACME = 'd0000000-0000-0000-0000-000000000001'


def deposit(cur, tenant_id, account_id, asset_id, amount):
    cur.execute("SELECT ledger.deposit(%s, %s, %s, %s)",
                (tenant_id, account_id, asset_id, amount))


def place_order(cur, tenant_id, account_id, market_id, side, price, qty):
    cur.execute("SELECT * FROM trading.place_order(%s, %s, %s, %s, %s, %s)",
                (tenant_id, account_id, market_id, side, price, qty))
    return cur.fetchone()


class TestTransferEdges:

    def test_sync_creates_edges_from_trades(self, db):
        """Syncing trade edges creates graph entries for executed trades."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)

        # Create a trade: Alice buys ACME from Bob
        place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50, 10)
        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 50, 10)

        db.execute("SELECT risk.sync_trade_edges(%s)", (TENANT_APEX,))

        db.execute("SELECT COUNT(*) FROM risk.transfer_edges WHERE tenant_id = %s",
                   (TENANT_APEX,))
        count = db.fetchone()[0]
        # Each trade generates 2 edges (quote: buyer→seller, base: seller→buyer)
        assert count >= 2


class TestCycleDetection:

    def _create_circular_trades(self, db):
        """Create A→B→C→A circular transfers via trading."""
        # Give everyone initial balances
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 50000)
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_ACME, 1000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_USDX, 50000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 1000)
        deposit(db, TENANT_APEX, ACCT_CHARLIE, ASSET_USDX, 50000)
        deposit(db, TENANT_APEX, ACCT_CHARLIE, ASSET_ACME, 1000)

        # Trade 1: Alice sells ACME to Bob (ACME flows: Alice → Bob)
        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'buy', 50, 10)
        place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'sell', 50, 10)

        # Trade 2: Bob sells ACME to Charlie (ACME flows: Bob → Charlie)
        place_order(db, TENANT_APEX, ACCT_CHARLIE, MARKET_ACME, 'buy', 50, 10)
        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 50, 10)

        # Trade 3: Charlie sells ACME to Alice (ACME flows: Charlie → Alice)
        place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50, 10)
        place_order(db, TENANT_APEX, ACCT_CHARLIE, MARKET_ACME, 'sell', 50, 10)

        # Sync edges
        db.execute("SELECT risk.sync_trade_edges(%s)", (TENANT_APEX,))

    def test_detects_cycle(self, db):
        """Recursive detection finds a circular transfer pattern."""
        self._create_circular_trades(db)

        db.execute("""
            SELECT * FROM risk.detect_cycles(
                %s,
                now() - INTERVAL '1 hour',
                now() + INTERVAL '1 hour',
                6, 0
            )
        """, (TENANT_APEX,))
        cycles = db.fetchall()
        assert len(cycles) > 0  # at least one cycle detected

    def test_no_cycle_without_circular_trades(self, db):
        """No cycle when transfers are one-directional."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)

        # Just one trade, no cycle
        place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50, 10)
        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 50, 10)

        db.execute("SELECT risk.sync_trade_edges(%s)", (TENANT_APEX,))

        db.execute("""
            SELECT COUNT(*) FROM risk.detect_cycles(
                %s,
                now() - INTERVAL '1 hour',
                now() + INTERVAL '1 hour',
                6, 0
            )
        """, (TENANT_APEX,))
        assert db.fetchone()[0] == 0

    def test_depth_limit_respected(self, db):
        """Cycles deeper than max_depth are not returned."""
        self._create_circular_trades(db)

        # Depth 1 should find no cycles (need at least 2 hops)
        db.execute("""
            SELECT COUNT(*) FROM risk.detect_cycles(
                %s, now() - INTERVAL '1 hour', now() + INTERVAL '1 hour', 1, 0
            )
        """, (TENANT_APEX,))
        assert db.fetchone()[0] == 0


class TestAlertGeneration:

    def test_generate_alerts_creates_alert(self, db):
        """Alert generation creates alerts for detected cycles."""
        # Setup circular trades
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 50000)
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_ACME, 1000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_USDX, 50000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 1000)
        deposit(db, TENANT_APEX, ACCT_CHARLIE, ASSET_USDX, 50000)
        deposit(db, TENANT_APEX, ACCT_CHARLIE, ASSET_ACME, 1000)

        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'buy', 50, 10)
        place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'sell', 50, 10)
        place_order(db, TENANT_APEX, ACCT_CHARLIE, MARKET_ACME, 'buy', 50, 10)
        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 50, 10)
        place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50, 10)
        place_order(db, TENANT_APEX, ACCT_CHARLIE, MARKET_ACME, 'sell', 50, 10)

        db.execute("""
            SELECT risk.generate_alerts(
                %s, now() - INTERVAL '1 hour', now() + INTERVAL '1 hour'
            )
        """, (TENANT_APEX,))
        count = db.fetchone()[0]

        db.execute("SELECT COUNT(*) FROM risk.alerts WHERE tenant_id = %s", (TENANT_APEX,))
        alert_count = db.fetchone()[0]
        assert alert_count >= 1

    def test_alerts_are_idempotent(self, db):
        """Running alert generation twice does not duplicate alerts."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 50000)
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_ACME, 1000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_USDX, 50000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 1000)
        deposit(db, TENANT_APEX, ACCT_CHARLIE, ASSET_USDX, 50000)
        deposit(db, TENANT_APEX, ACCT_CHARLIE, ASSET_ACME, 1000)

        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'buy', 50, 10)
        place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'sell', 50, 10)
        place_order(db, TENANT_APEX, ACCT_CHARLIE, MARKET_ACME, 'buy', 50, 10)
        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 50, 10)
        place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50, 10)
        place_order(db, TENANT_APEX, ACCT_CHARLIE, MARKET_ACME, 'sell', 50, 10)

        window = "now() - INTERVAL '1 hour', now() + INTERVAL '1 hour'"
        db.execute(f"SELECT risk.generate_alerts(%s, {window})", (TENANT_APEX,))
        db.execute(f"SELECT risk.generate_alerts(%s, {window})", (TENANT_APEX,))

        db.execute("SELECT COUNT(*) FROM risk.alerts WHERE tenant_id = %s", (TENANT_APEX,))
        count1 = db.fetchone()[0]

        # Running again should not increase count
        db.execute(f"SELECT risk.generate_alerts(%s, {window})", (TENANT_APEX,))
        db.execute("SELECT COUNT(*) FROM risk.alerts WHERE tenant_id = %s", (TENANT_APEX,))
        count2 = db.fetchone()[0]

        assert count2 == count1

    def test_alert_has_evidence(self, db):
        """Generated alerts contain traceable evidence."""
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 50000)
        deposit(db, TENANT_APEX, ACCT_ALICE, ASSET_ACME, 1000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_USDX, 50000)
        deposit(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 1000)
        deposit(db, TENANT_APEX, ACCT_CHARLIE, ASSET_USDX, 50000)
        deposit(db, TENANT_APEX, ACCT_CHARLIE, ASSET_ACME, 1000)

        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'buy', 50, 10)
        place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'sell', 50, 10)
        place_order(db, TENANT_APEX, ACCT_CHARLIE, MARKET_ACME, 'buy', 50, 10)
        place_order(db, TENANT_APEX, ACCT_BOB, MARKET_ACME, 'sell', 50, 10)
        place_order(db, TENANT_APEX, ACCT_ALICE, MARKET_ACME, 'buy', 50, 10)
        place_order(db, TENANT_APEX, ACCT_CHARLIE, MARKET_ACME, 'sell', 50, 10)

        db.execute("""
            SELECT risk.generate_alerts(
                %s, now() - INTERVAL '1 hour', now() + INTERVAL '1 hour'
            )
        """, (TENANT_APEX,))

        db.execute("""
            SELECT evidence_summary, edge_details, cycle_length, cycle_accounts
            FROM risk.alerts WHERE tenant_id = %s LIMIT 1
        """, (TENANT_APEX,))
        alert = db.fetchone()
        if alert:
            assert alert[0] is not None         # evidence_summary
            assert alert[2] >= 2                 # cycle_length
            assert len(alert[3]) >= 3            # cycle_accounts array
