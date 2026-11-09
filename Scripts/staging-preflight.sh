#!/bin/bash
#
# Re-validates everything immediately before a staging apply, and prints a
# single go/no-go.
#
#   ./Scripts/staging-preflight.sh
#
# Run this in the same shell session as the apply. A plan reviewed yesterday is
# not the plan that applies today: providers move, AWS retires engine versions
# (16.4 vanished from us-east-1 while this project was being written), and a
# tfvars file can be edited. This re-derives the plan and re-checks the
# invariants rather than trusting the last run.
#
# It creates nothing and changes nothing.

set -uo pipefail
cd "$(dirname "$0")/.."
TF="Infrastructure/terraform"
PLAN="$(mktemp -t vrc-staging-plan)"
trap 'rm -f "${PLAN}"' EXIT

EXPECTED_RESOURCES=60
failures=0

say()  { printf '%b\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mNO\033[0m   %s\n' "$*"; failures=$((failures+1)); }

# ---------------------------------------------------------------- 1. the code
step "1. Business rules"
# The runner colours its summary, so the escape codes are stripped before
# matching -- they sit between the count and the assertion total.
STRIP='s/\x1b\[[0-9;]*m//g'
TESTS="$(swift run vrc-test 2>&1 | sed "${STRIP}" \
         | grep -oE 'All [0-9]+ tests passed \([0-9]+ assertions\)' | tail -1)"
FAILED="$(swift run vrc-test 2>&1 | sed "${STRIP}" | grep -oE '[0-9]+ of [0-9]+ tests failed' | tail -1)"
if [ -n "${TESTS}" ] && [ -z "${FAILED}" ]; then ok "${TESTS}"
else bad "the test suite did not pass${FAILED:+ (${FAILED})}"; fi

DIGEST="$(swift run vrc-parity --digest 2>/dev/null | tail -1)"
EXPECTED_DIGEST="b3398471b1ee56f477d9a1244b16449e8827df1616aa5fca365ef3db96c604f5"
if [ "${DIGEST}" = "${EXPECTED_DIGEST}" ]; then
    ok "parity digest unchanged"
else
    bad "parity digest moved: ${DIGEST:-<none>}"
    say "       the business rules changed; re-run Scripts/check-parity.sh"
fi

if grep -q "public static let isEnabled = false" Sources/VRCCore/Logic/ExportPolicy.swift; then
    ok "OutboundSyncGate.isEnabled = false in code"
else
    bad "OutboundSyncGate.isEnabled is NOT false"
fi

# ------------------------------------------------------------ 2. migrations
step "2. Migrations are safe to send over the Data API"
for f in "${TF}/../../Migrations/postgres/010_repository_schema.sql" \
         "${TF}/../../Migrations/postgres/011_safety.sql"; do
    [ -f "$f" ] || { bad "missing $(basename "$f")"; continue; }
    # One statement at a time is the Data API's only mode, so an unbalanced
    # dollar-quote marker means a function body would be cut in half.
    if python3 - "$f" <<'PY'
import sys, re
text = open(sys.argv[1], encoding='utf-8').read()
# crude but sufficient: the whole file must have an even number of $$ markers
sys.exit(0 if text.count('$$') % 2 == 0 else 1)
PY
    then ok "$(basename "$f"): dollar quotes balanced"
    else bad "$(basename "$f"): unbalanced dollar quotes"; fi
done

# ------------------------------------------------------------- 3. packages
step "3. Lambda packages"
for f in fetch process publish api sweeper; do
    z=".build/lambda/${f}.zip"
    if [ ! -f "$z" ]; then
        bad "${f}.zip missing — run ./Scripts/build-lambda.sh"
        continue
    fi
    boot=$(unzip -l "$z" 2>/dev/null | grep -c " bootstrap$")
    libs=$(unzip -l "$z" 2>/dev/null | grep -c "lib/.*\.so")
    if [ "$boot" = "1" ] && [ "$libs" -gt 20 ]; then
        ok "${f}.zip: bootstrap + ${libs} libs"
    else
        bad "${f}.zip looks wrong (bootstrap=${boot} libs=${libs})"
    fi
done

# ------------------------------------------------------- 4. the actual plan
step "4. Re-deriving the staging plan"
if ! (cd "${TF}" && terraform init -input=false -no-color >/dev/null 2>&1); then
    bad "terraform init failed"
fi
if (cd "${TF}" && terraform plan -input=false -no-color \
        -var-file=staging.tfvars -out="${PLAN}" >/tmp/vrc-plan.log 2>&1); then
    ok "plan succeeded (check blocks passed)"
else
    bad "plan failed — see /tmp/vrc-plan.log"
    tail -5 /tmp/vrc-plan.log | sed 's/^/       /'
fi

if [ -s "${PLAN}" ]; then
  # The JSON goes to a file, not a pipe: python's script arrives on stdin via
  # the heredoc, so stdin cannot also carry the plan.
  PLAN_JSON="$(mktemp -t vrc-plan-json)"
  (cd "${TF}" && terraform show -json "${PLAN}" 2>/dev/null) > "${PLAN_JSON}"
  python3 - "${EXPECTED_RESOURCES}" "${PLAN_JSON}" <<'PY'
import json, sys, re
expected = int(sys.argv[1])
d = json.load(open(sys.argv[2]))
rc = d.get('resource_changes', [])
create = [r for r in rc if 'create' in r['change']['actions']]
other  = [r for r in rc if any(a in r['change']['actions'] for a in ('update','delete'))]
blob = json.dumps(rc)

def ok(m):  print(f"  \033[32mok\033[0m   {m}")
def bad(m): print(f"  \033[31mNO\033[0m   {m}"); sys.exit(1)

if len(create) == expected: ok(f"{len(create)} resources to create, as expected")
else: bad(f"{len(create)} resources to create, expected {expected} — review the diff")

if not other: ok("nothing to update or destroy")
else: bad(f"{len(other)} resource(s) would be changed or destroyed")

for t, label in [('aws_route53_record','Route 53 records'),
                 ('aws_acm_certificate','ACM certificates'),
                 ('aws_cloudfront_distribution','CloudFront distributions')]:
    if any(r['type'] == t for r in rc): bad(f"{label} present — staging must create none")
ok("no Route 53, ACM or CloudFront resources")

dynamo = sorted(set(re.findall(r'dynamodb:\w+', blob)))
if dynamo: bad(f"DynamoDB actions granted: {dynamo} — staging must have none")
ok("no DynamoDB access granted")

if 'priyankahomes' in blob.lower(): bad("the plan references PriyankaHomes")
ok("no PriyankaHomes references")

for r in rc:
    if r['type'] == 'aws_scheduler_schedule':
        state = (r['change']['after'] or {}).get('state')
        if state != 'DISABLED': bad(f"schedule {r['address']} would be {state}")
ok("both schedules created DISABLED")

for r in rc:
    if r['type'] == 'aws_rds_cluster':
        a = r['change']['after'] or {}
        sv = (a.get('serverlessv2_scaling_configuration') or [{}])[0]
        if a.get('engine_version') != '16.15':
            bad(f"engine_version is {a.get('engine_version')}, expected 16.15")
        if not a.get('enable_http_endpoint'): bad("the Data API is not enabled")
        if a.get('publicly_accessible'): bad("the cluster would be publicly accessible")
        if not a.get('storage_encrypted'): bad("storage is not encrypted")
        ok(f"cluster: {a.get('engine_version')}, Data API on, private, encrypted, "
           f"{sv.get('min_capacity')}–{sv.get('max_capacity')} ACU")

for r in rc:
    if r['type'] == 'aws_rds_cluster_instance':
        if (r['change']['after'] or {}).get('publicly_accessible'):
            bad("the writer instance would be publicly accessible")
ok("the writer instance is not publicly accessible")

leaked = [r['address'] for r in rc
          if r['type'] == 'aws_secretsmanager_secret_version'
          and (r['change']['after'] or {}).get('secret_string')]
if leaked: bad(f"secret values visible in the plan: {leaked}")
ok("no secret values in the plan")
PY
  [ $? -eq 0 ] || failures=$((failures+1))
  rm -f "${PLAN_JSON}"
fi

# ------------------------------------------------- 5. production untouched
step "5. Production is where it should be"
TABLES=$(aws dynamodb list-tables \
    --query "length(TableNames[?starts_with(@,'priyankahomes-south-boston')])" \
    --output text 2>/dev/null)
[ "${TABLES}" = "2" ] && ok "both PriyankaHomes tables present" \
                      || bad "expected 2 PriyankaHomes tables, found ${TABLES:-0}"

for zone in bostonfurnishedstays.com 39gstboston.com; do
    n=$(aws route53 list-hosted-zones \
        --query "length(HostedZones[?Name=='${zone}.'])" --output text 2>/dev/null)
    [ "${n}" = "1" ] && ok "hosted zone ${zone} present" || bad "hosted zone ${zone} missing"
done

DB="${HOME}/Library/Application Support/VacationRentalCalendar/VacationRentalCalendar.sqlite"
if [ -f "${DB}" ]; then
    SNAP="$(mktemp -t vrc-snap).sqlite"
    sqlite3 "${DB}" ".backup '${SNAP}'" 2>/dev/null
    A=$(sqlite3 "${SNAP}" "select count(*) from availability_decisions where status='approved'" 2>/dev/null)
    P=$(sqlite3 "${SNAP}" "select count(*) from availability_decisions where status='published'" 2>/dev/null)
    E=$(sqlite3 "${SNAP}" "select count(*) from events" 2>/dev/null)
    C=$(sqlite3 "${SNAP}" "select count(*) from classifications" 2>/dev/null)
    rm -f "${SNAP}"
    [ "${A}" = "2" ] && ok "2 approved decisions" || bad "approved decisions = ${A}, expected 2"
    [ "${P}" = "0" ] && ok "0 published decisions" || bad "published decisions = ${P}, expected 0"
    [ "${E}" = "7" ] && ok "7 events" || bad "events = ${E}, expected 7"
    [ "${C}" = "7" ] && ok "7 classifications" || bad "classifications = ${C}, expected 7"
fi

# ------------------------------------------------------------------ verdict
step "Verdict"
if [ "${failures}" -eq 0 ]; then
    say "  \033[32mGO\033[0m — the plan is valid and every invariant holds."
    say ""
    say "  Nothing has been applied. The apply command, which still needs the"
    say "  owner's explicit authorisation, is:"
    say ""
    say "    cd ${TF} && terraform apply -var-file=staging.tfvars"
    exit 0
fi
say "  \033[31mNO-GO\033[0m — ${failures} check(s) failed above. Do not apply."
exit 1
