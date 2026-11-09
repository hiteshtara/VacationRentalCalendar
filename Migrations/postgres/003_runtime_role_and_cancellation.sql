-- VacationRentalCalendar — migration 003
-- Restricted runtime role, four actor levels, and the controlled website
-- cancellation transaction.
--
-- DESIGN REVIEW ONLY. Not applied to any cloud database.
--
-- Migration 001 created vrc_app and vrc_readonly as privilege holders with no
-- login. This adds the login the Lambdas actually use, so nothing ever
-- connects as the Aurora master account.

BEGIN;

-- ===========================================================================
-- The runtime login
-- ===========================================================================

-- Password is set out of band, after the cluster exists, and stored in the
-- vrc/database/runtime secret. It is deliberately absent here: a password in
-- a migration is a password in Git.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vrc_runtime') THEN
        CREATE ROLE vrc_runtime LOGIN INHERIT;
    END IF;
END
$$;

GRANT vrc_app TO vrc_runtime;
GRANT USAGE ON SCHEMA public TO vrc_runtime;

-- What the runtime login must NOT be able to do, stated as privileges rather
-- than as a convention:
--
--   * no DDL              -- cannot create, alter or drop anything
--   * no audit rewriting  -- inherited from vrc_app's revoked UPDATE/DELETE
--   * no source deletion  -- same
--   * no role management  -- NOCREATEROLE, NOSUPERUSER by default
--
-- CREATE on the schema is revoked explicitly because PUBLIC holds it by
-- default on PostgreSQL versions before 15, and relying on the version
-- default is exactly the kind of assumption that stops being true.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM vrc_runtime;
REVOKE ALL ON DATABASE vrc FROM PUBLIC;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO vrc_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO vrc_app;

-- ===========================================================================
-- Four actor levels
-- ===========================================================================

-- Migration 002 distinguished 'importer' from everything else. The four levels
-- the system actually has differ in what they are allowed to do to a confirmed
-- reservation, which is the only thing that can lose money:
--
--   importer  untrusted external calendar content. May add observations.
--             May never withdraw an owner's classification, empty a feed, or
--             touch a confirmed reservation.
--   owner     an authenticated change made in the Mac application. May
--             cancel, may shorten, may authorise a mass withdrawal.
--   website   an authorised direct-booking cancellation from
--             bostonfurnishedstays.com. May release ONLY a reservation it
--             owns, and only through vrc_cancel_website_booking below.
--   admin     recovery. May do what owner may, and is always audited.
CREATE FUNCTION vrc_actor_is_valid(a text) RETURNS boolean
IMMUTABLE LANGUAGE sql AS $$
    SELECT a IN ('importer', 'owner', 'website', 'admin')
$$;

-- An unrecognised actor is treated as 'importer' -- the least privileged --
-- rather than rejected, so a typo degrades safely instead of failing open.
CREATE OR REPLACE FUNCTION vrc_current_actor() RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN vrc_actor_is_valid(coalesce(nullif(current_setting('vrc.actor', true), ''), 'importer'))
        THEN coalesce(nullif(current_setting('vrc.actor', true), ''), 'importer')
        ELSE 'importer'
    END
$$;

-- Guard 3 from migration 002 widened to the four levels. 'website' is added to
-- the set that may move a reservation out of confirmed, but ONLY via the
-- function below, which sets a one-shot marker. A website actor acting
-- directly is refused.
CREATE OR REPLACE FUNCTION vrc_protect_confirmed_reservation() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_actor text := vrc_current_actor();
    v_sanctioned boolean := coalesce(
        current_setting('vrc.cancellation_in_progress', true) = NEW.id::text, false);
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
                'which records the reason and the audit row. Direct status writes '
                'are refused for reservation %.', OLD.id
                USING ERRCODE = 'raise_exception';
        END IF;
    END IF;

    IF OLD.status = 'confirmed' AND NEW.status = 'confirmed'
       AND NOT (NEW.stay @> OLD.stay) AND v_actor IN ('importer', 'website') THEN
        RAISE EXCEPTION
            'refusing to shrink confirmed reservation % as %s (% -> %).',
            OLD.id, v_actor, OLD.stay, NEW.stay
            USING ERRCODE = 'raise_exception';
    END IF;

    RETURN NEW;
END;
$$;

-- ===========================================================================
-- The controlled website cancellation
-- ===========================================================================

-- One transaction that releases the availability, records why, and leaves the
-- audit history intact. Nothing is deleted: the reservation row stays,
-- cancelled, so the booking's history survives the release of its dates.
--
-- Returns the number of nights released, so the caller can report something
-- true rather than assuming.
-- The actor is taken from the session (`SET LOCAL vrc.actor`), never from an
-- argument. An earlier revision took it as a parameter, which was wrong twice
-- over: the trigger read the session while the function read the argument, so
-- the sanctioned path refused itself; and an importer could have elevated
-- simply by passing 'owner'. One source of truth.
CREATE FUNCTION vrc_cancel_website_booking(
    p_reservation_id uuid,
    p_reason         text,
    p_external_ref   text DEFAULT NULL
) RETURNS TABLE (nights_released int, cancelled_at timestamptz)
LANGUAGE plpgsql AS $$
DECLARE
    r            reservations;
    v_nights     int;
    v_now        timestamptz := now();
    p_actor      text := vrc_current_actor();
BEGIN
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'a cancellation reason is required'
            USING ERRCODE = 'raise_exception';
    END IF;
    IF p_actor NOT IN ('website', 'owner', 'admin') THEN
        RAISE EXCEPTION
            'actor %s may not cancel a reservation. An import must never '
            'conclude that a booking was cancelled.', p_actor
            USING ERRCODE = 'raise_exception';
    END IF;

    -- FOR UPDATE, so two cancellations of the same booking serialise rather
    -- than both reporting success.
    SELECT * INTO r FROM reservations WHERE id = p_reservation_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no reservation %', p_reservation_id
            USING ERRCODE = 'raise_exception';
    END IF;

    -- A website actor may only cancel a website booking. It must not be able
    -- to release an Airbnb or Vrbo reservation.
    IF p_actor = 'website' AND r.channel <> 'direct' THEN
        RAISE EXCEPTION
            'a website cancellation may only release a direct booking; '
            'reservation % is on %', p_reservation_id, r.channel
            USING ERRCODE = 'raise_exception';
    END IF;
    IF p_actor = 'website' AND p_external_ref IS NOT NULL
       AND r.external_ref IS DISTINCT FROM p_external_ref THEN
        RAISE EXCEPTION
            'external reference does not match reservation %', p_reservation_id
            USING ERRCODE = 'raise_exception';
    END IF;

    IF r.status = 'cancelled' THEN
        -- Idempotent: a retried webhook must not fail, and must not pretend to
        -- have released nights a second time.
        RETURN QUERY SELECT 0, r.cancelled_at;
        RETURN;
    END IF;
    IF r.status <> 'confirmed' THEN
        RAISE EXCEPTION
            'reservation % is %, not confirmed; nothing to release',
            p_reservation_id, r.status
            USING ERRCODE = 'raise_exception';
    END IF;

    v_nights := upper(r.stay) - lower(r.stay);

    -- The one-shot marker the trigger checks. Scoped to this transaction and
    -- to this reservation id, so it cannot sanction any other write.
    PERFORM set_config('vrc.cancellation_in_progress', p_reservation_id::text, true);

    UPDATE reservations
       SET status = 'cancelled', cancelled_at = v_now, updated_at = v_now
     WHERE id = p_reservation_id;

    -- Release any live hold the booking still owns.
    UPDATE holds SET released_at = v_now
     WHERE reservation_id = p_reservation_id AND released_at IS NULL;

    PERFORM set_config('vrc.cancellation_in_progress', '', true);

    -- Append-only: the audit row is the record that this happened and why.
    INSERT INTO availability_audit (decision_id, at, actor, from_status, to_status, detail)
    VALUES (NULL, v_now, p_actor, NULL, NULL,
            format('cancelled %s reservation %s (%s nights, %s) — %s',
                   r.channel, p_reservation_id, v_nights, r.stay, p_reason));

    -- Releasing nights is a feed REDUCTION. It must never reach a platform
    -- without approval, so it is recorded as a conflict for review rather than
    -- quietly republished.
    INSERT INTO conflicts (property_id, category, stay, detail)
    VALUES (r.property_id, 'availability_discrepancy', r.stay,
            format('direct booking cancelled, %s nights released — '
                   'reopening these dates on a platform requires approval', v_nights));

    RETURN QUERY SELECT v_nights, v_now;
END;
$$;

COMMENT ON FUNCTION vrc_cancel_website_booking(uuid, text, text) IS
    'The only path by which a website cancellation may release a confirmed '
    'reservation. Requires a reason, serialises on the row, is idempotent on '
    'retry, releases the hold, writes the audit row, and records a conflict so '
    'the freed nights are not republished without approval.';

GRANT EXECUTE ON FUNCTION vrc_cancel_website_booking(uuid, text, text) TO vrc_app;

INSERT INTO schema_migrations (version) VALUES (3);

COMMIT;
