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
# The repository schema stores days as epoch doubles; the generated `stay`
# column derives the daterange the constraints use.
E() { Q -c "select extract(epoch from make_timestamptz($1,$2,$3,0,0,0,'UTC'))" | head -1; }
pass=0; fail=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then printf '  %-58s %-18s PASS\n' "$1" "$3"; pass=$((pass+1))
  else printf '  %-58s %-18s ** FAIL ** (wanted %s)\n' "$1" "$3" "$2"; fail=$((fail+1)); fi
}

echo "=== X1. simultaneous holds on overlapping nights ($ROUNDS rounds) ==="
both=0; neither=0; exactly_one=0
for i in $(seq 1 "$ROUNDS"); do
  SLUG="cx-$i-$RANDOM$$"
  PID=$(Q -c "insert into properties (name,address,notes,created_at,updated_at,time_zone) values ('$SLUG','','',0,0,'UTC') returning id" | head -1)
  # Two sessions, same property, overlapping ranges, released into the
  # transaction at the same time by a shared start barrier.
  for who in A B; do
    if [ "$who" = A ]; then IN=$(E 2027 5 1); OUT=$(E 2027 5 6); else IN=$(E 2027 5 4); OUT=$(E 2027 5 9); fi
    (
      psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -tAq -v ON_ERROR_STOP=1 <<SQL >/dev/null 2>&1
BEGIN ISOLATION LEVEL SERIALIZABLE;
SET LOCAL vrc.actor = 'website';
SELECT pg_sleep(0.05);
INSERT INTO holds (property_id, channel, check_in, check_out, expires_at, created_at)
VALUES ($PID, 'direct', $IN, $OUT, now() + interval '15 minutes', 0);
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
PID=$(Q -c "insert into properties (name,address,notes,created_at,updated_at,time_zone) values ('$SLUG','','',0,0,'UTC') returning id" | head -1)
for who in A B; do
  if [ "$who" = A ]; then IN=$(E 2027 11 1); OUT=$(E 2027 11 6); CH=airbnb; else IN=$(E 2027 11 3); OUT=$(E 2027 11 8); CH=vrbo; fi
  (
    psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -tAq -v ON_ERROR_STOP=1 <<SQL >/dev/null 2>&1
BEGIN;
SELECT pg_sleep(0.05);
INSERT INTO reservations (property_id, channel, check_in, check_out, status, created_at, updated_at)
VALUES ($PID, '$CH', $IN, $OUT, 'confirmed', 0, 0);
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
PID=$(Q -c "insert into properties (name,address,notes,created_at,updated_at,time_zone) values ('$SLUG','','',0,0,'UTC') returning id" | head -1)
for who in A B; do
  if [ "$who" = A ]; then IN=$(E 2027 12 1); OUT=$(E 2027 12 5); CH=airbnb; else IN=$(E 2027 12 5); OUT=$(E 2027 12 9); CH=vrbo; fi
  (
    psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -tAq -v ON_ERROR_STOP=1 <<SQL >/dev/null 2>&1
BEGIN;
SELECT pg_sleep(0.05);
INSERT INTO reservations (property_id, channel, check_in, check_out, status, created_at, updated_at)
VALUES ($PID, '$CH', $IN, $OUT, 'confirmed', 0, 0);
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
PID=$(Q -c "insert into properties (name,address,notes,created_at,updated_at,time_zone) values ('$SLUG','','',0,0,'UTC') returning id" | head -1)
RID=$(Q -c "insert into reservations (property_id,channel,check_in,check_out,status,external_ref,created_at,updated_at)
            values ($PID,'direct',$(E 2028 1 1),$(E 2028 1 8),'confirmed','ext-cw',0,0) returning id" | head -1)
Q -c "insert into holds (property_id,channel,check_in,check_out,expires_at,reservation_id,created_at)
      values ($PID,'direct',$(E 2028 1 1),$(E 2028 1 8), now()+interval '1 day',$RID,0)" >/dev/null
for who in A B; do
  (
    psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -tAq <<SQL > "/tmp/vrc-cancel-$$-$who" 2>&1
BEGIN;
SET LOCAL vrc.actor = 'website';
SELECT pg_sleep(0.05);
SELECT nights_released FROM vrc_cancel_website_booking($RID, 'concurrent test', 'ext-cw');
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
