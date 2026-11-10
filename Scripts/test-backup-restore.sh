#!/bin/bash
#
# Tests Scripts/backup-before-install.sh against a throwaway database.
#
#   ./Scripts/test-backup-restore.sh
#
# Backup tooling that has never been restored from is a guess. These cases run
# the real script, end to end, and assert on what it produced.

set -uo pipefail
cd "$(dirname "$0")/.."
SCRIPT_UNDER_TEST="$(pwd)/Scripts/backup-before-install.sh"

pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }

# Never let a test reach the real installed application. An earlier version of
# the credential-health lookup probed by RUNNING the app binary, which on a
# build that does not recognise the flag launches the GUI — it started a second
# copy of the installed app and hung the suite.
export VRC_APP_BINARY="/nonexistent/VacationRentalCalendar"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
# Rehearsal mode. Not decoration: it makes a FORGOTTEN redirection a refusal
# instead of a write to the live database. On 2026-11-10 a rehearsal relied on
# an environment variable to isolate itself, the variable did not do what was
# assumed, and two live feeds were changed. Scripts sourced from here resolve
# the path they are about to touch and refuse if it is the real one.
export VRC_REHEARSAL="disposable-database-only"

export VRC_SUPPORT_DIR="${ROOT}/support"
mkdir -p "${VRC_SUPPORT_DIR}"
DB="${VRC_SUPPORT_DIR}/VacationRentalCalendar.sqlite"

# A database shaped like the real one, with a feed URL stored in the database
# column so the "no credential in the backup" check has something to find if
# it is broken.
sqlite3 "${DB}" <<'SQL'
CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, name TEXT, applied_at REAL);
INSERT INTO schema_migrations VALUES (13,'multi_property',0);
CREATE TABLE properties (id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO properties VALUES (1,'39 G Street');
CREATE TABLE platform_listings (id INTEGER PRIMARY KEY, platform TEXT, credential_ref TEXT);
INSERT INTO platform_listings VALUES (1,'airbnb','airbnb-p1-airbnb');
CREATE TABLE events (id INTEGER PRIMARY KEY, is_tombstoned INTEGER DEFAULT 0);
INSERT INTO events (id,is_tombstoned) VALUES (1,0),(2,0),(3,1);
CREATE TABLE classifications (event_key TEXT PRIMARY KEY);
INSERT INTO classifications VALUES ('a'),('b');
CREATE TABLE availability_decisions (id INTEGER PRIMARY KEY, publication_uid TEXT);
INSERT INTO availability_decisions VALUES (1,'vrc-aaa'),(2,'vrc-bbb');
CREATE TABLE availability_audit (id INTEGER PRIMARY KEY, decision_id INTEGER);
INSERT INTO availability_audit VALUES (1,1),(2,2);
SQL

printf '\033[1m==> Backup\033[0m\n'
OUT="$("${SCRIPT_UNDER_TEST}" 2>&1)"
DIR="$(printf '%s' "${OUT}" | grep -oE "${VRC_SUPPORT_DIR}/Backups/[0-9TZ]+" | head -1)"

[ -n "${DIR}" ] && [ -d "${DIR}" ] && ok "a backup directory was created" \
    || bad "no backup directory in the output"

[ -f "${DIR}/VacationRentalCalendar.sqlite" ] && ok "the database was captured" \
    || bad "no database in the backup"

printf '%s' "${OUT}" | grep -q "backup verified" && ok "the script verified its own backup" \
    || bad "the backup did not verify"

# The point of the whole exercise: no credential material anywhere.
if grep -rqE 'airbnb\.com/calendar/ical|vrbo\.com/icalendar|ical\.booking\.com' "${DIR}" 2>/dev/null; then
    bad "a feed URL leaked into the backup"
else
    ok "no feed URL anywhere in the backup"
fi

grep -q 'airbnb-p1-airbnb' "${DIR}/credential-references.txt" 2>/dev/null \
    && ok "credential REFERENCES are recorded" || bad "references missing"

grep -q 'events_active=2' "${DIR}/MANIFEST.txt" 2>/dev/null \
    && ok "the manifest records row counts" || bad "manifest counts missing or wrong"

printf '\n\033[1m==> Restore\033[0m\n'
# Destroy the live database the way a bad migration would, then restore.
sqlite3 "${DB}" "DELETE FROM events; DELETE FROM availability_decisions;" 2>/dev/null
before="$(sqlite3 "${DB}" 'SELECT COUNT(*) FROM events;')"
[ "${before}" = "0" ] && ok "precondition: the live database is wrecked" || bad "setup failed"

VRC_RESTORE_CONFIRMED=yes "${SCRIPT_UNDER_TEST}" --restore "${DIR}" >/dev/null 2>&1
after="$(sqlite3 "${DB}" 'SELECT COUNT(*) FROM events;')"
[ "${after}" = "3" ] && ok "restore brought the rows back" \
    || bad "restore left ${after} events, expected 3"

uids="$(sqlite3 "${DB}" 'SELECT COUNT(DISTINCT publication_uid) FROM availability_decisions;')"
[ "${uids}" = "2" ] && ok "publication UIDs survived the round trip" \
    || bad "expected 2 publication UIDs, got ${uids}"

ls "${VRC_SUPPORT_DIR}"/VacationRentalCalendar.sqlite.replaced-* >/dev/null 2>&1 \
    && ok "the wrecked database was set aside, so restore is itself reversible" \
    || bad "restore destroyed the previous state"

printf '\n  === %s passed, %s failed ===\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
