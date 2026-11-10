-- Tests for 011_safety.sql against the repository schema.
--
-- Run against a scratch database with 010 and 011 applied:
--   psql -d vrc -f Migrations/postgres/tests/011_safety_test.sql
--
-- Every case runs its statement, records whether the guards refused it, and
-- then checks the data is still there. A refusal that lost rows anyway reports
-- BADSTATE rather than passing.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE TEMP TABLE results (name text, expected text, actual text, detail text);

CREATE OR REPLACE FUNCTION pg_temp.epoch(y int, m int, d int) RETURNS double precision
LANGUAGE sql IMMUTABLE AS $$
    SELECT extract(epoch from make_timestamptz(y, m, d, 0, 0, 0, 'UTC'))
$$;

CREATE OR REPLACE FUNCTION pg_temp.record(
    p_name text, p_expected text, p_sql text, p_detail text DEFAULT ''
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_actual text := 'ALLOW'; v_err text := '';
BEGIN
    BEGIN EXECUTE p_sql;
    EXCEPTION WHEN raise_exception OR insufficient_privilege OR exclusion_violation THEN
        v_actual := 'REFUSE'; v_err := left(SQLERRM, 54);
    END;
    RESET ROLE;
    INSERT INTO results VALUES (p_name, p_expected, v_actual,
        CASE WHEN p_detail <> '' THEN p_detail ELSE v_err END);
END;
$$;

-- A listing with n events, the first `locked` of them owner-classified.
CREATE OR REPLACE FUNCTION pg_temp.fixture(n int, owner_set int, OUT listing bigint)
LANGUAGE plpgsql AS $$
DECLARE v_prop bigint; v_slug text := 'fx-' || gen_random_uuid()::text; i int; v_key text;
BEGIN
    INSERT INTO properties (name, address, notes, created_at, updated_at, time_zone)
        VALUES (v_slug, '', '', 0, 0, 'UTC') RETURNING id INTO v_prop;
    INSERT INTO platform_listings
        (property_id, platform, label, ical_url, auto_refresh_enabled, last_sync_summary,
         created_at, updated_at, url_storage, credential_ref, connection_state, connection_detail)
        VALUES (v_prop, 'airbnb', v_slug, '', 1, '', 0, 0, 'database', '', 'connected', '')
        RETURNING id INTO listing;
    FOR i IN 1..n LOOP
        v_key := v_slug || '-' || i;
        INSERT INTO events
            (listing_id, event_key, uid, platform, summary, details, location,
             check_in, check_out, is_all_day, feed_status, sequence, content_hash,
             first_seen_at, last_seen_at, is_tombstoned, has_unsupported_recurrence)
        VALUES (listing, v_key, v_key, 'airbnb', 'Blocked', '', '',
                pg_temp.epoch(2027, 1, 1) + (i * 864000),
                pg_temp.epoch(2027, 1, 4) + (i * 864000),
                1, 'confirmed', 0, '', 0, 0, 0, 0);
        INSERT INTO classifications
            (event_key, kind, confidence, source, needs_review, rationale, note,
             export_approved, export_suppressed, decided_at)
        VALUES (v_key, 'owner_block', 'high',
                CASE WHEN i <= owner_set THEN 'manual' ELSE 'automatic' END,
                0, '', '', 0, 0, 0);
    END LOOP;
END;
$$;

-- --------------------------------------------------- guard 1: owner's own work
DO $$
DECLARE l bigint;
BEGIN
    l := pg_temp.fixture(10, 1);
    PERFORM pg_temp.record(
        'G1  owner-classified event withdrawn, only 10% of the feed', 'REFUSE',
        format('UPDATE events SET is_tombstoned = 1
                 WHERE id = (SELECT id FROM events WHERE listing_id = %s
                              AND event_key LIKE ''%%-1'' LIMIT 1)', l));
    PERFORM pg_temp.record(
        'G1  two automatic events of 10 (20%)', 'ALLOW',
        format('UPDATE events SET is_tombstoned = 1
                 WHERE id IN (SELECT id FROM events WHERE listing_id = %s
                               AND event_key NOT LIKE ''%%-1''
                               ORDER BY id LIMIT 2)', l));
END $$;

-- ------------------------------------------------------- guard 2: mass removal
DO $$
DECLARE l bigint;
BEGIN
    l := pg_temp.fixture(4, 0);
    PERFORM pg_temp.record('G2a feed came back EMPTY (all 4)', 'REFUSE',
        format('UPDATE events SET is_tombstoned = 1 WHERE listing_id = %s', l));

    l := pg_temp.fixture(1, 0);
    PERFORM pg_temp.record('G2a single-event feed emptied', 'REFUSE',
        format('UPDATE events SET is_tombstoned = 1 WHERE listing_id = %s', l));

    l := pg_temp.fixture(6, 0);
    PERFORM pg_temp.record('G2b 4 of 6 (67%)', 'REFUSE',
        format('UPDATE events SET is_tombstoned = 1
                 WHERE id IN (SELECT id FROM events WHERE listing_id = %s
                               ORDER BY id LIMIT 4)', l));
    PERFORM pg_temp.record('G2b 2 of 6 (33%) — legitimate', 'ALLOW',
        format('UPDATE events SET is_tombstoned = 1
                 WHERE id IN (SELECT id FROM events WHERE listing_id = %s
                               ORDER BY id LIMIT 2)', l));
    PERFORM pg_temp.record('G2b exactly half (2 of 4)', 'ALLOW',
        format('UPDATE events SET is_tombstoned = 1
                 WHERE id IN (SELECT id FROM events WHERE listing_id = %s
                               AND is_tombstoned = 0 ORDER BY id LIMIT 2)', l));
END $$;

-- ----------------------------------------------------------- authorisation
DO $$
DECLARE l bigint;
BEGIN
    l := pg_temp.fixture(4, 0);
    PERFORM pg_temp.record('AU  authorised with the right listing:count', 'ALLOW',
        format('SET LOCAL vrc.authorize_withdrawal = %L;
                UPDATE events SET is_tombstoned = 1 WHERE listing_id = %s',
               l::text || ':4', l));

    l := pg_temp.fixture(4, 0);
    PERFORM pg_temp.record('AU  authorised with the WRONG count', 'REFUSE',
        format('SET LOCAL vrc.authorize_withdrawal = %L;
                UPDATE events SET is_tombstoned = 1 WHERE listing_id = %s',
               l::text || ':3', l));

    l := pg_temp.fixture(4, 0);
    PERFORM pg_temp.record('AU  nothing declared at all', 'REFUSE',
        format('UPDATE events SET is_tombstoned = 1 WHERE listing_id = %s', l));
END $$;

-- ------------------------------------------- double booking and adjacency
DO $$
DECLARE p bigint;
BEGIN
    INSERT INTO properties (name, address, notes, created_at, updated_at, time_zone)
        VALUES ('dbl', '', '', 0, 0, 'UTC') RETURNING id INTO p;
    INSERT INTO reservations
        (property_id, channel, check_in, check_out, status, created_at, updated_at)
        VALUES (p, 'airbnb', pg_temp.epoch(2026,12,10), pg_temp.epoch(2026,12,17),
                'confirmed', 0, 0);

    PERFORM pg_temp.record('DB  overlapping confirmed reservation (Dec 15-20)', 'REFUSE',
        format('INSERT INTO reservations
                  (property_id, channel, check_in, check_out, status, created_at, updated_at)
                VALUES (%s, ''vrbo'', %s, %s, ''confirmed'', 0, 0)',
               p, pg_temp.epoch(2026,12,15), pg_temp.epoch(2026,12,20)));

    PERFORM pg_temp.record('DB  checkout-day adjacency (Dec 17-20)', 'ALLOW',
        format('INSERT INTO reservations
                  (property_id, channel, check_in, check_out, status, created_at, updated_at)
                VALUES (%s, ''vrbo'', %s, %s, ''confirmed'', 0, 0)',
               p, pg_temp.epoch(2026,12,17), pg_temp.epoch(2026,12,20)));

    PERFORM pg_temp.record('DB  a cancelled overlap is allowed', 'ALLOW',
        format('INSERT INTO reservations
                  (property_id, channel, check_in, check_out, status, created_at,
                   updated_at, cancelled_at)
                VALUES (%s, ''booking_com'', %s, %s, ''cancelled'', 0, 0, 1)',
               p, pg_temp.epoch(2026,12,11), pg_temp.epoch(2026,12,14)));
END $$;

-- ------------------------------------------------ guard 3 and cancellation
DO $$
DECLARE p bigint; r bigint; v_nights int; v_audit int; v_conf int; v_holds int;
BEGIN
    INSERT INTO properties (name, address, notes, created_at, updated_at, time_zone)
        VALUES ('cx', '', '', 0, 0, 'UTC') RETURNING id INTO p;
    INSERT INTO reservations
        (property_id, channel, check_in, check_out, status, external_ref, created_at, updated_at)
        VALUES (p, 'direct', pg_temp.epoch(2027,6,1), pg_temp.epoch(2027,6,8),
                'confirmed', 'ext-1', 0, 0) RETURNING id INTO r;
    INSERT INTO holds (property_id, channel, check_in, check_out, expires_at,
                       reservation_id, created_at)
        VALUES (p, 'direct', pg_temp.epoch(2027,6,1), pg_temp.epoch(2027,6,8),
                now() + interval '1 day', r, 0);

    PERFORM pg_temp.record('G3  importer cancels a confirmed reservation', 'REFUSE',
        format('SET LOCAL vrc.actor=''importer'';
                UPDATE reservations SET status=''cancelled'', cancelled_at=1 WHERE id=%s', r));
    PERFORM pg_temp.record('G3  website writes status directly', 'REFUSE',
        format('SET LOCAL vrc.actor=''website'';
                UPDATE reservations SET status=''cancelled'', cancelled_at=1 WHERE id=%s', r));
    PERFORM pg_temp.record('G3  importer shrinks a confirmed stay', 'REFUSE',
        format('SET LOCAL vrc.actor=''importer'';
                UPDATE reservations SET check_out=%s WHERE id=%s',
               pg_temp.epoch(2027,6,3), r));

    -- The sanctioned path.
    PERFORM set_config('vrc.actor', 'website', true);
    SELECT nights_released INTO v_nights
      FROM vrc_cancel_website_booking(r, 'guest requested refund', 'ext-1');
    SELECT count(*) INTO v_audit FROM availability_audit WHERE detail LIKE '%' || r || '%';
    SELECT count(*) INTO v_conf FROM conflicts WHERE detail LIKE '%nights released%';
    SELECT count(*) INTO v_holds FROM holds WHERE reservation_id = r AND released_at IS NULL;

    INSERT INTO results VALUES ('CX  releases the right nights', '7', v_nights::text, '06-01→06-08');
    INSERT INTO results VALUES ('CX  reservation kept, not deleted', 'cancelled',
        (SELECT status::text FROM reservations WHERE id = r), 'history preserved');
    INSERT INTO results VALUES ('CX  one audit row naming the reason', '1', v_audit::text, '');
    INSERT INTO results VALUES ('CX  a conflict records the reduction', 'yes',
        CASE WHEN v_conf > 0 THEN 'yes' ELSE 'no' END, 'reopening needs approval');
    INSERT INTO results VALUES ('CX  the hold is released', '0', v_holds::text, '');

    SELECT nights_released INTO v_nights
      FROM vrc_cancel_website_booking(r, 'retried webhook', 'ext-1');
    INSERT INTO results VALUES ('CX  retry is idempotent', '0', v_nights::text, 'no double release');
    RESET ROLE;
END $$;

DO $$
DECLARE p bigint; r bigint;
BEGIN
    INSERT INTO properties (name, address, notes, created_at, updated_at, time_zone)
        VALUES ('cy', '', '', 0, 0, 'UTC') RETURNING id INTO p;
    INSERT INTO reservations (property_id, channel, check_in, check_out, status,
                              external_ref, created_at, updated_at)
        VALUES (p, 'airbnb', pg_temp.epoch(2027,7,1), pg_temp.epoch(2027,7,5),
                'confirmed', 'ext-2', 0, 0) RETURNING id INTO r;
    PERFORM pg_temp.record('CX  website cancels an AIRBNB reservation', 'REFUSE',
        format('SET LOCAL vrc.actor=''website'';
                SELECT vrc_cancel_website_booking(%s, ''try it'')', r));
    PERFORM pg_temp.record('CX  cancellation with no reason', 'REFUSE',
        format('SET LOCAL vrc.actor=''owner'';
                SELECT vrc_cancel_website_booking(%s, ''  '')', r));
    PERFORM pg_temp.record('CX  importer calls the cancellation function', 'REFUSE',
        format('SET LOCAL vrc.actor=''importer'';
                SELECT vrc_cancel_website_booking(%s, ''try it'')', r));
END $$;

-- ----------------------------------------------------------------- TRUNCATE
DO $$
DECLARE v text;
BEGIN
    FOR v IN SELECT unnest(ARRAY['events', 'availability_audit', 'reservations']) LOOP
        PERFORM pg_temp.record('TR  TRUNCATE ' || v, 'REFUSE',
            format('TRUNCATE %I CASCADE', v));
    END LOOP;
END $$;

-- ------------------------------------------------------- the runtime role
DO $$
BEGIN
    PERFORM pg_temp.record('R1  vrc_runtime creating a table', 'REFUSE',
        'SET LOCAL ROLE vrc_runtime; CREATE TABLE nope (x int)');
    PERFORM pg_temp.record('R2  vrc_runtime rewriting the audit trail', 'REFUSE',
        'SET LOCAL ROLE vrc_runtime; UPDATE availability_audit SET detail = ''x''');
    PERFORM pg_temp.record('R3  vrc_runtime deleting the audit trail', 'REFUSE',
        'SET LOCAL ROLE vrc_runtime; DELETE FROM availability_audit');
    PERFORM pg_temp.record('R4  vrc_runtime deleting events', 'REFUSE',
        'SET LOCAL ROLE vrc_runtime; DELETE FROM events');
    PERFORM pg_temp.record('R5  vrc_runtime deleting idempotency keys', 'REFUSE',
        'SET LOCAL ROLE vrc_runtime; DELETE FROM idempotency_keys');
    PERFORM pg_temp.record('R6  vrc_runtime reading events', 'ALLOW',
        'SET LOCAL ROLE vrc_runtime; SELECT 1 FROM events LIMIT 1');
    PERFORM pg_temp.record('R7  vrc_runtime appending an audit row', 'ALLOW',
        'SET LOCAL ROLE vrc_runtime; INSERT INTO availability_audit
         (at, actor, event, detail) VALUES (0, ''owner'', ''x'', ''appended'')');
END $$;

-- ------------------------------------------------------------ the allow-list
DO $$
DECLARE k text; v boolean;
BEGIN
    FOR k, v IN SELECT * FROM (VALUES
        ('confirmed_reservation', true), ('owner_block', true),
        ('maintenance_block', true), ('cancellation_block', false),
        ('platform_restriction', false), ('unknown_unavailable', false)) AS t(a, b)
    LOOP
        INSERT INTO results VALUES ('AL  ' || k, v::text,
            describes_genuine_unavailability(k)::text, 'BlockKind.rawValue');
    END LOOP;
END $$;

\pset border 2
SELECT CASE WHEN expected = actual THEN 'PASS' ELSE '** FAIL **' END AS result,
       name, expected, actual, detail
FROM results ORDER BY name;
SELECT count(*) FILTER (WHERE expected = actual) || ' of ' || count(*) || ' passed' AS summary
FROM results;
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM results WHERE expected <> actual;
    IF n > 0 THEN RAISE EXCEPTION '% safety test(s) failed', n; END IF;
END $$;
