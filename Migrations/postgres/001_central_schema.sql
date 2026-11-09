-- VacationRentalCalendar — central schema, version 1
--
-- DESIGN REVIEW ONLY. This has not been applied to any database, and no
-- Aurora/RDS cluster exists. Reviewed as part of Phase 1.
--
-- Three invariants are enforced by the database itself rather than by
-- application discipline, because every one of them has a money cost when it
-- fails:
--
--   1. Every stay interval is half-open [check-in, check-out).  CHECK constraints.
--   2. No two confirmed reservations on one property may overlap.  EXCLUDE.
--   3. The availability audit trail cannot be rewritten.  Privileges.
--
-- Postgres 16.3+ (required for Aurora Serverless v2 minimum 0 ACU).

BEGIN;

CREATE EXTENSION IF NOT EXISTS btree_gist;  -- for EXCLUDE (uuid WITH =, daterange WITH &&)

-- ===========================================================================
-- Vocabulary
-- ===========================================================================

-- 'direct' is bostonfurnishedstays.com; 'owner' is a manual entry by me.
CREATE TYPE channel AS ENUM ('airbnb', 'vrbo', 'booking_com', 'direct', 'owner');

-- Carried over from BlockKind in Sources/VRCCore/Model/Classification.swift.
-- provisional_hold is new in this schema and exists so that a temporary hold
-- can never be confused with a confirmed reservation.
CREATE TYPE block_kind AS ENUM (
    'confirmed_reservation',
    'owner_block',
    'maintenance_block',
    'cancellation_block',      -- never exported, no override
    'platform_restriction',    -- never exported, no override
    'provisional_hold',        -- never exported, expires
    'unknown_unavailable'      -- never treated as a reservation
);

-- The subset of block_kind that may ever leave this system. Kept as a
-- function rather than a column so it cannot drift out of step with the
-- export gate, and so a new enum value defaults to NOT exportable.
CREATE FUNCTION describes_genuine_unavailability(k block_kind)
RETURNS boolean IMMUTABLE LANGUAGE sql AS $$
    SELECT k IN ('confirmed_reservation', 'owner_block', 'maintenance_block')
$$;

CREATE TYPE reservation_status AS ENUM (
    'confirmed',        -- holds inventory; includes an unpaid balance
    'provisional',      -- a hold; expires
    'pending_payment',  -- a hold with a payment in flight; expires
    'cancelled',
    'expired',
    'needs_review'      -- indeterminate: a human decides
);

CREATE TYPE decision_action AS ENUM ('block', 'reopen', 'leave_unchanged');

-- The existing state machine, unchanged. 'approved' is the state the two
-- preserved Vrbo decisions are in today.
CREATE TYPE decision_status AS ENUM (
    'draft', 'validated', 'awaiting_approval', 'approved', 'published',
    'awaiting_platform_refresh', 'verified', 'cancelled', 'failed'
);

CREATE TYPE verification AS ENUM ('platform_evidenced', 'owner_asserted');

CREATE TYPE feed_stage AS ENUM ('prepared', 'uploaded', 'purged', 'verified', 'failed');

-- Reusable half-open guard. Applied to every interval column in the schema.
CREATE FUNCTION is_half_open_night_range(r daterange)
RETURNS boolean IMMUTABLE LANGUAGE sql AS $$
    SELECT r IS NOT NULL
       AND NOT isempty(r)
       AND lower_inc(r)
       AND NOT upper_inc(r)
       AND lower(r) IS NOT NULL
       AND upper(r) IS NOT NULL
$$;

-- ===========================================================================
-- Structure
-- ===========================================================================

CREATE TABLE properties (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug        text NOT NULL UNIQUE,
    name        text NOT NULL,
    time_zone   text NOT NULL DEFAULT 'America/New_York',
    -- Per-property feed host, so a second property can serve from its own
    -- domain without reshaping anything: 39 G Street uses
    -- feeds.39gstboston.com.
    feed_host   text,
    legacy_id   integer UNIQUE,   -- SQLite properties.id, for reconciliation
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE platform_listings (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    property_id      uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
    channel          channel NOT NULL,
    external_id      text,
    -- notConfigured | connected | revoked | disconnectedByOwner |
    -- credentialUnreadable | failing | unknown  (FeedConnectionState)
    connection_state text NOT NULL DEFAULT 'not_configured',
    -- A Secrets Manager ARN or SSM parameter name. NEVER the feed URL or
    -- token itself: the rule that credentials never enter the database
    -- survives the move off the Keychain.
    credential_ref   text,
    last_import_at   timestamptz,
    last_success_at  timestamptz,
    revoked_at       timestamptz,
    legacy_id        integer UNIQUE,
    UNIQUE (property_id, channel),
    CONSTRAINT credential_ref_is_a_reference
        CHECK (credential_ref IS NULL
               OR credential_ref NOT LIKE '%://%')   -- a URL would be a leak
);

-- ===========================================================================
-- Layer 1 — observation. What a channel told us. Never edited.
-- ===========================================================================

CREATE TABLE import_runs (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    listing_id     uuid NOT NULL REFERENCES platform_listings(id) ON DELETE CASCADE,
    started_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz,
    outcome        text,
    events_seen    integer,
    raw_object_key text,     -- S3 key of the raw payload, for forensics
    error          text
);

CREATE INDEX idx_import_runs_listing ON import_runs (listing_id, started_at DESC);

CREATE TABLE source_events (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    listing_id    uuid NOT NULL REFERENCES platform_listings(id) ON DELETE CASCADE,
    event_key     text NOT NULL,          -- stable dedupe key (EventKey)
    source_uid    text,
    stay          daterange NOT NULL,
    summary       text NOT NULL DEFAULT '',
    raw_status    text,
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at  timestamptz NOT NULL DEFAULT now(),
    -- Set when a feed stops listing an event. The row is kept, so history is
    -- never destroyed by an upstream deletion.
    withdrawn_at  timestamptz,
    legacy_id     integer UNIQUE,          -- SQLite events.id
    UNIQUE (listing_id, event_key),
    CONSTRAINT source_events_half_open CHECK (is_half_open_night_range(stay))
);

CREATE INDEX idx_source_events_stay ON source_events USING gist (stay);
CREATE INDEX idx_source_events_live ON source_events (listing_id) WHERE withdrawn_at IS NULL;

-- Deliberately NO exclusion constraint here. Two channels can both claim the
-- same nights; that is a fact about the world and must be recordable. It
-- becomes a conflict row, not a rejected insert.

-- ===========================================================================
-- Layer 2 — interpretation
-- ===========================================================================

CREATE TABLE classifications (
    source_event_id bigint PRIMARY KEY REFERENCES source_events(id) ON DELETE CASCADE,
    kind            block_kind NOT NULL,
    needs_review    boolean NOT NULL DEFAULT false,
    set_by          text NOT NULL,          -- 'owner' | 'inferred'
    note            text NOT NULL DEFAULT '',
    decided_at      timestamptz NOT NULL DEFAULT now(),
    -- An owner decision. While true, no importer or inference pass may change
    -- `kind`. This is what preserves the seven existing manual
    -- classifications through every future import.
    locked          boolean NOT NULL DEFAULT false,
    CONSTRAINT owner_decisions_are_locked
        CHECK (set_by <> 'owner' OR locked)
);

-- The authoritative reservation record.
CREATE TABLE reservations (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    property_id     uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
    channel         channel NOT NULL,
    stay            daterange NOT NULL,
    status          reservation_status NOT NULL,
    verification    verification NOT NULL DEFAULT 'platform_evidenced',
    source_event_id bigint REFERENCES source_events(id),
    external_ref    text,         -- e.g. the website's bookingId
    -- Opaque, non-identifying. Guest names, emails, phone numbers and payment
    -- details are deliberately absent from this schema: this system decides
    -- availability and has no need of them.
    guest_ref       text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    cancelled_at    timestamptz,
    CONSTRAINT reservations_half_open CHECK (is_half_open_night_range(stay)),
    CONSTRAINT cancelled_has_timestamp
        CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL)),

    -- The structural double-booking guard. Two confirmed reservations cannot
    -- overlap on one property, whatever the application tries to do.
    --
    -- Imports do not write here directly; they write source_events, and a
    -- promotion step moves them across. A promotion that trips this
    -- constraint is a real double booking: the handler records a conflict and
    -- leaves the observation unpromoted rather than discarding it. So this one
    -- constraint is both the preventer and the detector.
    CONSTRAINT no_double_booking
        EXCLUDE USING gist (property_id WITH =, stay WITH &&)
        WHERE (status = 'confirmed')
);

CREATE INDEX idx_reservations_stay ON reservations USING gist (property_id, stay);
CREATE INDEX idx_reservations_live ON reservations (property_id, status)
    WHERE status IN ('confirmed', 'provisional', 'pending_payment');

CREATE TABLE holds (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    property_id    uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
    channel        channel NOT NULL,
    stay           daterange NOT NULL,
    expires_at     timestamptz NOT NULL,
    released_at    timestamptz,
    reservation_id uuid REFERENCES reservations(id),
    external_ref   text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT holds_half_open CHECK (is_half_open_night_range(stay)),

    -- An index predicate must be immutable, so now() cannot appear here. The
    -- constraint therefore covers every unreleased hold, and a sweeper sets
    -- released_at once expires_at passes — the same active-release design
    -- PriyankaHomes already runs, where TTL is only a backstop. Availability
    -- queries test (released_at IS NULL AND expires_at > now()), so an
    -- expired-but-unswept hold is never read as blocking.
    CONSTRAINT no_overlapping_live_holds
        EXCLUDE USING gist (property_id WITH =, stay WITH &&)
        WHERE (released_at IS NULL)
);

CREATE INDEX idx_holds_expiring ON holds (expires_at) WHERE released_at IS NULL;

-- ===========================================================================
-- Layer 3 — availability decisions
-- ===========================================================================

CREATE TABLE availability_decisions (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    property_id         uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
    destination         channel NOT NULL,
    action              decision_action NOT NULL,
    stay                daterange NOT NULL,
    status              decision_status NOT NULL,
    reason              text NOT NULL DEFAULT '',
    -- Carried over VERBATIM from SQLite. A changed UID makes a destination
    -- platform see a delete plus a create instead of an update, so these are
    -- migrated, never regenerated.
    publication_uid     text NOT NULL UNIQUE,
    created_by          text NOT NULL DEFAULT '',
    approved_by         text,
    supersedes_id       bigint REFERENCES availability_decisions(id),
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    validated_at        timestamptz,
    approved_at         timestamptz,
    published_at        timestamptz,
    refresh_expected_by timestamptz,
    verified_at         timestamptz,
    cancelled_at        timestamptz,
    failure_reason      text,
    legacy_id           integer UNIQUE,
    CONSTRAINT decisions_half_open CHECK (is_half_open_night_range(stay)),
    CONSTRAINT approved_has_approver
        CHECK (status NOT IN ('approved', 'published', 'awaiting_platform_refresh', 'verified')
               OR (approved_at IS NOT NULL AND approved_by IS NOT NULL))
);

CREATE INDEX idx_decisions_property ON availability_decisions (property_id, destination, status);
CREATE INDEX idx_decisions_stay ON availability_decisions USING gist (stay);

-- Append-only. Enforced by privilege below, not by convention.
CREATE TABLE availability_audit (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    decision_id bigint REFERENCES availability_decisions(id) ON DELETE RESTRICT,
    at          timestamptz NOT NULL DEFAULT now(),
    actor       text NOT NULL,
    from_status decision_status,
    to_status   decision_status,
    detail      text NOT NULL DEFAULT ''
);

CREATE INDEX idx_audit_decision ON availability_audit (decision_id, at);

-- ===========================================================================
-- Layer 4 — publication
-- ===========================================================================

CREATE TABLE published_feeds (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    property_id uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
    destination channel NOT NULL,
    object_key  text NOT NULL,     -- 128 bits of randomness lives here
    token_ref   text NOT NULL,     -- Secrets Manager reference, never the token
    scope       text NOT NULL DEFAULT 'approved_manual_blocks_only',
    rotated_at  timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (property_id, destination),
    CONSTRAINT token_ref_is_a_reference
        CHECK (token_ref NOT LIKE '%://%')
);

CREATE TABLE feed_publications (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    feed_id            uuid NOT NULL REFERENCES published_feeds(id) ON DELETE CASCADE,
    stage              feed_stage NOT NULL,
    revision           integer NOT NULL,
    entry_count        integer NOT NULL,
    night_count        integer NOT NULL,
    body_sha256        text NOT NULL,
    body_object_key    text,        -- durable last-known-good copy in S3
    -- Only a fully served feed may become the recovery point. A publication
    -- that stopped at 'uploaded' was never served to anyone.
    is_last_known_good boolean NOT NULL DEFAULT false,
    at                 timestamptz NOT NULL DEFAULT now(),
    error              text,
    CONSTRAINT lkg_must_be_complete
        CHECK (NOT is_last_known_good OR stage IN ('purged', 'verified'))
);

CREATE INDEX idx_publications_feed ON feed_publications (feed_id, at DESC);
CREATE UNIQUE INDEX idx_one_lkg_per_feed ON feed_publications (feed_id)
    WHERE is_last_known_good;

CREATE TABLE published_feed_entries (
    publication_id  bigint NOT NULL REFERENCES feed_publications(id) ON DELETE CASCADE,
    publication_uid text NOT NULL,
    stay            daterange NOT NULL,
    PRIMARY KEY (publication_id, publication_uid),
    CONSTRAINT entries_half_open CHECK (is_half_open_night_range(stay))
);

-- ===========================================================================
-- Conflicts
-- ===========================================================================

CREATE TABLE conflicts (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    property_id uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
    -- booking_conflict | unverified_booking_conflict | calendar_overlap |
    -- availability_discrepancy  (ConflictAnalysis.ConflictCategory)
    category    text NOT NULL,
    stay        daterange NOT NULL,
    detail      text NOT NULL,
    detected_at timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz,
    CONSTRAINT conflicts_half_open CHECK (is_half_open_night_range(stay))
);

CREATE TABLE conflict_acknowledgements (
    conflict_id     bigint PRIMARY KEY REFERENCES conflicts(id) ON DELETE CASCADE,
    acknowledged_at timestamptz NOT NULL DEFAULT now(),
    actor           text NOT NULL,
    note            text NOT NULL DEFAULT ''
);

-- ===========================================================================
-- Bookkeeping
-- ===========================================================================

CREATE TABLE app_settings (
    key   text PRIMARY KEY,
    value text NOT NULL
);

CREATE TABLE schema_migrations (
    version    integer PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);

-- Before/after reconciliation evidence, kept in the database so the
-- migration can be audited after the fact rather than trusted.
CREATE TABLE migration_reconciliation (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_at   timestamptz NOT NULL DEFAULT now(),
    phase    text NOT NULL,            -- 'before' | 'after'
    metric   text NOT NULL,
    expected bigint,
    observed bigint,
    matched  boolean
);

-- ===========================================================================
-- Availability, derived in one place
-- ===========================================================================

-- The single definition of an unavailable night. Everything else reads this,
-- so no caller can invent its own rule. Note what is absent: cancellation
-- blocks, platform restrictions, unknown blocks and expired holds.
CREATE VIEW blocking_intervals AS
    SELECT r.property_id, r.stay, 'reservation'::text AS basis, r.channel::text AS source
      FROM reservations r
     WHERE r.status = 'confirmed'
UNION ALL
    SELECT h.property_id, h.stay, 'hold', h.channel::text
      FROM holds h
     WHERE h.released_at IS NULL AND h.expires_at > now()
UNION ALL
    SELECT pl.property_id, se.stay, 'classified_block', pl.channel::text
      FROM source_events se
      JOIN platform_listings pl ON pl.id = se.listing_id
      JOIN classifications c ON c.source_event_id = se.id
     WHERE se.withdrawn_at IS NULL
       AND describes_genuine_unavailability(c.kind);

-- ===========================================================================
-- Roles
-- ===========================================================================

CREATE ROLE vrc_app;        -- the Lambdas
CREATE ROLE vrc_readonly;   -- dashboard read paths

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO vrc_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO vrc_app;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO vrc_readonly;

-- The audit trail is append-only for the application itself. Rewriting
-- history requires a separate administrative credential that the running
-- service does not hold.
REVOKE UPDATE, DELETE ON availability_audit FROM vrc_app;

-- Source observations are facts; the service may add and withdraw them but
-- never delete them.
REVOKE DELETE ON source_events FROM vrc_app;

INSERT INTO schema_migrations (version) VALUES (1);
INSERT INTO app_settings (key, value) VALUES
    ('feed_publication_scope', 'approved_manual_blocks_only'),
    ('outbound_sync_enabled',  'false');

COMMIT;
