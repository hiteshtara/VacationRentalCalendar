-- VacationRentalCalendar — migration 002
-- Mass-withdrawal protection (Phase 2 §3.4)
--
-- DESIGN REVIEW ONLY. Not applied to any cloud database.
--
-- A feed that fails, goes stale, or comes back truncated must never cause
-- dates to reopen. The application already refuses to withdraw events on a
-- failed fetch, and FeedPublicationSafety already requires approval for
-- removals. This migration puts the same rule *below* the application, so a
-- coding mistake in a future importer cannot reopen inventory either.
--
-- Three independent guards, each refusing by default:
--
--   1. An owner's classification can never be withdrawn by an importer.
--   2. A withdrawal of every live event, or of more than half, is refused.
--   3. A confirmed reservation can never leave 'confirmed' on an import.
--
-- Each is bypassable only by a deliberate, per-transaction declaration that
-- names what is being authorised. An importer never sets one, so a bug cannot
-- stumble past these; only code written to ask can.

BEGIN;

-- ===========================================================================
-- Who is acting, and what have they authorised
-- ===========================================================================

-- Set by the application as `SET LOCAL vrc.actor = 'importer'` (or 'owner',
-- 'sweeper', 'publisher'). Defaults to 'importer' — the *least* trusted value —
-- so code that forgets to declare itself gets the strictest treatment rather
-- than the weakest.
CREATE FUNCTION vrc_current_actor() RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT coalesce(nullif(current_setting('vrc.actor', true), ''), 'importer')
$$;

-- An authorisation must name the listing AND the exact number of events, as
-- `SET LOCAL vrc.authorize_withdrawal = '<listing_uuid>:<count>'`. Naming the
-- count means an authorisation obtained for a 3-event withdrawal cannot
-- silently cover a 300-event one.
CREATE FUNCTION vrc_withdrawal_authorized(p_listing uuid, p_count bigint)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT coalesce(current_setting('vrc.authorize_withdrawal', true), '')
         = p_listing::text || ':' || p_count::text
$$;

COMMENT ON FUNCTION vrc_withdrawal_authorized(uuid, bigint) IS
    'True only when the current transaction explicitly authorised withdrawing '
    'exactly this many events from exactly this listing. Owner-approved '
    'removals set it; importers never do.';

-- ===========================================================================
-- Guard 1 and 2 — withdrawal of source events
-- ===========================================================================

CREATE FUNCTION vrc_guard_withdrawal() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    r               record;
    v_live_after    bigint;
    v_live_before   bigint;
    v_locked        bigint;
    v_actor         text := vrc_current_actor();
BEGIN
    FOR r IN
        SELECT n.listing_id AS listing_id, count(*) AS withdrawn
          FROM new_rows n
          JOIN old_rows o ON o.id = n.id
         WHERE o.withdrawn_at IS NULL
           AND n.withdrawn_at IS NOT NULL
         GROUP BY n.listing_id
    LOOP
        -- Guard 1: an owner's own decision is never collateral damage of an
        -- import. This is what preserves cancellation restrictions, owner
        -- blocks, maintenance blocks and platform restrictions — they are
        -- precisely the events the owner has classified.
        SELECT count(*) INTO v_locked
          FROM new_rows n
          JOIN old_rows o ON o.id = n.id
          JOIN classifications c ON c.source_event_id = n.id
         WHERE n.listing_id = r.listing_id
           AND o.withdrawn_at IS NULL
           AND n.withdrawn_at IS NOT NULL
           AND c.locked;

        IF v_locked > 0 AND NOT vrc_withdrawal_authorized(r.listing_id, r.withdrawn) THEN
            RAISE EXCEPTION
                'refusing to withdraw % event(s) carrying your own classification on listing % '
                '(actor %). A feed must not retract a decision you made. Authorise explicitly '
                'if this is intended.',
                v_locked, r.listing_id, v_actor
                USING ERRCODE = 'raise_exception',
                      HINT = 'SET LOCAL vrc.authorize_withdrawal = ''<listing>:<count>''';
        END IF;

        SELECT count(*) INTO v_live_after
          FROM source_events
         WHERE listing_id = r.listing_id AND withdrawn_at IS NULL;

        v_live_before := v_live_after + r.withdrawn;

        -- Guard 2a: the feed came back empty. Always refused — this is the
        -- exact shape of a revoked token, an HTML error page served with a 200,
        -- or a platform maintenance window.
        IF v_live_after = 0 AND v_live_before > 0
           AND NOT vrc_withdrawal_authorized(r.listing_id, r.withdrawn) THEN
            RAISE EXCEPTION
                'refusing to withdraw ALL % live event(s) on listing % (actor %). '
                'An empty feed is not evidence that dates are free.',
                v_live_before, r.listing_id, v_actor
                USING ERRCODE = 'raise_exception',
                      HINT = 'SET LOCAL vrc.authorize_withdrawal = ''<listing>:<count>''';
        END IF;

        -- Guard 2b: more than half the listing vanished in one statement.
        IF r.withdrawn * 2 > v_live_before
           AND NOT vrc_withdrawal_authorized(r.listing_id, r.withdrawn) THEN
            RAISE EXCEPTION
                'refusing to withdraw % of % live event(s) on listing % (actor %) — '
                'more than half. A feed this much smaller is treated as incomplete, '
                'not as dates being freed.',
                r.withdrawn, v_live_before, r.listing_id, v_actor
                USING ERRCODE = 'raise_exception',
                      HINT = 'SET LOCAL vrc.authorize_withdrawal = ''<listing>:<count>''';
        END IF;
    END LOOP;

    RETURN NULL;
END;
$$;

CREATE TRIGGER guard_withdrawal
    AFTER UPDATE ON source_events
    REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION vrc_guard_withdrawal();

-- `DELETE` is already revoked for vrc_app, but TRUNCATE bypasses both row
-- triggers and privileges on the rows themselves, so it is refused outright.
CREATE FUNCTION vrc_reject_truncate() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION
        'TRUNCATE is not permitted on %. Source observations are append-only; '
        'withdraw events individually so the guards can see it.', TG_TABLE_NAME
        USING ERRCODE = 'raise_exception';
END;
$$;

CREATE TRIGGER reject_truncate BEFORE TRUNCATE ON source_events
    FOR EACH STATEMENT EXECUTE FUNCTION vrc_reject_truncate();
CREATE TRIGGER reject_truncate_audit BEFORE TRUNCATE ON availability_audit
    FOR EACH STATEMENT EXECUTE FUNCTION vrc_reject_truncate();
CREATE TRIGGER reject_truncate_reservations BEFORE TRUNCATE ON reservations
    FOR EACH STATEMENT EXECUTE FUNCTION vrc_reject_truncate();

-- ===========================================================================
-- Guard 3 — a confirmed reservation never leaves 'confirmed' on an import
-- ===========================================================================

-- "Never reopen confirmed bookings." A cancellation is a real event and must
-- remain possible, but it is an owner action or a verified platform
-- cancellation — never an inference drawn from a feed that stopped mentioning
-- a booking.
CREATE FUNCTION vrc_protect_confirmed_reservation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status = 'confirmed' AND NEW.status <> 'confirmed'
       AND vrc_current_actor() = 'importer' THEN
        RAISE EXCEPTION
            'refusing to move reservation % out of confirmed (to %) on an import. '
            'A feed omitting a booking is not a cancellation.',
            OLD.id, NEW.status
            USING ERRCODE = 'raise_exception',
                  HINT = 'Cancellation requires an owner action: SET LOCAL vrc.actor = ''owner''';
    END IF;

    -- Shrinking a confirmed stay frees nights just as surely as cancelling it.
    IF OLD.status = 'confirmed' AND NEW.status = 'confirmed'
       AND NOT (NEW.stay @> OLD.stay)
       AND vrc_current_actor() = 'importer' THEN
        RAISE EXCEPTION
            'refusing to shrink confirmed reservation % on an import (% -> %).',
            OLD.id, OLD.stay, NEW.stay
            USING ERRCODE = 'raise_exception',
                  HINT = 'Shortening a confirmed stay requires an owner action';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER protect_confirmed_reservation
    BEFORE UPDATE ON reservations
    FOR EACH ROW EXECUTE FUNCTION vrc_protect_confirmed_reservation();

INSERT INTO schema_migrations (version) VALUES (2);

COMMIT;
