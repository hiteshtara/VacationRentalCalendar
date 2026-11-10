#!/bin/bash
#
# Tests the SELECTION logic of Scripts/migrate-cloud-credential.sh.
#
#   ./Scripts/test-migrate-credentials.sh
#
# Nothing here touches the real Keychain or a real install. `security` and the
# `vrc` helper are replaced by stubs on PATH, so the test can assert exactly
# which listings the script would prompt for — which is the property that
# matters. On 2026-11-10 it prompted six times for three credentials, and the
# one real failure was lost among three that could never succeed.
#
# The stub `security` records every call, so "did it prompt for this?" becomes
# "did it call `security ... -w` for this reference?".

set -uo pipefail
cd "$(dirname "$0")/.."
SCRIPT_UNDER_TEST="$(pwd)/Scripts/migrate-cloud-credential.sh"

pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; trap 'rm -rf "${ROOT}"' EXIT
mkdir -p "${ROOT}/bin"
CALLS="${ROOT}/security-calls.log"

# Stub `security`. PRESENT_REFS lists references that "exist" in the keychain;
# anything else reports absence, exactly as the real tool does for a reference
# that was never written.
cat > "${ROOT}/bin/security" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${CALLS}"
ref=""; want_value=false
while [ $# -gt 0 ]; do
    case "$1" in
        -a) ref="$2"; shift 2 ;;
        -w) want_value=true; shift ;;
        *)  shift ;;
    esac
done
case " ${PRESENT_REFS} " in
    *" ${ref} "*) ;;
    *) exit 44 ;;
esac
if [ "${want_value}" = true ]; then printf 'https://example.test/%s.ics\n' "${ref}"; fi
exit 0
STUB
chmod +x "${ROOT}/bin/security"

# Stub helper. Records set-url calls; `keychain` claims nothing is readable so
# the script always attempts a migration.
cat > "${ROOT}/bin/vrc" <<'STUB'
#!/bin/bash
case "${1:-}" in
    keychain) exit 0 ;;
    cloud)    exit 1 ;;
    set-url)  cat >/dev/null; printf '%s\n' "set-url $*" >> "${CALLS}"; exit 0 ;;
esac
exit 0
STUB
chmod +x "${ROOT}/bin/vrc"
export CALLS

make_db() {
    local db="$1"; rm -f "$db"
    sqlite3 "$db" <<'SQL'
CREATE TABLE properties (id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO properties VALUES (1,'39 G Street'),(2,'Test Cottage');
CREATE TABLE platform_listings (
  id INTEGER PRIMARY KEY, property_id INTEGER, platform TEXT, label TEXT,
  credential_ref TEXT, url_storage TEXT DEFAULT 'keychain');
INSERT INTO platform_listings (id,property_id,platform,label,credential_ref) VALUES
 (1,1,'vrbo','Vrbo','vrbo-5550554-v5'),
 (2,1,'airbnb','Airbnb','airbnb-123-v5'),
 (3,1,'booking_com','Booking.com','booking-17482435-v2'),
 (4,2,'airbnb','Airbnb','airbnb-p2-test-cottage'),
 (5,2,'vrbo','Vrbo','vrbo-p2-test-cottage'),
 (6,2,'booking_com','Booking.com','booking_com-p2-test-cottage');
SQL
}

run_migration() {
    : > "${CALLS}"
    make_db "${ROOT}/db.sqlite"
    PATH="${ROOT}/bin:${PATH}" \
    PRESENT_REFS="$1" \
    VRC_DB_OVERRIDE="${ROOT}/db.sqlite" \
    VRC_HELPER_OVERRIDE="${ROOT}/bin/vrc" \
        "${SCRIPT_UNDER_TEST}" --feeds-only "${@:2}" >/dev/null 2>&1
}

# How many times a VALUE was requested — i.e. how many authorization prompts
# the real tool would have raised.
# grep -c already prints 0 when nothing matches; it just exits 1 as well, so a
# `|| echo 0` fallback printed the count TWICE and the comparison never matched.
prompts() { grep -c -- '-w' "${CALLS}" 2>/dev/null; true; }
prompted_for() { grep -q -- "-a $1 " "${CALLS}" 2>/dev/null; }

printf '\033[1m==> Prompting only where a credential exists\033[0m\n'

# The three real listings have credentials; Test Cottage's three never did.
run_migration "vrbo-5550554-v5 airbnb-123-v5 booking-17482435-v2"
got="$(prompts)"
[ "${got}" = "3" ] && ok "three credentials, three prompts" \
    || bad "expected 3 prompts, got ${got}"

for ref in airbnb-p2-test-cottage vrbo-p2-test-cottage booking_com-p2-test-cottage; do
    if prompted_for "${ref}"; then bad "prompted for ${ref}, which has no credential"
    else ok "no prompt for ${ref}"; fi
done

printf '\n\033[1m==> Targeted migration\033[0m\n'

run_migration "vrbo-5550554-v5 airbnb-123-v5 booking-17482435-v2" --platform booking_com
got="$(prompts)"
[ "${got}" = "1" ] && ok "--platform booking_com prompts exactly once" \
    || bad "expected 1 prompt, got ${got}"
prompted_for "booking-17482435-v2" && ok "and it is the Booking.com credential" \
    || bad "the wrong credential was read"
if prompted_for "airbnb-123-v5" || prompted_for "vrbo-5550554-v5"; then
    bad "a working credential was touched"
else
    ok "the working Airbnb and Vrbo credentials are untouched"
fi

run_migration "vrbo-5550554-v5 airbnb-123-v5 booking-17482435-v2" --listing 1
got="$(prompts)"
[ "${got}" = "1" ] && ok "--listing 1 prompts exactly once" \
    || bad "expected 1 prompt, got ${got}"

printf '\n\033[1m==> Multiple properties\033[0m\n'

# A second property with real credentials must still be migrated: skipping is
# about ABSENT credentials, not about which property owns them.
run_migration "vrbo-5550554-v5 airbnb-123-v5 booking-17482435-v2 airbnb-p2-test-cottage"
got="$(prompts)"
[ "${got}" = "4" ] && ok "a second property's real credential is included" \
    || bad "expected 4 prompts, got ${got}"

run_migration ""
got="$(prompts)"
[ "${got}" = "0" ] && ok "nothing stored anywhere means no prompts at all" \
    || bad "expected 0 prompts, got ${got}"

printf '\n  === %s passed, %s failed ===\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
