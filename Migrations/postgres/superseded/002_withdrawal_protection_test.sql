-- Tests for migration 002 — mass-withdrawal protection.
--
-- Run against a scratch database that has had 001 and 002 applied:
--   psql -d vrc -f Migrations/postgres/tests/002_withdrawal_protection_test.sql
--
-- Each case runs in a savepoint and is rolled back, so the script is
-- idempotent and leaves nothing behind. Every case asserts the OUTCOME and,
-- where a refusal is expected, also asserts the data is still there.

\set ON_ERROR_STOP on
\timing off
SET client_min_messages = warning;

CREATE TEMP TABLE results (name text, expected text, actual text, detail text);

CREATE OR REPLACE FUNCTION pg_temp.fixture(
    n_events int, n_locked int, OUT listing uuid
) LANGUAGE plpgsql AS $$
DECLARE
    v_prop uuid;
    v_slug text := 'fx-' || gen_random_uuid()::text;
    v_event bigint;
    i int;
BEGIN
    INSERT INTO properties (slug, name) VALUES (v_slug, v_slug) RETURNING id INTO v_prop;
    INSERT INTO platform_listings (property_id, channel, credential_ref)
        VALUES (v_prop, 'vrbo', 'ref/' || v_slug) RETURNING id INTO listing;
    FOR i IN 1..n_events LOOP
        INSERT INTO source_events (listing_id, event_key, stay)
            VALUES (listing, 'e' || i,
                    daterange(DATE '2027-01-01' + (i * 10), DATE '2027-01-05' + (i * 10)))
            RETURNING id INTO v_event;
        IF i <= n_locked THEN
            INSERT INTO classifications (source_event_id, kind, set_by, locked)
                VALUES (v_event, 'owner_block', 'owner', true);
        END IF;
    END LOOP;
END;
$$;

-- Runs one statement, records whether the guards refused it, and checks how
-- many live events remain afterwards.
CREATE OR REPLACE FUNCTION pg_temp.check_case(
    p_name text, p_expected text, p_sql text, p_listing uuid, p_expect_live int
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_actual text := 'ALLOW';
    v_detail text := '';
    v_live   int;
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN raise_exception THEN
        v_actual := 'REFUSE';
        v_detail := left(SQLERRM, 58);
    END;

    SELECT count(*) INTO v_live
      FROM source_events WHERE listing_id = p_listing AND withdrawn_at IS NULL;

    IF v_live <> p_expect_live THEN
        v_detail := format('live=%s expected=%s', v_live, p_expect_live);
        v_actual := v_actual || '/BADSTATE';
    END IF;

    INSERT INTO results VALUES (p_name, p_expected, v_actual, v_detail);
END;
$$;

-- ---------------------------------------------------------------- guard 1
DO $$
DECLARE l uuid;
BEGIN
    l := pg_temp.fixture(6, 2);
    PERFORM pg_temp.check_case(
        'G1  owner-classified event withdrawn by importer', 'REFUSE',
        format('UPDATE source_events SET withdrawn_at = now()
                 WHERE id = (SELECT id FROM source_events
                              WHERE listing_id = %L ORDER BY id LIMIT 1)', l),
        l, 6);
END $$;

DO $$
DECLARE l uuid;
BEGIN
    l := pg_temp.fixture(10, 1);
    PERFORM pg_temp.check_case(
        'G1  locked event, only 10% of the feed', 'REFUSE',
        format('UPDATE source_events SET withdrawn_at = now()
                 WHERE id = (SELECT id FROM source_events
                              WHERE listing_id = %L ORDER BY id LIMIT 1)', l),
        l, 10);
    PERFORM pg_temp.check_case(
        'G1  two UNLOCKED events of 10 (20%)', 'ALLOW',
        format('UPDATE source_events SET withdrawn_at = now()
                 WHERE id IN (SELECT id FROM source_events
                               WHERE listing_id = %L ORDER BY id OFFSET 1 LIMIT 2)', l),
        l, 8);
END $$;

-- ---------------------------------------------------------------- guard 2a
DO $$
DECLARE l uuid;
BEGIN
    l := pg_temp.fixture(4, 0);
    PERFORM pg_temp.check_case(
        'G2a feed came back EMPTY (all 4 withdrawn)', 'REFUSE',
        format('UPDATE source_events SET withdrawn_at = now() WHERE listing_id = %L', l),
        l, 4);
END $$;

DO $$
DECLARE l uuid;
BEGIN
    l := pg_temp.fixture(1, 0);
    PERFORM pg_temp.check_case(
        'G2a single-event feed emptied', 'REFUSE',
        format('UPDATE source_events SET withdrawn_at = now() WHERE listing_id = %L', l),
        l, 1);
END $$;

-- ---------------------------------------------------------------- guard 2b
DO $$
DECLARE l uuid;
BEGIN
    l := pg_temp.fixture(6, 0);
    PERFORM pg_temp.check_case(
        'G2b 4 of 6 withdrawn (67%)', 'REFUSE',
        format('UPDATE source_events SET withdrawn_at = now()
                 WHERE id IN (SELECT id FROM source_events
                               WHERE listing_id = %L ORDER BY id LIMIT 4)', l),
        l, 6);
    PERFORM pg_temp.check_case(
        'G2b 2 of 6 withdrawn (33%) — legitimate', 'ALLOW',
        format('UPDATE source_events SET withdrawn_at = now()
                 WHERE id IN (SELECT id FROM source_events
                               WHERE listing_id = %L ORDER BY id LIMIT 2)', l),
        l, 4);
    PERFORM pg_temp.check_case(
        'G2b exactly half (2 of 4) — allowed', 'ALLOW',
        format('UPDATE source_events SET withdrawn_at = now()
                 WHERE id IN (SELECT id FROM source_events
                               WHERE listing_id = %L AND withdrawn_at IS NULL
                               ORDER BY id LIMIT 2)', l),
        l, 2);
END $$;

-- ------------------------------------------------------- authorisation
DO $$
DECLARE l uuid;
BEGIN
    l := pg_temp.fixture(4, 0);
    PERFORM pg_temp.check_case(
        'AU  authorised with correct listing:count', 'ALLOW',
        format('SET LOCAL vrc.authorize_withdrawal = %L;
                UPDATE source_events SET withdrawn_at = now() WHERE listing_id = %L',
               l::text || ':4', l),
        l, 0);
END $$;

DO $$
DECLARE l uuid;
BEGIN
    l := pg_temp.fixture(4, 0);
    PERFORM pg_temp.check_case(
        'AU  authorised with WRONG count (3, actually 4)', 'REFUSE',
        format('SET LOCAL vrc.authorize_withdrawal = %L;
                UPDATE source_events SET withdrawn_at = now() WHERE listing_id = %L',
               l::text || ':3', l),
        l, 4);
END $$;

DO $$
DECLARE l uuid; other uuid;
BEGIN
    l := pg_temp.fixture(4, 0);
    other := pg_temp.fixture(1, 0);
    PERFORM pg_temp.check_case(
        'AU  authorisation naming a DIFFERENT listing', 'REFUSE',
        format('SET LOCAL vrc.authorize_withdrawal = %L;
                UPDATE source_events SET withdrawn_at = now() WHERE listing_id = %L',
               other::text || ':4', l),
        l, 4);
END $$;

DO $$
DECLARE l uuid;
BEGIN
    l := pg_temp.fixture(4, 0);
    PERFORM pg_temp.check_case(
        'AU  actor=owner but no authorisation', 'REFUSE',
        format('SET LOCAL vrc.actor = ''owner'';
                UPDATE source_events SET withdrawn_at = now() WHERE listing_id = %L', l),
        l, 4);
END $$;

DO $$
DECLARE l uuid;
BEGIN
    l := pg_temp.fixture(4, 0);
    PERFORM pg_temp.check_case(
        'AU  nothing declared at all (default actor)', 'REFUSE',
        format('UPDATE source_events SET withdrawn_at = now() WHERE listing_id = %L', l),
        l, 4);
END $$;

-- ------------------------------------------------------------- guard 3
DO $$
DECLARE p uuid; r uuid; v_actual text := 'ALLOW'; v_status text;
BEGIN
    INSERT INTO properties (slug, name) VALUES ('g3-' || gen_random_uuid(), 'g3')
        RETURNING id INTO p;
    INSERT INTO reservations (property_id, channel, stay, status)
        VALUES (p, 'airbnb', '[2027-06-01,2027-06-08)', 'confirmed') RETURNING id INTO r;

    BEGIN
        UPDATE reservations SET status = 'cancelled', cancelled_at = now() WHERE id = r;
    EXCEPTION WHEN raise_exception THEN v_actual := 'REFUSE';
    END;
    SELECT status INTO v_status FROM reservations WHERE id = r;
    INSERT INTO results VALUES ('G3  importer cancels a CONFIRMED reservation', 'REFUSE',
        v_actual, 'status is still ' || v_status);

    v_actual := 'ALLOW';
    BEGIN
        UPDATE reservations SET stay = '[2027-06-01,2027-06-03)' WHERE id = r;
    EXCEPTION WHEN raise_exception THEN v_actual := 'REFUSE';
    END;
    INSERT INTO results VALUES ('G3  importer SHRINKS a confirmed stay', 'REFUSE',
        v_actual, (SELECT stay::text FROM reservations WHERE id = r));

    v_actual := 'ALLOW';
    BEGIN
        SET LOCAL vrc.actor = 'owner';
        UPDATE reservations SET status = 'cancelled', cancelled_at = now() WHERE id = r;
    EXCEPTION WHEN raise_exception THEN v_actual := 'REFUSE';
    END;
    SELECT status INTO v_status FROM reservations WHERE id = r;
    INSERT INTO results VALUES ('G3  OWNER cancels a confirmed reservation', 'ALLOW',
        v_actual, 'status is now ' || v_status);
END $$;

-- ------------------------------------------------------------- truncate
DO $$
DECLARE v text;
BEGIN
    FOR v IN SELECT unnest(ARRAY['source_events', 'availability_audit', 'reservations']) LOOP
        DECLARE v_actual text := 'ALLOW';
        BEGIN
            BEGIN
                EXECUTE format('TRUNCATE %I CASCADE', v);
            EXCEPTION WHEN raise_exception THEN v_actual := 'REFUSE';
            END;
            INSERT INTO results VALUES ('TR  TRUNCATE ' || v, 'REFUSE', v_actual, '');
        END;
    END LOOP;
END $$;

-- ------------------------------------------------------------- report
\pset border 2
SELECT
    CASE WHEN expected = actual THEN 'PASS' ELSE '** FAIL **' END AS result,
    name, expected, actual, detail
FROM results ORDER BY name;

SELECT count(*) FILTER (WHERE expected = actual) || ' of ' || count(*) || ' passed'
    AS summary FROM results;

DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM results WHERE expected <> actual;
    IF n > 0 THEN RAISE EXCEPTION '% guard test(s) failed', n; END IF;
END $$;
