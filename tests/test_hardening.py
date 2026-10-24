"""
VerityTick — Privilege model, engine audit trail, self-trade prevention,
reconciliation and partition maintenance tests.

Covers behaviour introduced by migration V012:
- vt_app can use the engine only through the audited API and only for its own tenant
- vt_app cannot call operator functions or write engine tables directly
- order placement and cancellation append hash-chained audit events
- orders that would cross the account's own resting order are rejected cleanly
- ledger.reconcile_balances / ledger.check_conservation detect drift
- tick partitions are created on demand
"""

import pytest
from psycopg2 import errors

TENANT_APEX = 'a0000000-0000-0000-0000-000000000001'
TENANT_MERIDIAN = 'a0000000-0000-0000-0000-000000000002'
ACCT_ALICE = 'e0000000-0000-0000-0000-000000000001'
ACCT_BOB = 'e0000000-0000-0000-0000-000000000003'
ACCT_CHARLIE = 'e0000000-0000-0000-0000-000000000004'
MARKET_ACME = 'd0000000-0000-0000-0000-000000000001'
ASSET_USDX = 'c0000000-0000-0000-0000-000000000001'
ASSET_ACME = 'c0000000-0000-0000-0000-000000000002'


def fund(cur, tenant, account, asset, amount):
    cur.execute("SELECT ledger.deposit(%s, %s, %s, %s)", (tenant, account, asset, amount))


def place(cur, tenant, account, side, price, qty, key=None):
    cur.execute(
        "SELECT order_id, status, remaining_quantity, trades_executed, message "
        "FROM trading.place_order(%s, %s, %s, %s, %s, %s, %s)",
        (tenant, account, MARKET_ACME, side, price, qty, key))
    return cur.fetchone()


def audit_events(cur, tenant, event_type=None):
    cur.execute(
        "SELECT event_type, entity_id FROM audit.events "
        "WHERE tenant_id = %s AND (%s::text IS NULL OR event_type = %s) ORDER BY seq",
        (tenant, event_type, event_type))
    return cur.fetchall()


def expect_error(cur, exc, sql, params=()):
    cur.execute("SAVEPOINT expect_error")
    with pytest.raises(exc):
        cur.execute(sql, params)
    cur.execute("ROLLBACK TO SAVEPOINT expect_error")


@pytest.fixture
def app(db):
    """Cursor acting as vt_app inside the Apex tenant context."""
    fund(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)
    fund(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)
    db.execute("SET LOCAL ROLE vt_app")
    db.execute("SET LOCAL app.current_tenant_id = %s", (TENANT_APEX,))
    return db


class TestApplicationRoleApi:

    def test_app_role_can_place_and_cancel_order(self, app):
        order_id, status, remaining, trades, _ = place(app, TENANT_APEX, ACCT_ALICE, 'buy', 10, 5)
        assert status == 'open'
        assert trades == 0

        app.execute("SELECT status FROM trading.cancel_order(%s, %s)", (TENANT_APEX, order_id))
        assert app.fetchone()[0] == 'cancelled'

    def test_app_role_can_match_orders(self, app):
        place(app, TENANT_APEX, ACCT_BOB, 'sell', 50, 10)
        _, status, _, trades, _ = place(app, TENANT_APEX, ACCT_ALICE, 'buy', 50, 10)
        assert status == 'filled'
        assert trades == 1

    def test_tenant_context_mismatch_is_denied(self, app):
        app.execute("SET LOCAL app.current_tenant_id = %s", (TENANT_MERIDIAN,))
        expect_error(app, errors.InsufficientPrivilege,
                     "SELECT * FROM trading.place_order(%s, %s, %s, 'buy', 10, 1)",
                     (TENANT_APEX, ACCT_ALICE, MARKET_ACME))

    def test_missing_tenant_context_is_denied(self, app):
        app.execute("RESET app.current_tenant_id")
        expect_error(app, errors.InsufficientPrivilege,
                     "SELECT * FROM trading.place_order(%s, %s, %s, 'buy', 10, 1)",
                     (TENANT_APEX, ACCT_ALICE, MARKET_ACME))

    def test_cancel_with_wrong_context_is_denied(self, app):
        order_id = place(app, TENANT_APEX, ACCT_ALICE, 'buy', 10, 1)[0]
        app.execute("SET LOCAL app.current_tenant_id = %s", (TENANT_MERIDIAN,))
        expect_error(app, errors.InsufficientPrivilege,
                     "SELECT * FROM trading.cancel_order(%s, %s)", (TENANT_APEX, order_id))

    def test_audit_append_requires_matching_context(self, app):
        app.execute("SET LOCAL app.current_tenant_id = %s", (TENANT_MERIDIAN,))
        expect_error(app, errors.InsufficientPrivilege,
                     "SELECT audit.append_event(%s, 'FORGED')", (TENANT_APEX,))

    @pytest.mark.parametrize("sql", [
        "SELECT ledger.deposit('{t}', '{a}', '{asset}', 1000000)",
        "SELECT trading.place_order_core('{t}', '{a}', '{m}', 'buy', 10, 1, NULL)",
        "SELECT audit.append_event_core('{t}', 'FORGED', NULL, NULL, NULL, '{{}}'::jsonb)",
        "SELECT risk.sync_trade_edges()",
        "SELECT market_data.ensure_tick_partition(now())",
    ])
    def test_operator_functions_are_not_callable(self, app, sql):
        stmt = sql.format(t=TENANT_APEX, a=ACCT_ALICE, asset=ASSET_USDX, m=MARKET_ACME)
        expect_error(app, errors.InsufficientPrivilege, stmt)

    @pytest.mark.parametrize("sql", [
        "UPDATE ledger.accounts SET balance = balance + 1000000",
        "INSERT INTO trading.orders (tenant_id, account_id, market_id, side, limit_price, "
        "original_quantity, remaining_quantity, status, priority_seq) "
        "VALUES ('{t}', '{a}', '{m}', 'buy', 1, 1, 1, 'open', 999999)",
        "DELETE FROM audit.events",
        "UPDATE core.markets SET status = 'halted'",
    ])
    def test_engine_tables_are_not_directly_writable(self, app, sql):
        stmt = sql.format(t=TENANT_APEX, a=ACCT_ALICE, m=MARKET_ACME)
        expect_error(app, errors.InsufficientPrivilege, stmt)

    def test_readonly_role_cannot_place_orders(self, db):
        db.execute("SET LOCAL ROLE vt_readonly")
        db.execute("SET LOCAL app.current_tenant_id = %s", (TENANT_APEX,))
        expect_error(db, errors.InsufficientPrivilege,
                     "SELECT * FROM trading.place_order(%s, %s, %s, 'buy', 10, 1)",
                     (TENANT_APEX, ACCT_ALICE, MARKET_ACME))


class TestEngineAuditTrail:

    def test_order_placement_appends_event(self, db):
        fund(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 1000)
        order_id = place(db, TENANT_APEX, ACCT_ALICE, 'buy', 10, 5)[0]
        events = audit_events(db, TENANT_APEX, 'order_placed')
        assert [str(e[1]) for e in events] == [str(order_id)]

    def test_rejection_is_recorded(self, db):
        result = place(db, TENANT_APEX, ACCT_ALICE, 'buy', 10, 5)
        assert result[1] == 'rejected'
        assert len(audit_events(db, TENANT_APEX, 'order_rejected')) == 1

    def test_cancel_appends_event(self, db):
        fund(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 1000)
        order_id = place(db, TENANT_APEX, ACCT_ALICE, 'buy', 10, 5)[0]
        db.execute("SELECT * FROM trading.cancel_order(%s, %s)", (TENANT_APEX, order_id))
        events = audit_events(db, TENANT_APEX, 'order_cancelled')
        assert [str(e[1]) for e in events] == [str(order_id)]

    def test_duplicate_idempotent_request_is_not_logged_twice(self, db):
        fund(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 1000)
        place(db, TENANT_APEX, ACCT_ALICE, 'buy', 10, 5, key='dup-1')
        place(db, TENANT_APEX, ACCT_ALICE, 'buy', 10, 5, key='dup-1')
        assert len(audit_events(db, TENANT_APEX, 'order_placed')) == 1

    def test_chain_verifies_after_engine_activity(self, db):
        fund(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)
        fund(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)
        place(db, TENANT_APEX, ACCT_BOB, 'sell', 50, 10)
        place(db, TENANT_APEX, ACCT_ALICE, 'buy', 50, 10)
        open_id = place(db, TENANT_APEX, ACCT_ALICE, 'buy', 20, 1)[0]
        db.execute("SELECT * FROM trading.cancel_order(%s, %s)", (TENANT_APEX, open_id))

        db.execute("SELECT is_valid, checked_events FROM audit.verify_chain(%s)", (TENANT_APEX,))
        is_valid, checked = db.fetchone()
        assert is_valid is True
        assert checked == 4


class TestSelfTradePrevention:

    def test_crossing_own_resting_order_is_rejected_cleanly(self, db):
        fund(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)
        fund(db, TENANT_APEX, ACCT_BOB, ASSET_USDX, 10000)
        resting = place(db, TENANT_APEX, ACCT_BOB, 'sell', 50, 10)
        assert resting[1] == 'open'

        result = place(db, TENANT_APEX, ACCT_BOB, 'buy', 50, 10)
        assert result[0] is None
        assert result[1] == 'rejected'
        assert 'own resting order' in result[4]

        db.execute("SELECT COUNT(*) FROM trading.trades WHERE sell_order_id = %s", (resting[0],))
        assert db.fetchone()[0] == 0
        db.execute("SELECT status FROM trading.orders WHERE order_id = %s", (resting[0],))
        assert db.fetchone()[0] == 'open'

    def test_rejected_order_does_not_reserve_funds(self, db):
        fund(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)
        fund(db, TENANT_APEX, ACCT_BOB, ASSET_USDX, 10000)
        place(db, TENANT_APEX, ACCT_BOB, 'sell', 50, 10)
        db.execute("SELECT ledger.available_balance(%s, %s)", (ACCT_BOB, ASSET_USDX))
        before = db.fetchone()[0]
        place(db, TENANT_APEX, ACCT_BOB, 'buy', 50, 10)
        db.execute("SELECT ledger.available_balance(%s, %s)", (ACCT_BOB, ASSET_USDX))
        assert db.fetchone()[0] == before

    def test_non_crossing_orders_from_same_account_are_allowed(self, db):
        fund(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)
        fund(db, TENANT_APEX, ACCT_BOB, ASSET_USDX, 10000)
        assert place(db, TENANT_APEX, ACCT_BOB, 'sell', 60, 10)[1] == 'open'
        assert place(db, TENANT_APEX, ACCT_BOB, 'buy', 50, 10)[1] == 'open'

    def test_other_accounts_still_match_normally(self, db):
        fund(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)
        fund(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)
        place(db, TENANT_APEX, ACCT_BOB, 'sell', 50, 10)
        assert place(db, TENANT_APEX, ACCT_ALICE, 'buy', 50, 10)[1] == 'filled'


def tamper_balance(cur):
    cur.execute(
        "UPDATE ledger.accounts SET balance = balance + 7 "
        "WHERE ledger_account_id = (SELECT ledger_account_id FROM ledger.accounts "
        "WHERE trading_account_id = %s AND asset_id = %s AND account_type = 'trading')",
        (ACCT_ALICE, ASSET_USDX))


class TestReconciliation:

    def trade(self, db):
        fund(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)
        fund(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)
        place(db, TENANT_APEX, ACCT_BOB, 'sell', 50, 10)
        place(db, TENANT_APEX, ACCT_ALICE, 'buy', 50, 10)

    def test_reconciles_after_trading(self, db):
        self.trade(db)
        db.execute("SELECT COUNT(*) FROM ledger.reconcile_balances()")
        assert db.fetchone()[0] == 0

    def test_conserves_every_asset(self, db):
        self.trade(db)
        db.execute("SELECT COUNT(*) FROM ledger.check_conservation()")
        assert db.fetchone()[0] == 0

    def test_detects_tampered_balance(self, db):
        self.trade(db)
        tamper_balance(db)
        db.execute("SELECT stored_balance - computed_balance FROM ledger.reconcile_balances()")
        rows = db.fetchall()
        assert len(rows) == 1
        assert rows[0][0] == 7

    def test_conservation_detects_created_money(self, db):
        self.trade(db)
        tamper_balance(db)
        db.execute("SELECT net_balance FROM ledger.check_conservation()")
        assert db.fetchone()[0] == 7

    def test_reconcile_can_be_scoped_to_tenant(self, db):
        self.trade(db)
        tamper_balance(db)
        db.execute("SELECT COUNT(*) FROM ledger.reconcile_balances(%s)", (TENANT_MERIDIAN,))
        assert db.fetchone()[0] == 0
        db.execute("SELECT COUNT(*) FROM ledger.reconcile_balances(%s)", (TENANT_APEX,))
        assert db.fetchone()[0] == 1


class TestRlsOnEngineTables:

    def test_chain_state_is_tenant_scoped(self, db):
        fund(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 1000)
        place(db, TENANT_APEX, ACCT_ALICE, 'buy', 10, 1)

        db.execute("SET LOCAL ROLE vt_app")
        db.execute("SET LOCAL app.current_tenant_id = %s", (TENANT_MERIDIAN,))
        db.execute("SELECT COUNT(*) FROM audit.chain_state")
        assert db.fetchone()[0] == 0

        db.execute("SET LOCAL app.current_tenant_id = %s", (TENANT_APEX,))
        db.execute("SELECT COUNT(*) FROM audit.chain_state")
        assert db.fetchone()[0] == 1

    def test_transfer_edges_are_tenant_scoped(self, db):
        fund(db, TENANT_APEX, ACCT_ALICE, ASSET_USDX, 10000)
        fund(db, TENANT_APEX, ACCT_BOB, ASSET_ACME, 100)
        place(db, TENANT_APEX, ACCT_BOB, 'sell', 50, 10)
        place(db, TENANT_APEX, ACCT_ALICE, 'buy', 50, 10)
        db.execute("SELECT risk.sync_trade_edges()")

        db.execute("SET LOCAL ROLE vt_app")
        db.execute("SET LOCAL app.current_tenant_id = %s", (TENANT_MERIDIAN,))
        db.execute("SELECT COUNT(*) FROM risk.transfer_edges")
        assert db.fetchone()[0] == 0

        db.execute("SET LOCAL app.current_tenant_id = %s", (TENANT_APEX,))
        db.execute("SELECT COUNT(*) FROM risk.transfer_edges")
        assert db.fetchone()[0] > 0


class TestTickPartitions:

    def test_partition_is_created_on_demand(self, db):
        db.execute("SELECT market_data.ensure_tick_partition(%s)", ('2041-05-15 12:00:00+00',))
        name = db.fetchone()[0]
        assert name.startswith('ticks_2041_0')
        db.execute("SELECT to_regclass(%s) IS NOT NULL", ('market_data.' + name,))
        assert db.fetchone()[0] is True

    def test_partition_creation_is_idempotent(self, db):
        db.execute("SELECT market_data.ensure_tick_partition(%s)", ('2041-08-15 12:00:00+00',))
        first = db.fetchone()[0]
        db.execute("SELECT market_data.ensure_tick_partition(%s)", ('2041-08-15 12:00:00+00',))
        assert db.fetchone()[0] == first
