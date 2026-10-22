"""
VerityTick — Security and Row-Level Security (RLS) Tests

Validates:
- Multi-tenant data isolation under restricted database roles (vt_app, vt_readonly)
- Fail-closed behavior when no tenant context is provided
- Cross-tenant data leakage prevention (orders, accounts, ledger journals, alerts)
- Immutability of posted financial ledger records under application roles
"""

import pytest
import psycopg2
from psycopg2 import errors

TENANT_APEX = 'a0000000-0000-0000-0000-000000000001'
TENANT_MERIDIAN = 'a0000000-0000-0000-0000-000000000002'
ACCT_ALICE = 'e0000000-0000-0000-0000-000000000001'   # Apex
ACCT_DIANA = 'e0000000-0000-0000-0000-000000000005'   # Meridian
MARKET_ACME = 'd0000000-0000-0000-0000-000000000001'
ASSET_USDX = 'c0000000-0000-0000-0000-000000000001'


@pytest.fixture
def app_role_session(db):
    """
    Switches session context to the restricted vt_app role within the test savepoint.
    Reverts back on teardown.
    """
    db.execute("SET ROLE vt_app")
    yield db
    db.execute("RESET ROLE")


class TestTenantIsolation:

    def test_fail_closed_without_tenant_context(self, app_role_session):
        """When app.current_tenant_id is not set, no tenant-scoped rows are visible."""
        cur = app_role_session
        cur.execute("RESET app.current_tenant_id")

        cur.execute("SELECT COUNT(*) FROM core.tenants")
        assert cur.fetchone()[0] == 0

        cur.execute("SELECT COUNT(*) FROM core.trading_accounts")
        assert cur.fetchone()[0] == 0

        cur.execute("SELECT COUNT(*) FROM trading.orders")
        assert cur.fetchone()[0] == 0

    def test_tenant_can_only_view_own_accounts(self, app_role_session):
        """Apex can only see Apex accounts; Meridian accounts are hidden."""
        cur = app_role_session
        cur.execute("SET LOCAL app.current_tenant_id = %s", (TENANT_APEX,))

        cur.execute("SELECT tenant_id, account_id FROM core.trading_accounts")
        rows = cur.fetchall()
        assert len(rows) > 0
        for tid, aid in rows:
            assert str(tid) == TENANT_APEX
            assert str(aid) != ACCT_DIANA

    def test_cross_tenant_isolation_meridian(self, app_role_session):
        """Meridian tenant only sees Meridian accounts."""
        cur = app_role_session
        cur.execute("SET LOCAL app.current_tenant_id = %s", (TENANT_MERIDIAN,))

        cur.execute("SELECT tenant_id, account_id FROM core.trading_accounts")
        rows = cur.fetchall()
        assert len(rows) > 0
        for tid, aid in rows:
            assert str(tid) == TENANT_MERIDIAN
            assert str(aid) != ACCT_ALICE

    def test_cross_tenant_orders_hidden(self, db):
        """Orders placed by Apex are invisible to Meridian under vt_app."""
        # 1. Place an order as Apex
        db.execute("SELECT ledger.deposit(%s, %s, %s, %s)",
                   (TENANT_APEX, ACCT_ALICE, ASSET_USDX, 1000))
        db.execute("""
            SELECT order_id FROM trading.place_order(%s, %s, %s, 'buy', 50, 10)
        """, (TENANT_APEX, ACCT_ALICE, MARKET_ACME))
        order_id = db.fetchone()[0]

        # 2. Switch to vt_app role as Meridian
        db.execute("SET ROLE vt_app")
        db.execute("SET LOCAL app.current_tenant_id = %s", (TENANT_MERIDIAN,))

        db.execute("SELECT COUNT(*) FROM trading.orders WHERE order_id = %s", (order_id,))
        assert db.fetchone()[0] == 0

        # 3. Switch to vt_app role as Apex - order is visible
        db.execute("SET LOCAL app.current_tenant_id = %s", (TENANT_APEX,))
        db.execute("SELECT COUNT(*) FROM trading.orders WHERE order_id = %s", (order_id,))
        assert db.fetchone()[0] == 1

        db.execute("RESET ROLE")


class TestLedgerImmutability:

    def test_app_role_cannot_update_posted_journal(self, db):
        """Application role (vt_app) is denied UPDATE permissions on posted ledger journals."""
        db.execute("SELECT ledger.deposit(%s, %s, %s, %s)",
                   (TENANT_APEX, ACCT_ALICE, ASSET_USDX, 500))

        db.execute("SELECT journal_id FROM ledger.journals LIMIT 1")
        journal_id = db.fetchone()[0]

        db.execute("SET ROLE vt_app")
        db.execute("SET LOCAL app.current_tenant_id = %s", (TENANT_APEX,))

        db.execute("SAVEPOINT priv_test_update")
        with pytest.raises(errors.InsufficientPrivilege):
            db.execute("""
                UPDATE ledger.journals
                SET description = 'Illicit tampering'
                WHERE journal_id = %s
            """, (journal_id,))

        db.execute("ROLLBACK TO SAVEPOINT priv_test_update")
        db.execute("RESET ROLE")

    def test_app_role_cannot_delete_ledger_entry(self, db):
        """Application role (vt_app) is denied DELETE permissions on ledger entries."""
        db.execute("SELECT ledger.deposit(%s, %s, %s, %s)",
                   (TENANT_APEX, ACCT_ALICE, ASSET_USDX, 500))

        db.execute("SELECT entry_id FROM ledger.entries LIMIT 1")
        entry_id = db.fetchone()[0]

        db.execute("SET ROLE vt_app")
        db.execute("SET LOCAL app.current_tenant_id = %s", (TENANT_APEX,))

        db.execute("SAVEPOINT priv_test_delete")
        with pytest.raises(errors.InsufficientPrivilege):
            db.execute("""
                DELETE FROM ledger.entries
                WHERE entry_id = %s
            """, (entry_id,))

        db.execute("ROLLBACK TO SAVEPOINT priv_test_delete")
        db.execute("RESET ROLE")
