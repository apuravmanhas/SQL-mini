"""
VerityTick - Concurrency tests.

These tests open several real database connections that commit independently,
so they run in a dedicated throwaway database (dropped when the module ends)
instead of the shared savepoint-based test database.

They check the properties the per-market lock is meant to guarantee:
- a resting order is never filled twice
- ledger balances reconcile and every asset is conserved after contention
- trades execute inside the crossing price range
- the book is uncrossed once all orders have been processed
- every engine call is accounted for in a valid audit chain
"""

import os
import random
import threading
from concurrent.futures import ThreadPoolExecutor

import psycopg2
import pytest

from tools.setup_db import run_setup, get_connection_params

pytestmark = pytest.mark.concurrency

CONC_DB = 'veritytick_concurrency'

TENANT = 'a0000000-0000-0000-0000-000000000001'
ALICE = 'e0000000-0000-0000-0000-000000000001'
BOB = 'e0000000-0000-0000-0000-000000000003'
CHARLIE = 'e0000000-0000-0000-0000-000000000004'
MARKET = 'd0000000-0000-0000-0000-000000000001'
USDX = 'c0000000-0000-0000-0000-000000000001'
ACME = 'c0000000-0000-0000-0000-000000000002'


def fresh_database():
    """Recreate the throwaway database and commit funding for the trading accounts."""
    run_setup(use_test_db=True, reset=True, seed=True, dbname=CONC_DB)
    p = get_connection_params(use_test_db=True, dbname=CONC_DB)
    conn = psycopg2.connect(**p)
    cur = conn.cursor()
    for acct, asset, amount in [
        (ALICE, USDX, 1_000_000), (CHARLIE, USDX, 1_000_000),
        (BOB, ACME, 10_000), (CHARLIE, ACME, 10_000),
    ]:
        cur.execute("SELECT ledger.deposit(%s, %s, %s, %s)", (TENANT, acct, asset, amount))
    conn.commit()
    conn.close()
    return p


@pytest.fixture
def params():
    return fresh_database()


def place_orders(params, orders, barrier=None):
    """Place orders on a dedicated connection, committing after each one."""
    conn = psycopg2.connect(**params)
    cur = conn.cursor()
    results = []
    try:
        if barrier is not None:
            barrier.wait(timeout=30)
        for account, side, price, qty in orders:
            cur.execute(
                "SELECT order_id, status, trades_executed "
                "FROM trading.place_order(%s, %s, %s, %s, %s, %s)",
                (TENANT, account, MARKET, side, price, qty))
            results.append(cur.fetchone())
            conn.commit()
    finally:
        conn.close()
    return results


def query(params, sql, args=()):
    conn = psycopg2.connect(**params)
    try:
        cur = conn.cursor()
        cur.execute(sql, args)
        return cur.fetchall()
    finally:
        conn.close()


@pytest.fixture(scope='module', autouse=True)
def drop_database_afterwards():
    yield
    p = get_connection_params(use_test_db=True, dbname='postgres')
    conn = psycopg2.connect(**p)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                "WHERE datname = %s AND pid <> pg_backend_pid()", (CONC_DB,))
    cur.execute(f'DROP DATABASE IF EXISTS "{CONC_DB}"')
    conn.close()


class TestRestingOrderRace:

    def test_resting_order_is_filled_exactly_once(self, params):
        place_orders(params, [(BOB, 'sell', 50, 10)])

        barrier = threading.Barrier(2)
        with ThreadPoolExecutor(max_workers=2) as pool:
            f1 = pool.submit(place_orders, params, [(ALICE, 'buy', 50, 10)], barrier)
            f2 = pool.submit(place_orders, params, [(CHARLIE, 'buy', 50, 10)], barrier)
            statuses = sorted([f1.result()[0][1], f2.result()[0][1]])

        assert statuses == ['filled', 'open']
        traded = query(params, "SELECT COALESCE(SUM(quantity), 0), COUNT(*) FROM trading.trades")[0]
        assert traded[0] == 10
        assert traded[1] == 1
        assert query(params, "SELECT COUNT(*) FROM ledger.reconcile_balances()")[0][0] == 0


THREADS = 8
ORDERS_PER_THREAD = 25


def build_orders(seed):
    rng = random.Random(seed)
    orders = []
    for _ in range(ORDERS_PER_THREAD):
        account = rng.choice([ALICE, BOB, CHARLIE])
        if account == ALICE:
            side = 'buy'
        elif account == BOB:
            side = 'sell'
        else:
            side = rng.choice(['buy', 'sell'])
        price = 49 + rng.choice([0, 0.5, 1, 1.5, 2])
        orders.append((account, side, price, rng.randint(1, 5)))
    return orders


@pytest.fixture(scope='module')
def storm():
    """Run all threads once; the tests below inspect the committed outcome."""
    params = fresh_database()
    barrier = threading.Barrier(THREADS)
    with ThreadPoolExecutor(max_workers=THREADS) as pool:
        futures = [pool.submit(place_orders, params, build_orders(i), barrier)
                   for i in range(THREADS)]
        results = [r for f in futures for r in f.result()]
    return params, results


class TestOrderStorm:

    def test_all_orders_were_processed(self, storm):
        _, results = storm
        assert len(results) == THREADS * ORDERS_PER_THREAD
        assert all(r[1] in ('open', 'partially_filled', 'filled', 'rejected') for r in results)

    def test_ledger_reconciles_and_conserves(self, storm):
        params, _ = storm
        assert query(params, "SELECT COUNT(*) FROM ledger.reconcile_balances()")[0][0] == 0
        assert query(params, "SELECT COUNT(*) FROM ledger.check_conservation()")[0][0] == 0
        negatives = query(
            params, "SELECT COUNT(*) FROM ledger.accounts WHERE balance < 0 AND account_type <> 'system'")
        assert negatives[0][0] == 0

    def test_filled_quantity_matches_trades(self, storm):
        params, _ = storm
        mismatches = query(params, """
            SELECT o.order_id FROM trading.orders o
            LEFT JOIN (
                SELECT order_id, SUM(quantity) AS qty FROM (
                    SELECT buy_order_id AS order_id, quantity FROM trading.trades
                    UNION ALL
                    SELECT sell_order_id, quantity FROM trading.trades) x
                GROUP BY order_id) t ON t.order_id = o.order_id
            WHERE o.original_quantity - o.remaining_quantity <> COALESCE(t.qty, 0)
               OR o.remaining_quantity < 0""")
        assert mismatches == []

    def test_trades_execute_inside_the_crossing_range(self, storm):
        params, _ = storm
        outside = query(params, """
            SELECT t.trade_id FROM trading.trades t
            JOIN trading.orders b ON b.order_id = t.buy_order_id
            JOIN trading.orders s ON s.order_id = t.sell_order_id
            WHERE NOT (s.limit_price <= t.price AND t.price <= b.limit_price)""")
        assert outside == []

    def test_book_is_uncrossed(self, storm):
        params, _ = storm
        best_bid, best_ask = query(params, """
            SELECT MAX(limit_price) FILTER (WHERE side = 'buy'),
                   MIN(limit_price) FILTER (WHERE side = 'sell')
            FROM trading.orders WHERE status IN ('open', 'partially_filled')""")[0]
        if best_bid is not None and best_ask is not None:
            assert best_bid < best_ask

    def test_audit_chain_accounts_for_every_call(self, storm):
        params, results = storm
        is_valid, checked = query(params, "SELECT is_valid, checked_events FROM audit.verify_chain(%s)", (TENANT,))[0]
        assert is_valid is True
        assert checked == len(results)
