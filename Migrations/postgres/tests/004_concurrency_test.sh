#!/bin/bash
#
# Two booking attempts, at the same moment, for overlapping nights.
#
# This cannot be tested from a single session, so it launches real concurrent
# psql processes. Run against a scratch database with migrations 001-003
# applied:
#
#   ./Migrations/postgres/tests/004_concurrency_test.sh <port> <db>

set -uo pipefail
PORT="${1:-54403}"
DB="${2:-vrc}"
HOST=127.0.0.1
USER=vrctest
ROUNDS="${ROUNDS:-12}"

Q() { psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -tAq "$@"; }
pass=0; fail=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then printf '  %-58s %-18s PASS\n' "$1" "$3"; pass=$((pass+1))
  else printf '  %-58s %-18s ** FAIL ** (wanted %s)\n' "$1" "$3" "$2"; fail=$((fail+1)); fi
}

echo "=== X1. simultaneous holds on overlapping nights ($ROUNDS rounds) ==="
both=0; neither=0; exactly_one=0
for i in $(seq 1 "$ROUNDS"); do
  SLUG="cx-$i-$RANDOM$$"
  PID=$(Q -c "insert into properties (slug,name) values ('$SLUG','$SLUG') returning id" | head -1)
  # Two sessions, same property, overlapping ranges, released into the
  # transaction at the same time by a shared start barrier.
  for who in A B; do
    if [ "$who" = A ]; then RANGE='[2027-05-01,2027-05-06)'; else RANGE='[2027-05-04,2027-05-09)'; fi
    (
      psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -tAq -v ON_ERROR_STOP=1 <<SQL >/dev/null 2>&1
BEGIN ISOLATION LEVEL SERIALIZABLE;
SET LOCAL vrc.actor = 'website';
SELECT pg_sleep(0.05);
INSERT INTO holds (property_id, channel, stay, expires_at)
VALUES ('$PID', 'direct', '$RANGE', now() + interval '15 minutes');
COMMIT;
SQL
      echo "$?" > "/tmp/vrc-cx-$$-$who"
    ) &
  done
  wait
  held=$(Q -c "select count(*) from holds where property_id='$PID' and released_at is null" | head -1)
  case "$held" in
    1) exactly_one=$((exactly_one+1)) ;;
    0) neither=$((neither+1)) ;;
    *) both=$((both+1)) ;;
  esac
done
rm -f /tmp/vrc-cx-$$-*
echo "   exactly one won: $exactly_one   neither: $neither   BOTH (double booking): $both"
check "X1 no round ever let both holds through" "0" "$both"
check "X1 every round produced a winner" "$ROUNDS" "$exactly_one"

echo
echo "=== X2. simultaneous CONFIRMED reservations on overlapping nights ==="
SLUG="cy-$RANDOM$$"
PID=$(Q -c "insert into properties (slug,name) values ('$SLUG','$SLUG') returning id" | head -1)
for who in A B; do
  if [ "$who" = A ]; then RANGE='[2027-11-01,2027-11-06)'; CH=airbnb; else RANGE='[2027-11-03,2027-11-08)'; CH=vrbo; fi
  (
    psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -tAq -v ON_ERROR_STOP=1 <<SQL >/dev/null 2>&1
BEGIN;
SELECT pg_sleep(0.05);
INSERT INTO reservations (property_id, channel, stay, status)
VALUES ('$PID', '$CH', '$RANGE', 'confirmed');
COMMIT;
SQL
  ) &
done
wait
confirmed=$(Q -c "select count(*) from reservations where property_id='$PID' and status='confirmed'" | head -1)
check "X2 only one confirmed reservation exists" "1" "$confirmed"

echo
echo "=== X3. checkout-day adjacency under concurrency must BOTH succeed ==="
SLUG="cz-$RANDOM$$"
PID=$(Q -c "insert into properties (slug,name) values ('$SLUG','$SLUG') returning id" | head -1)
for who in A B; do
  if [ "$who" = A ]; then RANGE='[2027-12-01,2027-12-05)'; CH=airbnb; else RANGE='[2027-12-05,2027-12-09)'; CH=vrbo; fi
  (
    psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -tAq -v ON_ERROR_STOP=1 <<SQL >/dev/null 2>&1
BEGIN;
SELECT pg_sleep(0.05);
INSERT INTO reservations (property_id, channel, stay, status)
VALUES ('$PID', '$CH', '$RANGE', 'confirmed');
COMMIT;
SQL
  ) &
done
wait
adjacent=$(Q -c "select count(*) from reservations where property_id='$PID' and status='confirmed'" | head -1)
check "X3 a guest leaving and another arriving the same day" "2" "$adjacent"

echo
echo "=== X4. simultaneous cancellations of ONE booking release nights once ==="
SLUG="cw-$RANDOM$$"
PID=$(Q -c "insert into properties (slug,name) values ('$SLUG','$SLUG') returning id" | head -1)
RID=$(Q -c "insert into reservations (property_id,channel,stay,status,external_ref)
            values ('$PID','direct','[2028-01-01,2028-01-08)','confirmed','ext-cw') returning id" | head -1)
Q -c "insert into holds (property_id,channel,stay,expires_at,reservation_id)
      values ('$PID','direct','[2028-01-01,2028-01-08)', now()+interval '1 day','$RID')" >/dev/null
for who in A B; do
  (
    psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -tAq <<SQL > "/tmp/vrc-cancel-$$-$who" 2>&1
BEGIN;
SET LOCAL vrc.actor = 'website';
SELECT pg_sleep(0.05);
SELECT nights_released FROM vrc_cancel_website_booking('$RID', 'concurrent test', 'ext-cw');
COMMIT;
SQL
  ) &
done
wait
total=0
for who in A B; do
  n=$(grep -oE '^[0-9]+$' "/tmp/vrc-cancel-$$-$who" 2>/dev/null | head -1)
  total=$((total + ${n:-0}))
done
rm -f /tmp/vrc-cancel-$$-*
audit=$(Q -c "select count(*) from availability_audit where detail like '%$RID%'" | head -1)
check "X4 nights released in total across both attempts" "7" "$total"
check "X4 exactly one audit row for the cancellation" "1" "$audit"
unreleased=$(Q -c "select count(*) from holds where reservation_id='$RID' and released_at is null" | head -1)
check "X4 the hold is released" "0" "$unreleased"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
