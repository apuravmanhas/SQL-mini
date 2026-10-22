"""
VerityTick — pytest configuration and shared fixtures.

Provides database connection fixtures that use transactions
with rollback for test isolation.
"""

import os
import pytest
import psycopg2


def _load_env():
    """Load .env file from project root.

    Only sets values that are not already in the environment,
    and skips empty values (so env vars take precedence).
    """
    env_path = os.path.join(os.path.dirname(__file__), '..', '.env')
    env_path = os.path.abspath(env_path)
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, _, value = line.partition('=')
                    key, value = key.strip(), value.strip()
                    if value:  # skip empty values
                        os.environ.setdefault(key, value)


_load_env()


def get_db_params(use_test_db=True):
    """Get database connection parameters."""
    dbname = os.environ.get('VT_TEST_DB_NAME', 'veritytick_test') if use_test_db \
        else os.environ.get('VT_DB_NAME', 'veritytick')
    return {
        'host': os.environ.get('VT_DB_HOST', 'localhost'),
        'port': int(os.environ.get('VT_DB_PORT', '5432')),
        'user': os.environ.get('VT_DB_USER', 'postgres'),
        'password': os.environ.get('VT_DB_PASSWORD', ''),
        'dbname': dbname,
    }


@pytest.fixture(scope='session')
def db_params():
    """Database connection parameters for the test database."""
    # Use the main dev database for now (test DB setup will come later)
    return get_db_params(use_test_db=False)


@pytest.fixture(scope='session')
def db_connection(db_params):
    """Session-scoped database connection."""
    conn = psycopg2.connect(**db_params)
    yield conn
    conn.close()


@pytest.fixture
def db(db_connection):
    """
    Per-test database cursor wrapped in a savepoint.
    Rolls back after each test for isolation.
    """
    # Start a savepoint so each test is isolated
    cur = db_connection.cursor()
    cur.execute("SAVEPOINT test_savepoint")
    yield cur
    db_connection.rollback()  # Roll back to before the savepoint


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
