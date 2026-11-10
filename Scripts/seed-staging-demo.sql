-- Synthetic demo data for the AWS *staging* cluster only.
--
-- Gives the Cloud pane two visible blocking intervals (one confirmed
-- reservation, one active hold) for a demo "39 G Street", in 2027 so they never
-- collide with real 2026 data. Fully self-contained and idempotent: it creates
-- the property if the integration suite deleted it, and is safe to re-run.
--
-- NOT production data. The staging cluster holds only synthetic rows; the
-- integration suite clears these tables and this file restores them. Never run
-- against production.

-- The property the demo intervals hang off. Idempotent on the name.
INSERT INTO properties (name, address, created_at, updated_at)
SELECT 'Staging Demo — 39 G Street', 'South Boston, MA',
       extract(epoch from now()), extract(epoch from now())
WHERE NOT EXISTS (SELECT 1 FROM properties WHERE name = 'Staging Demo — 39 G Street');

-- One confirmed reservation and one active hold, keyed to the demo property.
DELETE FROM reservations r USING properties p
 WHERE r.property_id = p.id AND p.name = 'Staging Demo — 39 G Street' AND r.channel = 'direct';
INSERT INTO reservations (property_id, channel, check_in, check_out, status, external_ref, created_at, updated_at)
SELECT p.id, 'direct',
       extract(epoch from timestamp '2027-07-01 00:00:00'),
       extract(epoch from timestamp '2027-07-08 00:00:00'),
       'confirmed', 'demo-res-1',
       extract(epoch from now()), extract(epoch from now())
  FROM properties p WHERE p.name = 'Staging Demo — 39 G Street';

DELETE FROM holds h USING properties p
 WHERE h.property_id = p.id AND p.name = 'Staging Demo — 39 G Street' AND h.channel = 'direct';
INSERT INTO holds (property_id, channel, check_in, check_out, expires_at, external_ref, created_at)
SELECT p.id, 'direct',
       extract(epoch from timestamp '2027-09-01 00:00:00'),
       extract(epoch from timestamp '2027-09-04 00:00:00'),
       timestamp '2099-01-01 00:00:00+00', 'demo-hold-1',
       extract(epoch from now())
  FROM properties p WHERE p.name = 'Staging Demo — 39 G Street';
