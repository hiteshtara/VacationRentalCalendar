#!/bin/bash
#
# Proves a rehearsal cannot reach the live database.
#
#   ./Scripts/test-rehearsal-isolation.sh
#
# WHY THIS EXISTS
#
# On 2026-11-10 a rehearsal of a connection-state recovery was "isolated" by
# setting HOME to a temporary directory and copying the database there. On
# macOS, FileManager resolves the application support directory WITHOUT
# consulting HOME, so `vrc` opened the real database and changed two live
# feeds' connection state without approval. The copy being watched was never
# touched, so the rehearsal's own before/after check showed nothing wrong: the
# wrong file was being read.
#
# So these tests do the dangerous thing ON PURPOSE. They aim state-changing
# commands straight at the live database and require a refusal. The live
# database is checksummed before and after the whole run and the suite fails
# loudly if a single byte changed — if a guard is ever broken, this says so
# instead of the next person finding out from their data.

set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

VRC="${REPO}/.build/debug/vrc"
LIVE_DB="${HOME}/Library/Application Support/VacationRentalCalendar/VacationRentalCalendar.sqlite"
SUPPORT_DIR="${HOME}/Library/Application Support/VacationRentalCalendar"
REHEARSAL_VAR="VRC_REHEARSAL"
REHEARSAL_VALUE="disposable-database-only"

pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }

digest() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'; }

if [ ! -x "${VRC}" ]; then
    echo "building vrc..." && swift build --product vrc >/dev/null 2>&1
fi
[ -x "${VRC}" ] || { echo "error: no vrc binary"; exit 1; }
[ -f "${LIVE_DB}" ] || { echo "error: no live database to defend"; exit 1; }

# The tripwire. Everything below must leave this untouched.
LIVE_BEFORE="$(digest "${LIVE_DB}")"
LIVE_STATES_BEFORE="$(sqlite3 "${LIVE_DB}" \
    "SELECT id||'='||connection_state FROM platform_listings ORDER BY id;")"
LIVE_EVENTS_BEFORE="$(sqlite3 "${LIVE_DB}" "SELECT COUNT(*) FROM listing_connection_events;")"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

printf '\033[1m==> 1. A state-changing command aimed at the live database is refused\033[0m\n'

# The exact command that caused the incident, pointed at the real file.
OUT="$("${VRC}" connection --listing 1 --state failing \
        --detail "isolation test — must never be written" --actor test \
        --database "${LIVE_DB}" 2>&1)"
RC=$?
[ "${RC}" -ne 0 ] && ok "refused (exit ${RC})" || bad "NOT refused (exit ${RC}): ${OUT}"
printf '%s' "${OUT}" | grep -qi "refus" \
    && ok "and the refusal says so plainly" \
    || bad "no refusal in the message: ${OUT}"

printf '\033[1m==> 2. So are the other spellings of the same file\033[0m\n'

# A symlink that looks disposable and resolves to production.
ln -s "${LIVE_DB}" "${WORK}/innocent.sqlite" 2>/dev/null
OUT="$("${VRC}" connection --listing 1 --state failing --actor test \
        --database "${WORK}/innocent.sqlite" 2>&1)"
[ $? -ne 0 ] && ok "a symlink to the live database is refused" \
             || bad "a symlink to the live database was accepted: ${OUT}"

# Traversal back into the support directory.
OUT="$("${VRC}" connection --listing 1 --state failing --actor test \
        --database "${SUPPORT_DIR}/sub/../VacationRentalCalendar.sqlite" 2>&1)"
[ $? -ne 0 ] && ok "traversal into the support directory is refused" \
             || bad "traversal was accepted: ${OUT}"

# The write-ahead log, which holds the most recent writes.
OUT="$("${VRC}" connection --listing 1 --state failing --actor test \
        --database "${LIVE_DB}-wal" 2>&1)"
[ $? -ne 0 ] && ok "the write-ahead log is refused" \
             || bad "the WAL was accepted: ${OUT}"

printf '\033[1m==> 3. Rehearsal mode refuses to fall back to the live database\033[0m\n'

# No --database at all. Without rehearsal mode this would open production,
# which is the whole mistake; with it, the omission is a refusal.
OUT="$(env "${REHEARSAL_VAR}=${REHEARSAL_VALUE}" "${VRC}" connection \
        --listing 1 --state failing --actor test 2>&1)"
[ $? -ne 0 ] && ok "a missing --database is a refusal, not a default" \
             || bad "it defaulted to the live database: ${OUT}"
printf '%s' "${OUT}" | grep -q "REFUSED" \
    && ok "and names the mode that refused it" \
    || bad "unclear refusal: ${OUT}"

printf '\033[1m==> 4. A disposable copy still works, so the guard is usable\033[0m\n'

COPY="${WORK}/scratch.sqlite"
sqlite3 "${LIVE_DB}" ".backup '${COPY}'" 2>/dev/null
BEFORE_COPY="$(sqlite3 "${COPY}" "SELECT connection_state FROM platform_listings WHERE id=1;")"
OUT="$(env "${REHEARSAL_VAR}=${REHEARSAL_VALUE}" "${VRC}" connection \
        --listing 1 --state connected --detail "rehearsal" --actor test \
        --database "${COPY}" 2>&1)"
RC=$?
[ "${RC}" -eq 0 ] && ok "a disposable path is accepted (exit ${RC})" \
                  || bad "a disposable path was refused: ${OUT}"
AFTER_COPY="$(sqlite3 "${COPY}" "SELECT connection_state FROM platform_listings WHERE id=1;")"
[ "${BEFORE_COPY}" != "${AFTER_COPY}" ] \
    && ok "and the change landed in the copy (${BEFORE_COPY} -> ${AFTER_COPY})" \
    || bad "the copy did not change, so nothing was actually exercised"

printf '\033[1m==> 5. The command announces which database it opened\033[0m\n'
printf '%s' "${OUT}" | grep -q "database .*scratch.sqlite" \
    && ok "the resolved path is printed, so the wrong file is obvious" \
    || bad "no database path announced: ${OUT}"

printf '\033[1m==> 6. In-memory needs no path and touches no file\033[0m\n'
OUT="$(env "${REHEARSAL_VAR}=${REHEARSAL_VALUE}" "${VRC}" status --memory 2>&1)"
[ $? -eq 0 ] && ok "--memory is accepted in rehearsal mode" \
             || bad "--memory was refused: ${OUT}"

printf '\033[1m==> 7. A backup rehearsal cannot target the live support directory\033[0m\n'
OUT="$(env "${REHEARSAL_VAR}=${REHEARSAL_VALUE}" VRC_SUPPORT_DIR="${SUPPORT_DIR}" \
        "${REPO}/Scripts/backup-before-install.sh" 2>&1)"
[ $? -ne 0 ] && ok "a rehearsal backup aimed at the live directory is refused" \
             || bad "it backed up the live directory in rehearsal mode"

printf '\033[1m==> 8. THE TRIPWIRE: the live database is byte-identical\033[0m\n'

LIVE_AFTER="$(digest "${LIVE_DB}")"
LIVE_STATES_AFTER="$(sqlite3 "${LIVE_DB}" \
    "SELECT id||'='||connection_state FROM platform_listings ORDER BY id;")"
LIVE_EVENTS_AFTER="$(sqlite3 "${LIVE_DB}" "SELECT COUNT(*) FROM listing_connection_events;")"

[ "${LIVE_BEFORE}" = "${LIVE_AFTER}" ] \
    && ok "the live database file is unchanged" \
    || bad "THE LIVE DATABASE CHANGED: ${LIVE_BEFORE} -> ${LIVE_AFTER}"
[ "${LIVE_STATES_BEFORE}" = "${LIVE_STATES_AFTER}" ] \
    && ok "every connection state is unchanged" \
    || bad "CONNECTION STATES CHANGED: ${LIVE_STATES_BEFORE} -> ${LIVE_STATES_AFTER}"
[ "${LIVE_EVENTS_BEFORE}" = "${LIVE_EVENTS_AFTER}" ] \
    && ok "no connection-history row was added (${LIVE_EVENTS_AFTER})" \
    || bad "HISTORY WAS WRITTEN: ${LIVE_EVENTS_BEFORE} -> ${LIVE_EVENTS_AFTER}"

printf '\n  === %s passed, %s failed ===\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
