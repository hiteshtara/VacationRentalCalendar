-- VacationRentalCalendar -- PostgreSQL safety layer
--
-- Hand-written, and NOT regenerated: this is everything Postgres can enforce
-- that SQLite cannot, expressed over the generated repository schema in
-- 010_repository_schema.sql.
--
-- The bridge is generated columns. The repositories keep writing epoch doubles
-- and check_in/check_out pairs, exactly as they do against SQLite, while the
-- constraints and guards here operate on real `date`, `timestamptz` and
-- `daterange` values derived from those same columns. Neither side
-- compromises, and the two cannot disagree because one is computed from the
-- other.
--
-- DESIGN REVIEW ONLY. Not applied to any cloud database.

BEGIN;

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ===========================================================================
-- Bridging columns
-- ===========================================================================

-- An epoch double is a point in time; the repositories store midnight UTC for
-- a calendar day. `to_timestamp` then `::date` recovers the day without
-- re-introducing a timezone, which is what keeps the half-open night interval
-- honest across a DST boundary.
CREATE FUNCTION vrc_day(epoch double precision) RETURNS date
IMMUTABLE STRICT LANGUAGE sql AS $$
    SELECT (timezone('UTC', to_timestamp(epoch)))::date
$$;

ALTER TABLE events
    ADD COLUMN stay daterange
        GENERATED ALWAYS AS (daterange(vrc_day(check_in), vrc_day(check_out), '[)')) STORED,
    ADD COLUMN last_seen_ts timestamptz
        GENERATED ALWAYS AS (to_timestamp(last_seen_at)) STORED;

ALTER TABLE availability_decisions
    ADD COLUMN stay daterange
        GENERATED ALWAYS AS (daterange(vrc_day(start_day), vrc_day(end_day), '[)')) STORED;

ALTER TABLE published_feed_entries
    ADD COLUMN stay daterange
        GENERATED ALWAYS AS (daterange(vrc_day(start_day), vrc_day(end_day), '[)')) STORED;

CREATE INDEX idx_events_stay ON events USING gist (stay);
CREATE INDEX idx_events_live ON events (listing_id) WHERE is_tombstoned = 0;
CREATE INDEX idx_decisions_stay ON availability_decisions USING gist (stay);
CREATE INDEX idx_decisions_lookup
    ON availability_decisions (property_id, destination, status);
CREATE UNIQUE INDEX idx_decisions_publication_uid
    ON availability_decisions (publication_uid);

-- A night interval must be half-open and bounded. `daterange` canonicalises to
-- `[)` for a discrete type, so the bound shape is guaranteed; what this
-- forbids is an empty or unbounded range, both of which are representable and
-- would be catastrophic.
ALTER TABLE events ADD CONSTRAINT events_stay_sane
    CHECK (NOT isempty(stay) AND lower(stay) IS NOT NULL AND upper(stay) IS NOT NULL);
ALTER TABLE availability_decisions ADD CONSTRAINT decisions_stay_sane
    CHECK (NOT isempty(stay) AND lower(stay) IS NOT NULL AND upper(stay) IS NOT NULL);

-- ===========================================================================
-- Bookings we admit ourselves
-- ===========================================================================

-- `events` deliberately carries no overlap constraint: Airbnb and Vrbo can
-- both report overlapping nights, and that is a fact to record and surface as
-- a conflict, not an insert to reject. ConflictDetector does that, identically
-- on both dialects.
--
-- Direct bookings are different. We admit those, so we can refuse to admit two
-- that overlap -- and the database is the right place for that, because no
-- application bug can get past it.
CREATE TYPE reservation_status AS ENUM (
    'confirmed', 'provisional', 'pending_payment',
    'cancelled', 'expired', 'needs_review'
);

CREATE TABLE reservations (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    property_id   bigint NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
    channel       text NOT NULL,
    check_in      double precision NOT NULL,
    check_out     double precision NOT NULL,
    status        reservation_status NOT NULL,
    external_ref  text,
    -- Opaque. Guest names, emails and payment details are deliberately absent:
    -- this system decides availability and has no need of them.
    guest_ref     text,
    created_at    double precision NOT NULL,
    updated_at    double precision NOT NULL,
    cancelled_at  double precision,
    stay daterange
        GENERATED ALWAYS AS (daterange(vrc_day(check_in), vrc_day(check_out), '[)')) STORED,
    CONSTRAINT reservations_stay_sane
        CHECK (NOT isempty(daterange(vrc_day(check_in), vrc_day(check_out), '[)'))),
    CONSTRAINT cancelled_has_timestamp
        CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL)),
    -- Verified: Dec 15-20 is refused against Dec 10-17, while Dec 17-20 is
    -- accepted, because a guest leaving on the 17th and another arriving on
    -- the 17th is not a conflict.
    CONSTRAINT no_double_booking
        EXCLUDE USING gist (property_id WITH =, stay WITH &&) WHERE (status = 'confirmed')
);

CREATE TABLE holds (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    property_id    bigint NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
    channel        text NOT NULL,
    check_in       double precision NOT NULL,
    check_out      double precision NOT NULL,
    expires_at     timestamptz NOT NULL,
    released_at    timestamptz,
    reservation_id bigint REFERENCES reservations(id),
    external_ref   text,
    created_at     double precision NOT NULL,
    stay daterange
        GENERATED ALWAYS AS (daterange(vrc_day(check_in), vrc_day(check_out), '[)')) STORED,
    -- An index predicate must be immutable, so now() cannot appear here. The
    -- constraint covers every unreleased hold and the sweeper sets released_at
    -- once expires_at passes; availability queries additionally test
    -- expires_at > now(), so an expired-but-unswept hold never reads as
    -- blocking.
    CONSTRAINT no_overlapping_live_holds
        EXCLUDE USING gist (property_id WITH =, stay WITH &&) WHERE (released_at IS NULL)
);

CREATE INDEX idx_holds_expiring ON holds (expires_at) WHERE released_at IS NULL;

CREATE TABLE conflicts (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    property_id bigint NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
    category    text NOT NULL,
    check_in    double precision NOT NULL,
    check_out   double precision NOT NULL,
    detail      text NOT NULL,
    detected_at timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz
);

-- ===========================================================================
-- What may ever leave this system
-- ===========================================================================

-- An allow-list, so a BlockKind added later is NOT exportable by default. The
-- failure mode of forgetting to update this is a night left on sale, which is
-- recoverable; the opposite would silently withdraw inventory.
-- The values are BlockKind.rawValue, which is snake_case. An earlier revision
-- used the Swift case names instead, so this returned false for everything and
-- blocking_intervals silently reported zero classified blocks -- every owner
-- block and maintenance block missing from the database's view of
-- availability. Caught by the cross-dialect test that compares this function
-- against describesGenuineUnavailability for every BlockKind, which is now a
-- standing check rather than a one-off.
CREATE FUNCTION describes_genuine_unavailability(kind text)
RETURNS boolean IMMUTABLE STRICT LANGUAGE sql AS $$
    SELECT kind IN ('confirmed_reservation', 'owner_block', 'maintenance_block')
$$;

-- One definition of an unavailable night, so no caller can invent its own.
-- Note what is absent: cancellation blocks, platform restrictions, unknown
-- blocks, tombstoned events and expired holds.
CREATE VIEW blocking_intervals AS
    SELECT r.property_id, r.stay, 'reservation'::text AS basis, r.channel AS source
      FROM reservations r
     WHERE r.status = 'confirmed'
UNION ALL
    SELECT h.property_id, h.stay, 'hold', h.channel
      FROM holds h
     WHERE h.released_at IS NULL AND h.expires_at > now()
UNION ALL
    SELECT pl.property_id, e.stay, 'classified_block', pl.platform
      FROM events e
      JOIN platform_listings pl ON pl.id = e.listing_id
      JOIN classifications c ON c.event_key = e.event_key
     WHERE e.is_tombstoned = 0
       AND describes_genuine_unavailability(c.kind);

-- ===========================================================================
-- Actors
-- ===========================================================================

CREATE FUNCTION vrc_actor_is_valid(a text) RETURNS boolean
IMMUTABLE LANGUAGE sql AS $$
    SELECT a IN ('importer', 'owner', 'website', 'admin')
$$;

-- An unrecognised actor degrades to 'importer', the least privileged, rather
-- than erroring: a typo must fail safe, not fail open.
CREATE FUNCTION vrc_current_actor() RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN vrc_actor_is_valid(coalesce(nullif(current_setting('vrc.actor', true), ''), 'importer'))
        THEN coalesce(nullif(current_setting('vrc.actor', true), ''), 'importer')
        ELSE 'importer'
    END
$$;

-- An authorisation names the listing AND the exact count, so one obtained for
-- a 3-event withdrawal cannot silently cover a 300-event one.
CREATE FUNCTION vrc_withdrawal_authorized(p_listing bigint, p_count bigint)
RETURNS boolean STABLE LANGUAGE sql AS $$
    SELECT coalesce(current_setting('vrc.authorize_withdrawal', true), '')
         = p_listing::text || ':' || p_count::text
$$;

-- ===========================================================================
-- Guard 1 and 2 -- withdrawal of observed events
-- ===========================================================================

CREATE FUNCTION vrc_guard_withdrawal() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    r             record;
    v_live_after  bigint;
    v_live_before bigint;
    v_owner_set   bigint;
    v_actor       text := vrc_current_actor();
BEGIN
    FOR r IN
        SELECT n.listing_id AS listing_id, count(*) AS withdrawn
          FROM new_rows n JOIN old_rows o ON o.id = n.id
         WHERE o.is_tombstoned = 0 AND n.is_tombstoned <> 0
         GROUP BY n.listing_id
    LOOP
        -- Guard 1: an event the owner classified by hand is never collateral
        -- damage of an import. `source = 'manual'` is the owner's own
        -- decision, which is what preserves cancellation restrictions, owner
        -- blocks, maintenance blocks and platform restrictions.
        SELECT count(*) INTO v_owner_set
          FROM new_rows n
          JOIN old_rows o ON o.id = n.id
          JOIN classifications c ON c.event_key = n.event_key
         WHERE n.listing_id = r.listing_id
           AND o.is_tombstoned = 0 AND n.is_tombstoned <> 0
           AND c.source = 'manual';

        IF v_owner_set > 0 AND NOT vrc_withdrawal_authorized(r.listing_id, r.withdrawn) THEN
            RAISE EXCEPTION
                'refusing to withdraw % event(s) carrying your own classification on listing % '
                '(actor %). A feed must not retract a decision you made.',
                v_owner_set, r.listing_id, v_actor
                USING ERRCODE = 'raise_exception';
        END IF;

        SELECT count(*) INTO v_live_after
          FROM events WHERE listing_id = r.listing_id AND is_tombstoned = 0;
        v_live_before := v_live_after + r.withdrawn;

        -- Guard 2a: the feed came back empty. Always refused -- that is the
        -- shape of a revoked token or an HTML error page served with a 200.
        IF v_live_after = 0 AND v_live_before > 0
           AND NOT vrc_withdrawal_authorized(r.listing_id, r.withdrawn) THEN
            RAISE EXCEPTION
                'refusing to withdraw ALL % live event(s) on listing % (actor %). '
                'An empty feed is not evidence that dates are free.',
                v_live_before, r.listing_id, v_actor
                USING ERRCODE = 'raise_exception';
        END IF;

        -- Guard 2b: more than half the listing vanished in one statement.
        IF r.withdrawn * 2 > v_live_before
           AND NOT vrc_withdrawal_authorized(r.listing_id, r.withdrawn) THEN
            RAISE EXCEPTION
                'refusing to withdraw % of % live event(s) on listing % (actor %) -- '
                'more than half. A feed this much smaller is treated as incomplete.',
                r.withdrawn, v_live_before, r.listing_id, v_actor
                USING ERRCODE = 'raise_exception';
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE TRIGGER guard_withdrawal
    AFTER UPDATE ON events
    REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION vrc_guard_withdrawal();

CREATE FUNCTION vrc_reject_truncate() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION
        'TRUNCATE is not permitted on %. Observations and audit rows are '
        'append-only; withdraw events individually so the guards can see it.',
        TG_TABLE_NAME USING ERRCODE = 'raise_exception';
END;
$$;

CREATE TRIGGER reject_truncate BEFORE TRUNCATE ON events
    FOR EACH STATEMENT EXECUTE FUNCTION vrc_reject_truncate();
CREATE TRIGGER reject_truncate_audit BEFORE TRUNCATE ON availability_audit
    FOR EACH STATEMENT EXECUTE FUNCTION vrc_reject_truncate();
CREATE TRIGGER reject_truncate_reservations BEFORE TRUNCATE ON reservations
    FOR EACH STATEMENT EXECUTE FUNCTION vrc_reject_truncate();

-- ===========================================================================
-- Guard 3 -- a confirmed reservation never silently loses its dates
-- ===========================================================================

CREATE FUNCTION vrc_protect_confirmed_reservation() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_actor text := vrc_current_actor();
    v_sanctioned boolean := coalesce(
        current_setting('vrc.cancellation_in_progress', true) = NEW.id::text, false);
    v_new_stay daterange;
    v_old_stay daterange;
BEGIN
    IF OLD.status = 'confirmed' AND NEW.status <> 'confirmed' THEN
        IF v_actor = 'importer' THEN
            RAISE EXCEPTION
                'refusing to move reservation % out of confirmed (to %) on an import. '
                'A feed omitting a booking is not a cancellation.', OLD.id, NEW.status
                USING ERRCODE = 'raise_exception';
        END IF;
        IF v_actor = 'website' AND NOT v_sanctioned THEN
            RAISE EXCEPTION
                'a website cancellation must go through vrc_cancel_website_booking, '
                'which records the reason and the audit row. Reservation %.', OLD.id
                USING ERRCODE = 'raise_exception';
        END IF;
    END IF;

    -- Shrinking frees nights just as surely as cancelling.
    --
    -- The ranges are recomputed from the base columns rather than read from
    -- NEW.stay. `stay` is a GENERATED column, and PostgreSQL fills generated
    -- columns AFTER a BEFORE trigger runs -- so NEW.stay is NULL here, and the
    -- obvious `NOT (NEW.stay @> OLD.stay)` evaluated to NULL, which is not
    -- true, so the guard never fired. It let an importer move a confirmed
    -- check-out from the 8th to the 3rd and silently free five nights.
    IF OLD.status = 'confirmed' AND NEW.status = 'confirmed'
       AND v_actor IN ('importer', 'website') THEN
        v_new_stay := daterange(vrc_day(NEW.check_in), vrc_day(NEW.check_out), '[)');
        v_old_stay := daterange(vrc_day(OLD.check_in), vrc_day(OLD.check_out), '[)');
        IF NOT (v_new_stay @> v_old_stay) THEN
            RAISE EXCEPTION
                'refusing to shrink confirmed reservation % as % (% -> %).',
                OLD.id, v_actor, v_old_stay, v_new_stay
                USING ERRCODE = 'raise_exception';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER protect_confirmed_reservation
    BEFORE UPDATE ON reservations
    FOR EACH ROW EXECUTE FUNCTION vrc_protect_confirmed_reservation();

-- ===========================================================================
-- The controlled website cancellation
-- ===========================================================================

-- The actor comes from the session, never from an argument: the trigger reads
-- the session, so an argument would be a second source of truth -- and would
-- have let an importer elevate simply by passing 'owner'.
CREATE FUNCTION vrc_cancel_website_booking(
    p_reservation_id bigint,
    p_reason         text,
    p_external_ref   text DEFAULT NULL
) RETURNS TABLE (nights_released int, cancelled_at double precision)
LANGUAGE plpgsql AS $$
DECLARE
    r        reservations;
    v_nights int;
    v_now    double precision := extract(epoch from now());
    p_actor  text := vrc_current_actor();
BEGIN
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'a cancellation reason is required'
            USING ERRCODE = 'raise_exception';
    END IF;
    IF p_actor NOT IN ('website', 'owner', 'admin') THEN
        RAISE EXCEPTION
            'actor % may not cancel a reservation. An import must never conclude '
            'that a booking was cancelled.', p_actor USING ERRCODE = 'raise_exception';
    END IF;

    SELECT * INTO r FROM reservations WHERE id = p_reservation_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no reservation %', p_reservation_id
            USING ERRCODE = 'raise_exception';
    END IF;

    IF p_actor = 'website' AND r.channel <> 'direct' THEN
        RAISE EXCEPTION
            'a website cancellation may only release a direct booking; reservation % is on %',
            p_reservation_id, r.channel USING ERRCODE = 'raise_exception';
    END IF;
    IF p_actor = 'website' AND p_external_ref IS NOT NULL
       AND r.external_ref IS DISTINCT FROM p_external_ref THEN
        RAISE EXCEPTION 'external reference does not match reservation %', p_reservation_id
            USING ERRCODE = 'raise_exception';
    END IF;

    IF r.status = 'cancelled' THEN
        -- Idempotent: a retried webhook must not fail, and must not claim to
        -- have released nights a second time.
        RETURN QUERY SELECT 0, r.cancelled_at;
        RETURN;
    END IF;
    IF r.status <> 'confirmed' THEN
        RAISE EXCEPTION 'reservation % is %, not confirmed; nothing to release',
            p_reservation_id, r.status USING ERRCODE = 'raise_exception';
    END IF;

    v_nights := upper(r.stay) - lower(r.stay);
    PERFORM set_config('vrc.cancellation_in_progress', p_reservation_id::text, true);
    UPDATE reservations
       SET status = 'cancelled', cancelled_at = v_now, updated_at = v_now
     WHERE id = p_reservation_id;
    UPDATE holds SET released_at = now()
     WHERE reservation_id = p_reservation_id AND released_at IS NULL;
    PERFORM set_config('vrc.cancellation_in_progress', '', true);

    INSERT INTO availability_audit (decision_id, at, actor, event, detail)
    VALUES (NULL, v_now, p_actor, 'cancelled',
            format('cancelled %s reservation %s (%s nights, %s) -- %s',
                   r.channel, p_reservation_id, v_nights, r.stay, p_reason));

    -- Releasing nights is a feed REDUCTION, so it is recorded for review
    -- rather than quietly republished.
    INSERT INTO conflicts (property_id, category, check_in, check_out, detail)
    VALUES (r.property_id, 'availability_discrepancy', r.check_in, r.check_out,
            format('direct booking cancelled, %s nights released -- reopening these '
                   'dates on a platform requires approval', v_nights));

    RETURN QUERY SELECT v_nights, v_now;
END;
$$;

-- ===========================================================================
-- Roles
-- ===========================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vrc_app') THEN
        CREATE ROLE vrc_app;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vrc_readonly') THEN
        CREATE ROLE vrc_readonly;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vrc_runtime') THEN
        CREATE ROLE vrc_runtime LOGIN INHERIT;
    END IF;
END
$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO vrc_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO vrc_app;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO vrc_readonly;
GRANT vrc_app TO vrc_runtime;
GRANT USAGE ON SCHEMA public TO vrc_runtime;
GRANT EXECUTE ON FUNCTION vrc_cancel_website_booking(bigint, text, text) TO vrc_app;

-- The audit trail is append-only for the running service. Rewriting history
-- needs a separate administrative credential the service does not hold.
REVOKE UPDATE, DELETE ON availability_audit FROM vrc_app;
-- Observations are facts: the service may tombstone them but never delete.
REVOKE DELETE ON events FROM vrc_app;
-- No DDL. CREATE is revoked explicitly rather than relying on the version
-- default, which changed in PostgreSQL 15.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM vrc_runtime;

-- ===========================================================================
-- Idempotency
-- ===========================================================================

-- A mutating API request carries a key derived from its own content. Recording
-- the key with the outcome is what lets a retried request return what the
-- first one did instead of creating a second decision.
--
-- The key alone is the primary key, so a concurrent duplicate loses the insert
-- race rather than both proceeding.
CREATE TABLE idempotency_keys (
    key             text PRIMARY KEY,
    route           text NOT NULL,
    publication_uid text,
    response_status bigint NOT NULL,
    created_at      double precision NOT NULL
);

GRANT SELECT, INSERT, UPDATE ON idempotency_keys TO vrc_app;
-- Never deleted: forgetting a key would make a late retry create a duplicate.
REVOKE DELETE ON idempotency_keys FROM vrc_app;

INSERT INTO schema_migrations (version) VALUES (11);

INSERT INTO app_settings (key, value) VALUES
    ('feed_publication_scope', 'approved_manual_blocks_only'),
    ('outbound_sync_enabled',  'false')
ON CONFLICT (key) DO NOTHING;

COMMIT;
