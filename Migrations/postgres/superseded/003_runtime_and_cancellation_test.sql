-- Tests for migration 003 — runtime role, four actor levels, and the
-- controlled website cancellation.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE TEMP TABLE results (name text, expected text, actual text, detail text);

CREATE OR REPLACE FUNCTION pg_temp.record(
    p_name text, p_expected text, p_sql text, p_detail text DEFAULT ''
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_actual text := 'ALLOW'; v_err text := '';
BEGIN
    BEGIN EXECUTE p_sql;
    EXCEPTION
        -- syntax_error is caught too so a mistake in a test's own SQL shows up
        -- as a failure rather than as a convincing-looking REFUSE.
        WHEN raise_exception OR insufficient_privilege THEN
            v_actual := 'REFUSE'; v_err := left(SQLERRM, 52);
    END;
    -- A case that did SET LOCAL ROLE leaves it set for the rest of the
    -- transaction, which would make the bookkeeping insert below fail as the
    -- restricted role. Reset before recording anything.
    RESET ROLE;
    INSERT INTO results VALUES (p_name, p_expected, v_actual,
        CASE WHEN p_detail <> '' THEN p_detail ELSE v_err END);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.booking(
    p_channel channel DEFAULT 'direct', OUT reservation uuid
) LANGUAGE plpgsql AS $$
DECLARE v_prop uuid; v_slug text := 'b-' || gen_random_uuid()::text;
BEGIN
    INSERT INTO properties (slug, name) VALUES (v_slug, v_slug) RETURNING id INTO v_prop;
    INSERT INTO reservations (property_id, channel, stay, status, external_ref)
        VALUES (v_prop, p_channel, '[2027-06-01,2027-06-08)', 'confirmed', 'ext-123')
        RETURNING id INTO reservation;
    INSERT INTO holds (property_id, channel, stay, expires_at, reservation_id)
        VALUES (v_prop, p_channel, '[2027-06-01,2027-06-08)',
                now() + interval '1 day', reservation);
END;
$$;

-- ------------------------------------------------- the four actor levels
DO $$
DECLARE r uuid;
BEGIN
    r := pg_temp.booking();
    PERFORM pg_temp.record('A1  importer cancels a confirmed reservation', 'REFUSE',
        format('SET LOCAL vrc.actor=''importer'';
                UPDATE reservations SET status=''cancelled'', cancelled_at=now() WHERE id=%L', r));

    r := pg_temp.booking();
    PERFORM pg_temp.record('A2  website writes status DIRECTLY (bypassing the function)', 'REFUSE',
        format('SET LOCAL vrc.actor=''website'';
                UPDATE reservations SET status=''cancelled'', cancelled_at=now() WHERE id=%L', r));

    r := pg_temp.booking();
    PERFORM pg_temp.record('A3  owner cancels directly', 'ALLOW',
        format('SET LOCAL vrc.actor=''owner'';
                UPDATE reservations SET status=''cancelled'', cancelled_at=now() WHERE id=%L', r));

    r := pg_temp.booking();
    PERFORM pg_temp.record('A4  admin cancels directly', 'ALLOW',
        format('SET LOCAL vrc.actor=''admin'';
                UPDATE reservations SET status=''cancelled'', cancelled_at=now() WHERE id=%L', r));

    r := pg_temp.booking();
    PERFORM pg_temp.record('A5  unrecognised actor degrades to importer', 'REFUSE',
        format('SET LOCAL vrc.actor=''wibble'';
                UPDATE reservations SET status=''cancelled'', cancelled_at=now() WHERE id=%L', r));

    r := pg_temp.booking();
    PERFORM pg_temp.record('A6  website shrinks a confirmed stay', 'REFUSE',
        format('SET LOCAL vrc.actor=''website'';
                UPDATE reservations SET stay=''[2027-06-01,2027-06-03)'' WHERE id=%L', r));
END $$;

-- --------------------------------------- the controlled cancellation path
DO $$
DECLARE r uuid; v_nights int; v_at timestamptz; v_audit int; v_conf int; v_holds int;
BEGIN
    r := pg_temp.booking();
    PERFORM set_config('vrc.actor', 'website', true);
    SELECT nights_released, cancelled_at INTO v_nights, v_at
      FROM vrc_cancel_website_booking(r, 'guest requested refund', 'ext-123');
    SELECT count(*) INTO v_audit FROM availability_audit WHERE detail LIKE '%' || r::text || '%';
    SELECT count(*) INTO v_conf  FROM conflicts WHERE detail LIKE '%nights released%';
    SELECT count(*) INTO v_holds FROM holds WHERE reservation_id = r AND released_at IS NULL;

    INSERT INTO results VALUES ('C1  releases the right number of nights', '7',
        v_nights::text, 'stay was 06-01 to 06-08');
    INSERT INTO results VALUES ('C2  reservation row is kept, not deleted', 'cancelled',
        (SELECT status::text FROM reservations WHERE id = r), 'history preserved');
    INSERT INTO results VALUES ('C3  writes an audit row naming the reason', '1',
        v_audit::text, (SELECT left(detail, 46) FROM availability_audit
                         WHERE detail LIKE '%' || r::text || '%' LIMIT 1));
    INSERT INTO results VALUES ('C4  records a conflict so dates are not republished', 'yes',
        CASE WHEN v_conf > 0 THEN 'yes' ELSE 'no' END, 'reduction needs approval');
    INSERT INTO results VALUES ('C5  releases the live hold', '0',
        v_holds::text, 'unreleased holds remaining');

    -- Retried webhook
    SELECT nights_released INTO v_nights
      FROM vrc_cancel_website_booking(r, 'guest requested refund', 'ext-123');
    INSERT INTO results VALUES ('C6  retry is idempotent, releases 0 more', '0',
        v_nights::text, 'no double release');
END $$;

DO $$
DECLARE r uuid;
BEGIN
    r := pg_temp.booking();
    PERFORM pg_temp.record('C7  cancellation with no reason', 'REFUSE',
        format('SET LOCAL vrc.actor=''website'';
                SELECT vrc_cancel_website_booking(%L, ''  '')', r));

    r := pg_temp.booking('airbnb');
    PERFORM pg_temp.record('C8  website cancels an AIRBNB reservation', 'REFUSE',
        format('SET LOCAL vrc.actor=''website'';
                SELECT vrc_cancel_website_booking(%L, ''try it'')', r));

    r := pg_temp.booking();
    PERFORM pg_temp.record('C9  website with a mismatched external ref', 'REFUSE',
        format('SET LOCAL vrc.actor=''website'';
                SELECT vrc_cancel_website_booking(%L, ''try it'', ''wrong-ref'')', r));

    r := pg_temp.booking();
    PERFORM pg_temp.record('C10 importer calls the cancellation function', 'REFUSE',
        format('SET LOCAL vrc.actor=''importer'';
                SELECT vrc_cancel_website_booking(%L, ''try it'')', r));

    PERFORM pg_temp.record('C11 cancelling a reservation that does not exist', 'REFUSE',
        format('SET LOCAL vrc.actor=''owner'';
                SELECT vrc_cancel_website_booking(%L, ''try it'')',
               gen_random_uuid()));
END $$;

-- ----------------------------------------------- the runtime role's limits
DO $$
BEGIN
    PERFORM pg_temp.record('R1  vrc_runtime creating a table (DDL)', 'REFUSE',
        'SET LOCAL ROLE vrc_runtime; CREATE TABLE should_not_exist (x int)');
    PERFORM pg_temp.record('R2  vrc_runtime rewriting the audit trail', 'REFUSE',
        'SET LOCAL ROLE vrc_runtime; UPDATE availability_audit SET detail = ''rewritten''');
    PERFORM pg_temp.record('R3  vrc_runtime deleting the audit trail', 'REFUSE',
        'SET LOCAL ROLE vrc_runtime; DELETE FROM availability_audit');
    PERFORM pg_temp.record('R4  vrc_runtime deleting source observations', 'REFUSE',
        'SET LOCAL ROLE vrc_runtime; DELETE FROM source_events');
    PERFORM pg_temp.record('R5  vrc_runtime reading reservations (must work)', 'ALLOW',
        'SET LOCAL ROLE vrc_runtime; SELECT 1 FROM reservations LIMIT 1');
    PERFORM pg_temp.record('R6  vrc_runtime appending an audit row (must work)', 'ALLOW',
        'SET LOCAL ROLE vrc_runtime; INSERT INTO availability_audit (actor, detail)
         VALUES (''owner'', ''appended by runtime'')');
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
    IF n > 0 THEN RAISE EXCEPTION '% test(s) failed', n; END IF;
END $$;
