"""
VerityTick — Audit Chain Tests

Tests hash-chain integrity:
- Event appending and hash computation
- Chain verification (normal, tampered, broken link)
- External checkpoint export
"""

import pytest

TENANT_APEX = 'a0000000-0000-0000-0000-000000000001'
TENANT_MERIDIAN = 'a0000000-0000-0000-0000-000000000002'


class TestAuditChain:

    def test_append_event(self, db):
        """Appending an event returns a valid event ID."""
        db.execute("""
            SELECT audit.append_event(%s, 'test_event', 'order', NULL, NULL,
                                      '{"key": "value"}'::jsonb)
        """, (TENANT_APEX,))
        event_id = db.fetchone()[0]
        assert event_id is not None

    def test_chain_grows(self, db):
        """Appending multiple events increments the sequence."""
        for i in range(3):
            db.execute("""
                SELECT audit.append_event(%s, 'test_event', NULL, NULL, NULL,
                                          %s::jsonb)
            """, (TENANT_APEX, f'{{"seq": {i}}}'))

        db.execute("""
            SELECT head_seq FROM audit.chain_state WHERE tenant_id = %s
        """, (TENANT_APEX,))
        assert db.fetchone()[0] == 3

    def test_hash_chain_linked(self, db):
        """Each event's previous_hash matches the prior event's event_hash."""
        for i in range(3):
            db.execute("""
                SELECT audit.append_event(%s, 'link_test', NULL, NULL, NULL,
                                          '{}'::jsonb)
            """, (TENANT_APEX,))

        db.execute("""
            SELECT seq, previous_hash, event_hash
            FROM audit.events
            WHERE tenant_id = %s
            ORDER BY seq
        """, (TENANT_APEX,))
        events = db.fetchall()

        assert events[0][1] == 'GENESIS'  # first event's prev is GENESIS
        for i in range(1, len(events)):
            assert events[i][1] == events[i-1][2]  # prev_hash = prior's event_hash

    def test_verify_valid_chain(self, db):
        """Verification passes for an untampered chain."""
        for i in range(5):
            db.execute("""
                SELECT audit.append_event(%s, 'verify_test', NULL, NULL, NULL,
                                          '{}'::jsonb)
            """, (TENANT_APEX,))

        db.execute("SELECT * FROM audit.verify_chain(%s)", (TENANT_APEX,))
        result = db.fetchone()
        assert result[0] is True  # is_valid
        assert result[1] == 5     # checked_events

    def test_detect_tampered_event(self, db):
        """Verification detects when an event's payload has been modified."""
        for i in range(3):
            db.execute("""
                SELECT audit.append_event(%s, 'tamper_test', NULL, NULL, NULL,
                                          '{}'::jsonb)
            """, (TENANT_APEX,))

        # Tamper with event 2's payload (direct UPDATE bypasses app logic)
        db.execute("""
            UPDATE audit.events
            SET payload = '{"tampered": true}'::jsonb
            WHERE tenant_id = %s AND seq = 2
        """, (TENANT_APEX,))

        db.execute("SELECT * FROM audit.verify_chain(%s)", (TENANT_APEX,))
        result = db.fetchone()
        assert result[0] is False  # is_valid
        assert result[2] == 2      # first_invalid_seq
        assert 'hash mismatch' in result[3].lower()

    def test_detect_broken_link(self, db):
        """Verification detects a broken previous_hash link."""
        for i in range(3):
            db.execute("""
                SELECT audit.append_event(%s, 'link_break_test', NULL, NULL, NULL,
                                          '{}'::jsonb)
            """, (TENANT_APEX,))

        # Break the chain link at event 3
        db.execute("""
            UPDATE audit.events
            SET previous_hash = 'deadbeef'
            WHERE tenant_id = %s AND seq = 3
        """, (TENANT_APEX,))

        db.execute("SELECT * FROM audit.verify_chain(%s)", (TENANT_APEX,))
        result = db.fetchone()
        assert result[0] is False
        assert 'broken link' in result[3].lower()

    def test_export_checkpoint(self, db):
        """Checkpoint export returns current chain head."""
        db.execute("""
            SELECT audit.append_event(%s, 'checkpoint_test', NULL, NULL, NULL,
                                      '{}'::jsonb)
        """, (TENANT_APEX,))

        db.execute("SELECT * FROM audit.export_checkpoint(%s)", (TENANT_APEX,))
        cp = db.fetchone()
        assert cp is not None
        assert cp[1] == TENANT_APEX     # tenant_id
        assert cp[2] >= 1               # head_seq
        assert len(cp[3]) == 64         # sha256 hex = 64 chars

    def test_separate_tenant_chains(self, db):
        """Each tenant has an independent chain."""
        db.execute("SELECT audit.append_event(%s, 'tenant1_event')", (TENANT_APEX,))
        db.execute("SELECT audit.append_event(%s, 'tenant2_event')", (TENANT_MERIDIAN,))

        db.execute("SELECT head_seq FROM audit.chain_state WHERE tenant_id = %s",
                   (TENANT_APEX,))
        assert db.fetchone()[0] == 1

        db.execute("SELECT head_seq FROM audit.chain_state WHERE tenant_id = %s",
                   (TENANT_MERIDIAN,))
        assert db.fetchone()[0] == 1
