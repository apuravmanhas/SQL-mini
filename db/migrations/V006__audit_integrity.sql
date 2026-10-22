-- VerityTick Migration V006
-- Tamper-Evident Audit Log with Hash Chain
--
-- Implements:
-- - Append-only audit events for all important actions
-- - SHA-256 hash chain via pgcrypto for tamper evidence
-- - Per-tenant chains with atomic sequence assignment
-- - Verification functions for chain integrity
--
-- TRUST MODEL:
-- This chain is tamper-evident under the assumption that a verifier
-- retains independent checkpoints. A sufficiently privileged actor
-- who can rewrite the entire chain and its state table can reconstruct
-- a consistent alternative history. See docs/KNOWN_LIMITATIONS.md.

-- =============================================================================
-- Audit Chain State (one row per tenant chain)
-- =============================================================================

CREATE TABLE audit.chain_state (
    chain_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES core.tenants(tenant_id) UNIQUE,
    head_seq        BIGINT NOT NULL DEFAULT 0,
    head_hash       TEXT NOT NULL DEFAULT 'GENESIS',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE audit.chain_state IS
    'Tracks the current head of each tenant''s audit hash chain';

-- =============================================================================
-- Audit Events
-- =============================================================================

CREATE TABLE audit.events (
    event_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    chain_id            UUID NOT NULL REFERENCES audit.chain_state(chain_id),
    tenant_id           UUID NOT NULL REFERENCES core.tenants(tenant_id),
    seq                 BIGINT NOT NULL,

    -- Event content
    event_type          TEXT NOT NULL,
    entity_type         TEXT,
    entity_id           UUID,
    actor_id            UUID,
    event_timestamp     TIMESTAMPTZ NOT NULL DEFAULT now(),
    payload             JSONB NOT NULL DEFAULT '{}'::jsonb,

    -- Hash chain
    previous_hash       TEXT NOT NULL,
    event_hash          TEXT NOT NULL,

    -- Canonicalization
    canon_version       SMALLINT NOT NULL DEFAULT 1,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Each chain has unique sequence numbers
    CONSTRAINT uq_chain_seq UNIQUE (chain_id, seq)
);

CREATE INDEX idx_audit_events_tenant ON audit.events (tenant_id, seq);
CREATE INDEX idx_audit_events_type ON audit.events (event_type);
CREATE INDEX idx_audit_events_entity ON audit.events (entity_type, entity_id);

COMMENT ON TABLE audit.events IS
    'Immutable audit trail with SHA-256 hash chain for tamper evidence';
COMMENT ON COLUMN audit.events.canon_version IS
    'Serialization format version. Allows future format changes without breaking old hashes.';

-- =============================================================================
-- Canonical serialization (version 1)
-- =============================================================================

CREATE OR REPLACE FUNCTION audit.canonicalize_v1(
    p_chain_id UUID,
    p_seq BIGINT,
    p_event_type TEXT,
    p_entity_type TEXT,
    p_entity_id UUID,
    p_actor_id UUID,
    p_event_timestamp TIMESTAMPTZ,
    p_payload JSONB,
    p_previous_hash TEXT
) RETURNS TEXT AS $$
BEGIN
    -- Deterministic canonical form:
    -- chain_id|seq|event_type|entity_type|entity_id|actor_id|timestamp_iso|payload_sorted|previous_hash
    -- NULL fields → empty string
    RETURN p_chain_id::TEXT || '|' ||
           p_seq::TEXT || '|' ||
           p_event_type || '|' ||
           COALESCE(p_entity_type, '') || '|' ||
           COALESCE(p_entity_id::TEXT, '') || '|' ||
           COALESCE(p_actor_id::TEXT, '') || '|' ||
           to_char(p_event_timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') || '|' ||
           COALESCE(p_payload::TEXT, '{}') || '|' ||
           p_previous_hash;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- =============================================================================
-- Hash computation
-- =============================================================================

CREATE OR REPLACE FUNCTION audit.compute_hash(p_canonical TEXT)
RETURNS TEXT AS $$
BEGIN
    RETURN encode(digest(p_canonical, 'sha256'), 'hex');
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- =============================================================================
-- Append an audit event (atomic, serialized per chain)
-- =============================================================================

CREATE OR REPLACE FUNCTION audit.append_event(
    p_tenant_id UUID,
    p_event_type TEXT,
    p_entity_type TEXT DEFAULT NULL,
    p_entity_id UUID DEFAULT NULL,
    p_actor_id UUID DEFAULT NULL,
    p_payload JSONB DEFAULT '{}'::jsonb
) RETURNS UUID AS $$
DECLARE
    v_chain_id UUID;
    v_new_seq BIGINT;
    v_prev_hash TEXT;
    v_canonical TEXT;
    v_event_hash TEXT;
    v_event_id UUID;
    v_now TIMESTAMPTZ := now();
BEGIN
    -- Get or create chain state, locking for serialization
    INSERT INTO audit.chain_state (tenant_id)
    VALUES (p_tenant_id)
    ON CONFLICT (tenant_id) DO NOTHING;

    SELECT chain_id, head_seq, head_hash
    INTO v_chain_id, v_new_seq, v_prev_hash
    FROM audit.chain_state
    WHERE tenant_id = p_tenant_id
    FOR UPDATE;

    v_new_seq := v_new_seq + 1;

    -- Compute canonical form and hash
    v_canonical := audit.canonicalize_v1(
        v_chain_id, v_new_seq, p_event_type,
        p_entity_type, p_entity_id, p_actor_id,
        v_now, p_payload, v_prev_hash
    );
    v_event_hash := audit.compute_hash(v_canonical);

    -- Insert event
    INSERT INTO audit.events (
        chain_id, tenant_id, seq, event_type,
        entity_type, entity_id, actor_id,
        event_timestamp, payload,
        previous_hash, event_hash, canon_version
    ) VALUES (
        v_chain_id, p_tenant_id, v_new_seq, p_event_type,
        p_entity_type, p_entity_id, p_actor_id,
        v_now, p_payload,
        v_prev_hash, v_event_hash, 1
    ) RETURNING event_id INTO v_event_id;

    -- Update chain head
    UPDATE audit.chain_state
    SET head_seq = v_new_seq,
        head_hash = v_event_hash,
        updated_at = v_now
    WHERE chain_id = v_chain_id;

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- Verify chain integrity
-- =============================================================================

CREATE OR REPLACE FUNCTION audit.verify_chain(
    p_tenant_id UUID
) RETURNS TABLE (
    is_valid BOOLEAN,
    checked_events BIGINT,
    first_invalid_seq BIGINT,
    error_message TEXT
) AS $$
DECLARE
    v_chain_id UUID;
    v_expected_head_seq BIGINT;
    v_expected_head_hash TEXT;
    v_prev_hash TEXT := 'GENESIS';
    v_event RECORD;
    v_recomputed_canonical TEXT;
    v_recomputed_hash TEXT;
    v_count BIGINT := 0;
BEGIN
    -- Get chain state
    SELECT cs.chain_id, cs.head_seq, cs.head_hash
    INTO v_chain_id, v_expected_head_seq, v_expected_head_hash
    FROM audit.chain_state cs
    WHERE cs.tenant_id = p_tenant_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT true, 0::BIGINT, NULL::BIGINT,
            'No chain exists for this tenant'::TEXT;
        RETURN;
    END IF;

    -- Walk the chain in order
    FOR v_event IN
        SELECT * FROM audit.events e
        WHERE e.chain_id = v_chain_id
        ORDER BY e.seq ASC
    LOOP
        v_count := v_count + 1;

        -- Check sequence continuity
        IF v_event.seq != v_count THEN
            RETURN QUERY SELECT false, v_count, v_event.seq,
                ('Missing sequence: expected ' || v_count || ', found ' || v_event.seq)::TEXT;
            RETURN;
        END IF;

        -- Check previous hash linkage
        IF v_event.previous_hash != v_prev_hash THEN
            RETURN QUERY SELECT false, v_count, v_event.seq,
                ('Broken link at seq ' || v_event.seq ||
                 ': expected prev_hash ' || v_prev_hash ||
                 ', found ' || v_event.previous_hash)::TEXT;
            RETURN;
        END IF;

        -- Recompute hash
        IF v_event.canon_version = 1 THEN
            v_recomputed_canonical := audit.canonicalize_v1(
                v_event.chain_id, v_event.seq, v_event.event_type,
                v_event.entity_type, v_event.entity_id, v_event.actor_id,
                v_event.event_timestamp, v_event.payload, v_event.previous_hash
            );
        ELSE
            RETURN QUERY SELECT false, v_count, v_event.seq,
                ('Unsupported canon_version: ' || v_event.canon_version)::TEXT;
            RETURN;
        END IF;

        v_recomputed_hash := audit.compute_hash(v_recomputed_canonical);

        IF v_recomputed_hash != v_event.event_hash THEN
            RETURN QUERY SELECT false, v_count, v_event.seq,
                ('Hash mismatch at seq ' || v_event.seq ||
                 ': stored ' || v_event.event_hash ||
                 ', computed ' || v_recomputed_hash)::TEXT;
            RETURN;
        END IF;

        v_prev_hash := v_event.event_hash;
    END LOOP;

    -- Verify head consistency
    IF v_count != v_expected_head_seq THEN
        RETURN QUERY SELECT false, v_count, NULL::BIGINT,
            ('Head seq mismatch: chain_state says ' || v_expected_head_seq ||
             ', found ' || v_count || ' events')::TEXT;
        RETURN;
    END IF;

    IF v_prev_hash != v_expected_head_hash THEN
        RETURN QUERY SELECT false, v_count, NULL::BIGINT,
            ('Head hash mismatch: chain_state says ' || v_expected_head_hash ||
             ', last event hash is ' || v_prev_hash)::TEXT;
        RETURN;
    END IF;

    RETURN QUERY SELECT true, v_count, NULL::BIGINT,
        ('Chain valid: ' || v_count || ' events verified')::TEXT;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- Export checkpoint for external verification
-- =============================================================================

CREATE OR REPLACE FUNCTION audit.export_checkpoint(
    p_tenant_id UUID
) RETURNS TABLE (
    chain_id UUID,
    tenant_id UUID,
    head_seq BIGINT,
    head_hash TEXT,
    checkpoint_time TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT cs.chain_id, cs.tenant_id, cs.head_seq, cs.head_hash, now()
    FROM audit.chain_state cs
    WHERE cs.tenant_id = p_tenant_id;
END;
$$ LANGUAGE plpgsql;
