"""
VerityTick — Database Setup and Migration Tool

Creates the database and applies versioned SQL migrations in order.
Safe to run repeatedly: tracks applied migrations in a version table.
"""

import os
import sys
import glob
import psycopg2
from psycopg2 import sql


def get_connection_params():
    """Read connection parameters from environment or .env file."""
    # Try loading .env if it exists
    env_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), '.env')
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, _, value = line.partition('=')
                    os.environ.setdefault(key.strip(), value.strip())

    return {
        'host': os.environ.get('VT_DB_HOST', 'localhost'),
        'port': int(os.environ.get('VT_DB_PORT', '5432')),
        'user': os.environ.get('VT_DB_USER', 'postgres'),
        'password': os.environ.get('VT_DB_PASSWORD', ''),
        'dbname': os.environ.get('VT_DB_NAME', 'veritytick'),
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
    return basename.split('__')[0]  # e.g., "V001"


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


def run_migrations():
    """Main migration workflow."""
    params = get_connection_params()

    # Step 1: Create database if needed
    create_database_if_not_exists(params)

    # Step 2: Connect to the target database
    conn = psycopg2.connect(**params)

    try:
        # Step 3: Ensure migration tracking table
        ensure_migration_table(conn)

        # Step 4: Find and apply pending migrations
        applied = get_applied_migrations(conn)
        migration_files = get_migration_files()

        if not migration_files:
            print("No migration files found in db/migrations/")
            return

        pending = [
            f for f in migration_files
            if extract_version(f) not in applied
        ]

        if not pending:
            print("All migrations already applied.")
            return

        print(f"Found {len(pending)} pending migration(s):")
        for filepath in pending:
            apply_migration(conn, filepath)

        print(f"\nAll {len(pending)} migration(s) applied successfully.")

    finally:
        conn.close()


if __name__ == '__main__':
    try:
        run_migrations()
    except Exception as e:
        print(f"\nMigration failed: {e}", file=sys.stderr)
        sys.exit(1)
