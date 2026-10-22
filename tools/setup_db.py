"""
VerityTick — Database Setup, Migration & Seeding Tool

Creates the database and applies versioned SQL migrations in order.
Safe to run repeatedly: tracks applied migrations in public.schema_migrations.
"""

import os
import sys
import glob
import argparse
import psycopg2
from psycopg2 import sql


def get_connection_params(use_test_db=False):
    """Read connection parameters from environment or .env file."""
    env_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), '.env')
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, _, value = line.partition('=')
                    key, value = key.strip(), value.strip()
                    if value:
                        os.environ.setdefault(key, value)

    dbname = os.environ.get('VT_TEST_DB_NAME', 'veritytick_test') if use_test_db \
        else os.environ.get('VT_DB_NAME', 'veritytick')

    return {
        'host': os.environ.get('VT_DB_HOST', 'localhost'),
        'port': int(os.environ.get('VT_DB_PORT', '5432')),
        'user': os.environ.get('VT_DB_USER', 'postgres'),
        'password': os.environ.get('VT_DB_PASSWORD', ''),
        'dbname': dbname,
    }


def get_admin_connection(params):
    """Connect to the 'postgres' maintenance database."""
    admin_params = dict(params)
    admin_params['dbname'] = 'postgres'
    return psycopg2.connect(**admin_params)


def create_database_if_not_exists(params):
    """Create the target database if it doesn't exist."""
    conn = get_admin_connection(params)
    conn.autocommit = True
    cur = conn.cursor()

    cur.execute(
        "SELECT 1 FROM pg_database WHERE datname = %s",
        (params['dbname'],)
    )
    if not cur.fetchone():
        print(f"Creating database '{params['dbname']}'...")
        cur.execute(
            sql.SQL("CREATE DATABASE {}").format(
                sql.Identifier(params['dbname'])
            )
        )
        print(f"Database '{params['dbname']}' created.")
    else:
        print(f"Database '{params['dbname']}' already exists.")

    cur.close()
    conn.close()


def drop_database_if_exists(params):
    """Drop database for clean reset."""
    conn = get_admin_connection(params)
    conn.autocommit = True
    cur = conn.cursor()

    # Terminate active connections first
    cur.execute("""
        SELECT pg_terminate_backend(pid)
        FROM pg_stat_activity
        WHERE datname = %s AND pid <> pg_backend_pid()
    """, (params['dbname'],))

    cur.execute(
        sql.SQL("DROP DATABASE IF EXISTS {}").format(
            sql.Identifier(params['dbname'])
        )
    )
    print(f"Database '{params['dbname']}' dropped.")
    cur.close()
    conn.close()


def ensure_migration_table(conn):
    """Create the migration tracking table if it doesn't exist."""
    cur = conn.cursor()
    cur.execute("""
        CREATE TABLE IF NOT EXISTS public.schema_migrations (
            version     TEXT PRIMARY KEY,
            filename    TEXT NOT NULL,
            applied_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
            checksum    TEXT
        )
    """)
    conn.commit()
    cur.close()


def get_applied_migrations(conn):
    """Return set of already-applied migration versions."""
    cur = conn.cursor()
    cur.execute("SELECT version FROM public.schema_migrations ORDER BY version")
    versions = {row[0] for row in cur.fetchall()}
    cur.close()
    return versions


def get_migration_files():
    """Find all migration SQL files, sorted by version."""
    migrations_dir = os.path.join(
        os.path.dirname(os.path.dirname(__file__)),
        'db', 'migrations'
    )
    pattern = os.path.join(migrations_dir, 'V*.sql')
    files = sorted(glob.glob(pattern))
    return files


def extract_version(filepath):
    """Extract version string from filename like V001__description.sql."""
    basename = os.path.basename(filepath)
    return basename.split('__')[0]


def apply_migration(conn, filepath):
    """Apply a single migration file within a transaction."""
    version = extract_version(filepath)
    filename = os.path.basename(filepath)

    print(f"  Applying {filename}...", end=" ")

    with open(filepath, 'r', encoding='utf-8') as f:
        migration_sql = f.read()

    import hashlib
    checksum = hashlib.sha256(migration_sql.encode('utf-8')).hexdigest()[:16]

    cur = conn.cursor()
    try:
        cur.execute(migration_sql)
        cur.execute(
            """INSERT INTO public.schema_migrations (version, filename, checksum)
               VALUES (%s, %s, %s)""",
            (version, filename, checksum)
        )
        conn.commit()
        print("OK")
    except Exception as e:
        conn.rollback()
        print(f"FAILED: {e}")
        raise
    finally:
        cur.close()


def seed_database(params):
    """Apply development seed fixtures."""
    seed_path = os.path.join(
        os.path.dirname(os.path.dirname(__file__)),
        'db', 'seed', 'development_seed.sql'
    )
    if not os.path.exists(seed_path):
        return

    print(f"Seeding '{params['dbname']}' with development fixtures...")
    conn = psycopg2.connect(**params)
    cur = conn.cursor()
    try:
        with open(seed_path, 'r', encoding='utf-8') as f:
            seed_sql = f.read()
        cur.execute(seed_sql)
        conn.commit()
        print("Seeding completed successfully.")
    except Exception as e:
        conn.rollback()
        print(f"Seeding note: {e}")
    finally:
        cur.close()
        conn.close()


def run_setup(use_test_db=False, reset=False, seed=False):
    """Main workflow: create db, apply migrations, optionally seed."""
    params = get_connection_params(use_test_db=use_test_db)

    if reset:
        drop_database_if_exists(params)

    create_database_if_not_exists(params)

    conn = psycopg2.connect(**params)
    try:
        ensure_migration_table(conn)
        applied = get_applied_migrations(conn)
        migration_files = get_migration_files()

        pending = [
            f for f in migration_files
            if extract_version(f) not in applied
        ]

        if pending:
            print(f"Found {len(pending)} pending migration(s) for '{params['dbname']}':")
            for filepath in pending:
                apply_migration(conn, filepath)
            print(f"All {len(pending)} migration(s) applied successfully.")
        else:
            print(f"All migrations already applied for '{params['dbname']}'.")
    finally:
        conn.close()

    if seed or reset:
        seed_database(params)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="VerityTick Database Setup")
    parser.add_argument('--test', action='store_true', help="Operate on test database (veritytick_test)")
    parser.add_argument('--reset', action='store_true', help="Drop and recreate database from scratch")
    parser.add_argument('--seed', action='store_true', help="Load development seed data")
    args = parser.parse_args()

    try:
        run_setup(use_test_db=args.test, reset=args.reset, seed=args.seed)
    except Exception as e:
        print(f"\nOperation failed: {e}", file=sys.stderr)
        sys.exit(1)
