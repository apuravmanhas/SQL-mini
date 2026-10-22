"""
VerityTick — Schema Constraint Tests

Tests that the database correctly enforces:
- Primary keys and uniqueness
- Foreign key relationships
- CHECK constraints
- NOT NULL constraints
- Tenant-account ownership trigger
"""

import pytest
import psycopg2
from psycopg2 import errors


# ─── Tenant Tests ──────────────────────────────────────────────────────

class TestTenantConstraints:

    def test_tenant_exists(self, db):
        """Verify seed tenants were loaded."""
        db.execute("SELECT COUNT(*) FROM core.tenants")
        assert db.fetchone()[0] == 3

    def test_tenant_name_unique(self, db):
        """Duplicate tenant name must be rejected."""
        with pytest.raises(errors.UniqueViolation):
            db.execute("""
                INSERT INTO core.tenants (name)
                VALUES ('Apex Trading Co')
            """)

    def test_tenant_invalid_status(self, db):
        """Invalid status value must be rejected."""
        with pytest.raises(errors.CheckViolation):
            db.execute("""
                INSERT INTO core.tenants (name, status)
                VALUES ('Bad Status Corp', 'deleted')
            """)

    def test_tenant_name_not_null(self, db):
        """Tenant name cannot be NULL."""
        with pytest.raises(errors.NotNullViolation):
            db.execute("""
                INSERT INTO core.tenants (name)
                VALUES (NULL)
            """)


# ─── User Tests ────────────────────────────────────────────────────────

class TestUserConstraints:

    def test_user_requires_valid_tenant(self, db):
        """User must reference an existing tenant."""
        with pytest.raises(errors.ForeignKeyViolation):
            db.execute("""
                INSERT INTO core.users (tenant_id, username, display_name)
                VALUES ('ffffffff-ffff-ffff-ffff-ffffffffffff', 'ghost', 'Ghost User')
            """)

    def test_user_username_unique_per_tenant(self, db):
        """Same username within a tenant must be rejected."""
        with pytest.raises(errors.UniqueViolation):
            db.execute("""
                INSERT INTO core.users (tenant_id, username, display_name)
                VALUES ('a0000000-0000-0000-0000-000000000001', 'alice', 'Another Alice')
            """)

    def test_user_same_username_different_tenants(self, db):
        """Same username in different tenants is allowed."""
        db.execute("""
            INSERT INTO core.users (tenant_id, username, display_name)
            VALUES ('a0000000-0000-0000-0000-000000000002', 'alice', 'Alice At Meridian')
        """)
        # Should succeed — no exception

    def test_user_invalid_status(self, db):
        """Invalid user status must be rejected."""
        with pytest.raises(errors.CheckViolation):
            db.execute("""
                INSERT INTO core.users
                    (tenant_id, username, display_name, status)
                VALUES
                    ('a0000000-0000-0000-0000-000000000001', 'zara', 'Zara', 'banned')
            """)


# ─── Asset Tests ───────────────────────────────────────────────────────

class TestAssetConstraints:

    def test_asset_symbol_unique(self, db):
        """Duplicate asset symbol must be rejected."""
        with pytest.raises(errors.UniqueViolation):
            db.execute("""
                INSERT INTO core.assets (symbol, name, asset_type)
                VALUES ('USDX', 'Duplicate Dollar', 'currency')
            """)

    def test_asset_invalid_type(self, db):
        """Invalid asset type must be rejected."""
        with pytest.raises(errors.CheckViolation):
            db.execute("""
                INSERT INTO core.assets (symbol, name, asset_type)
                VALUES ('TOKN', 'Token', 'nft')
            """)

    def test_asset_precision_negative(self, db):
        """Negative precision must be rejected."""
        with pytest.raises(errors.CheckViolation):
            db.execute("""
                INSERT INTO core.assets (symbol, name, precision_scale)
                VALUES ('NEG', 'Negative Precision', -1)
            """)

    def test_asset_precision_too_high(self, db):
        """Precision above 18 must be rejected."""
        with pytest.raises(errors.CheckViolation):
            db.execute("""
                INSERT INTO core.assets (symbol, name, precision_scale)
                VALUES ('BIG', 'Too Precise', 19)
            """)


# ─── Market Tests ──────────────────────────────────────────────────────

class TestMarketConstraints:

    def test_market_symbol_unique(self, db):
        """Duplicate market symbol must be rejected."""
        with pytest.raises(errors.UniqueViolation):
            db.execute("""
                INSERT INTO core.markets
                    (symbol, base_asset_id, quote_asset_id)
                VALUES
                    ('ACME/USDX',
                     'c0000000-0000-0000-0000-000000000002',
                     'c0000000-0000-0000-0000-000000000001')
            """)

    def test_market_same_base_and_quote(self, db):
        """Base and quote asset cannot be the same."""
        with pytest.raises(errors.CheckViolation):
            db.execute("""
                INSERT INTO core.markets
                    (symbol, base_asset_id, quote_asset_id)
                VALUES
                    ('USDX/USDX',
                     'c0000000-0000-0000-0000-000000000001',
                     'c0000000-0000-0000-0000-000000000001')
            """)

    def test_market_invalid_base_asset(self, db):
        """Market must reference valid base asset."""
        with pytest.raises(errors.ForeignKeyViolation):
            db.execute("""
                INSERT INTO core.markets
                    (symbol, base_asset_id, quote_asset_id)
                VALUES
                    ('FAKE/USDX',
                     'ffffffff-ffff-ffff-ffff-ffffffffffff',
                     'c0000000-0000-0000-0000-000000000001')
            """)

    def test_market_min_quantity_positive(self, db):
        """Minimum quantity must be positive."""
        with pytest.raises(errors.CheckViolation):
            db.execute("""
                INSERT INTO core.markets
                    (symbol, base_asset_id, quote_asset_id, min_quantity)
                VALUES
                    ('TEST/USDX',
                     'c0000000-0000-0000-0000-000000000002',
                     'c0000000-0000-0000-0000-000000000001',
                     0)
            """)

    def test_market_invalid_status(self, db):
        """Invalid market status must be rejected."""
        with pytest.raises(errors.CheckViolation):
            db.execute("""
                INSERT INTO core.markets
                    (symbol, base_asset_id, quote_asset_id, status)
                VALUES
                    ('TST2/USDX',
                     'c0000000-0000-0000-0000-000000000002',
                     'c0000000-0000-0000-0000-000000000001',
                     'paused')
            """)


# ─── Trading Account Tests ────────────────────────────────────────────

class TestAccountConstraints:

    def test_account_requires_valid_tenant(self, db):
        """Account must reference an existing tenant.
        The tenant-ownership trigger fires before FK check, so we get CheckViolation
        because the user doesn't belong to the fake tenant.
        """
        with pytest.raises((errors.ForeignKeyViolation, errors.CheckViolation)):
            db.execute("""
                INSERT INTO core.trading_accounts
                    (tenant_id, user_id, label)
                VALUES
                    ('ffffffff-ffff-ffff-ffff-ffffffffffff',
                     'b0000000-0000-0000-0000-000000000001',
                     'rogue')
            """)

    def test_account_requires_valid_user(self, db):
        """Account must reference an existing user.
        The tenant-ownership trigger fires before FK check, so we get CheckViolation
        because the fake user doesn't belong to the tenant.
        """
        with pytest.raises((errors.ForeignKeyViolation, errors.CheckViolation)):
            db.execute("""
                INSERT INTO core.trading_accounts
                    (tenant_id, user_id, label)
                VALUES
                    ('a0000000-0000-0000-0000-000000000001',
                     'ffffffff-ffff-ffff-ffff-ffffffffffff',
                     'rogue')
            """)

    def test_account_user_tenant_mismatch(self, db):
        """Account's user must belong to the account's tenant."""
        # diana (user 4) belongs to Meridian (tenant 2),
        # but we try to create account under Apex (tenant 1)
        with pytest.raises(psycopg2.errors.CheckViolation):
            db.execute("""
                INSERT INTO core.trading_accounts
                    (tenant_id, user_id, label)
                VALUES
                    ('a0000000-0000-0000-0000-000000000001',
                     'b0000000-0000-0000-0000-000000000004',
                     'cross-tenant')
            """)

    def test_account_label_unique_per_user(self, db):
        """Same label for same user must be rejected."""
        with pytest.raises(errors.UniqueViolation):
            db.execute("""
                INSERT INTO core.trading_accounts
                    (tenant_id, user_id, label)
                VALUES
                    ('a0000000-0000-0000-0000-000000000001',
                     'b0000000-0000-0000-0000-000000000001',
                     'default')
            """)

    def test_account_same_label_different_users(self, db):
        """Same label for different users is fine."""
        # Both alice and bob can have 'default' — already in seed data
        db.execute("""
            SELECT COUNT(*) FROM core.trading_accounts
            WHERE label = 'default'
        """)
        count = db.fetchone()[0]
        assert count >= 2

    def test_account_invalid_status(self, db):
        """Invalid account status must be rejected."""
        with pytest.raises(errors.CheckViolation):
            db.execute("""
                INSERT INTO core.trading_accounts
                    (tenant_id, user_id, label, status)
                VALUES
                    ('a0000000-0000-0000-0000-000000000001',
                     'b0000000-0000-0000-0000-000000000001',
                     'test', 'deleted')
            """)
