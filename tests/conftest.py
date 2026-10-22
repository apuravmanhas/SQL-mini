"""
VerityTick — pytest configuration and shared fixtures.

Provides test database isolation:
- Session fixture initializes a pristine test database (veritytick_test)
- Function fixtures wrap each test in a transaction savepoint with automatic rollback
"""

import os
import sys
import pytest
import psycopg2

# Add project root to sys.path so tools can be imported
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
from tools.setup_db import run_setup, get_connection_params


def _load_env():
    """Load .env file from project root."""
    env_path = os.path.join(os.path.dirname(__file__), '..', '.env')
    env_path = os.path.abspath(env_path)
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, _, value = line.partition('=')
                    key, value = key.strip(), value.strip()
                    if value:
                        os.environ.setdefault(key, value)


_load_env()


@pytest.fixture(scope='session', autouse=True)
def setup_test_database():
    """
    Ensure the isolated test database exists, has migrations applied,
    and is seeded cleanly for the test run.
    """
    run_setup(use_test_db=True, reset=True, seed=True)


@pytest.fixture(scope='session')
def db_params():
    """Database connection parameters for the isolated test database."""
    return get_connection_params(use_test_db=True)


@pytest.fixture(scope='session')
def db_connection(setup_test_database, db_params):
    """Session-scoped database connection to the test database."""
    conn = psycopg2.connect(**db_params)
    yield conn
    conn.close()


@pytest.fixture
def db(db_connection):
    """
    Per-test database cursor wrapped in a savepoint.
    Rolls back after each test for strict isolation.
    """
    cur = db_connection.cursor()
    cur.execute("SAVEPOINT test_savepoint")
    yield cur
    db_connection.rollback()


@pytest.fixture
def conn(db_params):
    """
    Per-test independent connection (for tests that need commit/rollback control).
    Rolls back any uncommitted work on teardown.
    """
    connection = psycopg2.connect(**db_params)
    yield connection
    connection.rollback()
    connection.close()
