#!/bin/bash
#
# Tests that taking a backup, or asking about credential health, cannot touch
# a credential value, cannot raise a Keychain dialog, cannot launch the app,
# and cannot change any connection state.
#
#   ./Scripts/test-credential-health.sh
#
# WHY THESE EXIST
#
# On 2026-11-10 at 23:05 `backup-before-install.sh` launched
# `VacationRentalCalendar --credential-health` to ask whether six credentials
# were readable. Answering that question means READING them, which requests
# Keychain authorization. The running app's hourly refresh fired at the same
# moment, both code objects asked for authorization on the same items, two
# reads returned -128, and the import path latched `credentialUnreadable` on
# Airbnb and Vrbo — a state that is never retried. A backup disconnected two
# live calendars.
#
# The central test below is not a grep. It points the scripts at a DECOY app
# bundle whose executable records that it ran, and then asserts the decoy was
# never executed. That is the test that would have caught the original bug,
# and it keeps working however the scripts are refactored.
#
# THIS FILE REPLACES AN EARLIER VERSION, and two of its assertions are now
# deliberately inverted. The old suite asserted that a binary DECLARING
# --credential-health support "was executed", and that the app reported
# `readable` / `unreadable` / `not-configured` distinctly. Executing the app is
# precisely the defect, and `unreadable` was a claim only a secret read could
# justify. The cases that still hold — a non-declaring binary is never run, an
# unknown reference is not-configured, an empty reference is not a lookup — are
# kept below.

set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }

# Rehearsal mode. Not decoration: it makes a FORGOTTEN redirection a refusal
# instead of a write to the live database. On 2026-11-10 a rehearsal relied on
# an environment variable to isolate itself, the variable did not do what was
# assumed, and two live feeds were changed. Scripts sourced from here resolve
# the path they are about to touch and refuse if it is the real one.
export VRC_REHEARSAL="disposable-database-only"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# A bundle that looks installed and able to answer --credential-health, whose
# executable does nothing but record that something ran it.
make_decoy() {
    local root="$1"
    mkdir -p "${root}/Contents/MacOS"
    cat > "${root}/Contents/MacOS/VacationRentalCalendar" <<'DECOY'
#!/bin/bash
printf 'executed %s\n' "$*" >> "${VRC_DECOY_MARKER}"
exit 0
DECOY
    chmod +x "${root}/Contents/MacOS/VacationRentalCalendar"
    cp "${root}/Contents/MacOS/VacationRentalCalendar" "${root}/Contents/MacOS/vrc"
    cat > "${root}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.vacationrentalcalendar.app</string>
  <key>VRCSupportsCredentialHealth</key><true/>
</dict></plist>
PLIST
}

printf '\033[1m==> 1. A backup never executes the application\033[0m\n'

DECOY="${WORK}/Decoy.app"
MARKER="${WORK}/decoy-ran.txt"
make_decoy "${DECOY}"

# A realistic database to back up: the real schema, with connection states set.
SUPPORT="${WORK}/support"
mkdir -p "${SUPPORT}"
DB="${SUPPORT}/VacationRentalCalendar.sqlite"
# The newest backup directory that actually holds a database. Chosen by
# scanning rather than by `tail -1`: a stray bundle directory sorts after the
# timestamped ones and has no database in it.
SEED=""
for candidate in "${HOME}/Library/Application Support/VacationRentalCalendar/Backups"/*; do
    [ -f "${candidate}/VacationRentalCalendar.sqlite" ] && SEED="${candidate}"
done
if [ -n "${SEED}" ]; then
    # Read-only use of an existing verified backup as a schema source. Copied
    # through .backup, never written back.
    sqlite3 "${SEED}/VacationRentalCalendar.sqlite" ".backup '${DB}'" 2>/dev/null
fi

if [ ! -f "${DB}" ]; then
    bad "no database available to test against (need one verified backup)"
else
    BEFORE="$(sqlite3 "${DB}" "SELECT id||'='||connection_state FROM platform_listings ORDER BY id;")"
    REFS="$(sqlite3 "${DB}" "SELECT COUNT(*) FROM platform_listings WHERE credential_ref <> '';")"

    OUT="$(VRC_SUPPORT_DIR="${SUPPORT}" \
           VRC_APP_BUNDLE="${DECOY}" \
           VRC_APP_BINARY="${DECOY}/Contents/MacOS/VacationRentalCalendar" \
           VRC_DECOY_MARKER="${MARKER}" \
           "${REPO}/Scripts/backup-before-install.sh" 2>&1)"
    RC=$?

    [ "${RC}" -eq 0 ] && ok "the backup completed (exit ${RC})" \
                      || bad "the backup failed (exit ${RC})"

    # THE test. If the scripts ever go back to asking the app, this fires.
    if [ -f "${MARKER}" ]; then
        bad "the backup EXECUTED the application: $(tr '\n' ' ' < "${MARKER}")"
    else
        ok "the application was never executed"
    fi

    AFTER="$(sqlite3 "${DB}" "SELECT id||'='||connection_state FROM platform_listings ORDER BY id;")"
    [ "${BEFORE}" = "${AFTER}" ] \
        && ok "no connection state changed" \
        || bad "connection states changed: ${BEFORE} -> ${AFTER}"

    # The backup must still do its job, not pass by doing nothing.
    NEWDIR="$(ls -d "${SUPPORT}/Backups"/*/ 2>/dev/null | tail -1)"
    if [ -n "${NEWDIR}" ] && [ -f "${NEWDIR}/keychain-presence.txt" ]; then
        LINES="$(grep -cv '^#' "${NEWDIR}/keychain-presence.txt" || true)"
        [ "${LINES}" = "${REFS}" ] \
            && ok "all ${REFS} reference(s) still recorded" \
            || bad "recorded ${LINES} of ${REFS} reference(s)"
        grep -q '^#' "${NEWDIR}/keychain-presence.txt" \
            && ok "the presence file states what it does and does not prove" \
            || bad "no caveat recorded alongside the statuses"
    else
        bad "no backup directory or presence file produced"
    fi

    # And it must not have written a secret anywhere, which the backup's own
    # verifier also checks — asserted here independently.
    if grep -rlE 'airbnb\.com/calendar/ical|vrbo\.com/icalendar|ical\.booking\.com' \
         "${SUPPORT}/Backups" >/dev/null 2>&1; then
        bad "a feed URL reached the backup"
    else
        ok "no feed URL anywhere in the backup"
    fi
fi

printf '\033[1m==> 2. The health helper cannot read a secret\033[0m\n'

# `security ... -w` is the flag that prints a password. Its absence is the
# property; asserted on the source because there is no way to observe "did not
# pass a flag" from outside.
if grep -nE 'find-generic-password[^|]*(-w|--?password)' Scripts/credential-health.sh >/dev/null 2>&1; then
    bad "credential-health.sh asks security for a secret value"
else
    ok "credential-health.sh never passes -w to security"
fi

for script in credential-health.sh backup-before-install.sh; do
    if grep -nE '\$\{?(APP_BINARY|VRC_APP_BINARY)\}?"?[[:space:]]|--credential-health|--credential-store' \
         "Scripts/${script}" | grep -v '^\s*#' | grep -vE '^[0-9]+:#' >/dev/null 2>&1; then
        bad "${script} still invokes the app binary"
    else
        ok "${script} contains no invocation of the app binary"
    fi
done

printf '\033[1m==> 3. Data protection items are reported, not guessed\033[0m\n'

# shellcheck source=credential-health.sh
source "${REPO}/Scripts/credential-health.sh"

STATUS="$(VRC_FORCE_HEALTH_SOURCE=unverifiable credential_status "some-ref")"
[ "${STATUS}" = "unverified" ] \
    && ok "a data protection item reports 'unverified', not a guess" \
    || bad "expected 'unverified', got '${STATUS}'"

CAVEAT="$(VRC_FORCE_HEALTH_SOURCE=unverifiable credential_health_caveat)"
printf '%s' "${CAVEAT}" | grep -qi "not verified" \
    && ok "and says plainly that presence was not verified" \
    || bad "the caveat does not say presence is unverified: ${CAVEAT}"

# It must not silently answer "not-configured" for a DP item, which would make
# six live credentials look like data loss.
[ "${STATUS}" != "not-configured" ] \
    && ok "an unverifiable item is never reported as absent" \
    || bad "a data protection item was reported absent"

printf '\033[1m==> 4. A binary that does not declare support is never executed either\033[0m\n'

# Kept from the earlier suite. Its point was narrower than today's rule — it
# only forbade running a binary that had not declared the flag — but a
# regression that reintroduced probing would likely reintroduce it here first.
PLAIN="${WORK}/Undeclared.app"
PLAIN_MARKER="${WORK}/undeclared-ran.txt"
mkdir -p "${PLAIN}/Contents/MacOS"
cat > "${PLAIN}/Contents/MacOS/VacationRentalCalendar" <<'UNDECL'
#!/bin/bash
printf 'executed\n' >> "${VRC_DECOY_MARKER}"
exit 0
UNDECL
chmod +x "${PLAIN}/Contents/MacOS/VacationRentalCalendar"
printf '<?xml version="1.0"?><plist version="1.0"><dict/></plist>\n' \
    > "${PLAIN}/Contents/Info.plist"

( export VRC_APP_BUNDLE="${PLAIN}"
  export VRC_APP_BINARY="${PLAIN}/Contents/MacOS/VacationRentalCalendar"
  export VRC_DECOY_MARKER="${PLAIN_MARKER}"
  source "${REPO}/Scripts/credential-health.sh"
  credential_status "whatever-ref" >/dev/null 2>&1 ) || true

[ -f "${PLAIN_MARKER}" ] \
    && bad "an undeclared binary was executed" \
    || ok "an undeclared binary was not executed"

printf '\033[1m==> 5. An unknown reference is absent, not an error\033[0m\n'

# Kept from the earlier suite. A reference with no Keychain item behind it must
# read as not-configured rather than failing the caller.
UNKNOWN="$(VRC_FORCE_HEALTH_SOURCE=security \
           CREDENTIAL_SERVICE="com.vacationrentalcalendar.test-absent" \
           credential_status "no-such-reference-$$")"
[ "${UNKNOWN}" = "not-configured" ] \
    && ok "an unknown reference reports not-configured" \
    || bad "expected not-configured, got '${UNKNOWN}'"

printf '\033[1m==> 6. An empty reference is not a Keychain question at all\033[0m\n'
EMPTY="$(credential_status "")"
[ "${EMPTY}" = "not-configured" ] \
    && ok "an unconfigured listing needs no lookup" \
    || bad "expected not-configured, got ${EMPTY}"

printf '\n  === %s passed, %s failed ===\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
