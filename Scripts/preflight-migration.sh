#!/bin/bash
#
# Preflight for the Developer ID + data protection Keychain migration.
#
#   ./Scripts/preflight-migration.sh
#
# READ-ONLY, AND CANNOT PROMPT. It reads Keychain item ATTRIBUTES only — never
# a value — so no authorization is requested and no dialog can appear. It
# executes neither the installed application nor the vrc helper. It opens the
# live database read-only to count rows and list reference NAMES.
#
# Exits non-zero if anything would block the migration, so it can gate the
# real run rather than merely describe it.

set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=apple-config.sh
source Scripts/apple-config.sh

SUPPORT="${HOME}/Library/Application Support/VacationRentalCalendar"
DB="${SUPPORT}/VacationRentalCalendar.sqlite"
SERVICE="com.vacationrentalcalendar.feed-url"
NEW_APP="dist-developer-id/VacationRentalCalendar.app"
OLD_APP="/Applications/VacationRentalCalendar.app"

blockers=0
ok()    { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn()  { printf '  \033[33mnote\033[0m  %s\n' "$*"; }
block() { printf '  \033[31mBLOCK\033[0m %s\n' "$*"; blockers=$((blockers+1)); }
step()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

printf '\033[1mMigration preflight — %s\033[0m\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'commit %s on %s\n' \
    "$(git rev-parse --short HEAD)" "$(git rev-parse --abbrev-ref HEAD)"

# ---------------------------------------------------------------- 1. inventory
step "1. Source inventory (names only, no value read)"

ALL_ITEMS="$(swift -e '
import Foundation
import Security
let q: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.vacationrentalcalendar.feed-url",
    kSecReturnAttributes as String: true,
    kSecMatchLimit as String: kSecMatchLimitAll,
]
var r: CFTypeRef?
guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess,
      let items = r as? [[String: Any]] else { exit(1) }
for name in items.compactMap({ $0[kSecAttrAccount as String] as? String }).sorted() {
    print(name)
}' 2>/dev/null)"

ITEM_COUNT="$(printf '%s\n' "${ALL_ITEMS}" | grep -c . || true)"
if [ "${ITEM_COUNT}" -eq 18 ]; then
    ok "${ITEM_COUNT} Keychain items under ${SERVICE}"
else
    block "expected 18 Keychain items, found ${ITEM_COUNT}"
fi

# "Configured" here must mean what CredentialInventory.wasConfigured means:
# evidenced, not inferred from the reference string. The SQL mirrors
# FeedConnectionState.impliesStoredCredential plus a URL in the database; a
# test asserts the two lists agree.
ACTIVE_FEEDS="$(sqlite3 "file:${DB}?mode=ro" \
    "SELECT credential_ref FROM platform_listings
     WHERE credential_ref <> ''
       AND (ical_url <> ''
            OR connection_state IN ('connected','failing','revoked',
                                    'disconnected_by_owner','credential_unreadable'))
     ORDER BY id;" 2>/dev/null)"
# The complement, computed rather than queried. A second SQL list would be the
# same rule written twice, free to drift from the first; this cannot.
ALL_DB_REFS="$(sqlite3 "file:${DB}?mode=ro" \
    "SELECT credential_ref FROM platform_listings
     WHERE credential_ref <> '' ORDER BY id;" 2>/dev/null)"
PLACEHOLDERS="$(printf '%s\n' "${ALL_DB_REFS}" \
                | grep -vxF -f <(printf '%s\n' ${ACTIVE_FEEDS}) || true)"

printf '\n  Active secrets (6 expected):\n'
for ref in ${ACTIVE_FEEDS} aws-access-key-id aws-secret-access-key \
           feed-key-1-booking_com-v1; do
    if printf '%s\n' "${ALL_ITEMS}" | grep -qx "${ref}"; then
        printf '    \033[32mpresent\033[0m  %s\n' "${ref}"
    else
        block "active secret missing from the Keychain: ${ref}"
    fi
done

# The six active names, one per line, so exclusion is a line match rather than
# a glob over a space-joined string — which excluded nothing and reported 15.
ACTIVE_LIST="$(printf '%s\n' ${ACTIVE_FEEDS}
printf '%s\n' aws-access-key-id aws-secret-access-key feed-key-1-booking_com-v1)"

printf '\n  Historical entries kept for rollback (12 expected):\n'
HISTORICAL="$(printf '%s\n' "${ALL_ITEMS}" \
              | grep -vxF -f <(printf '%s\n' "${ACTIVE_LIST}") || true)"
printf '%s\n' "${HISTORICAL}" | sed '/^$/d; s/^/    /'
HIST="$(printf '%s\n' "${HISTORICAL}" | grep -c . || true)"
[ "${HIST}" -eq 12 ] && ok "${HIST} historical entries" \
                     || block "expected 12 historical entries, found ${HIST}"

# ------------------------------------------------------------- 2. no blockers
step "2. Configured-but-missing check (the only stop condition here)"
MISSING=0
for ref in ${ACTIVE_FEEDS}; do
    printf '%s\n' "${ALL_ITEMS}" | grep -qx "${ref}" || { MISSING=$((MISSING+1)); }
done
[ "${MISSING}" -eq 0 ] && ok "no configured listing references a missing secret" \
                       || block "${MISSING} configured listing(s) reference a missing secret"

printf '\n  Unconfigured listings — placeholders, NOT blockers:\n'
for ref in ${PLACEHOLDERS}; do printf '    %s\n' "${ref}"; done
ok "$(printf '%s\n' "${PLACEHOLDERS}" | grep -c . || true) placeholder(s) correctly excluded"

# ---------------------------------------------------------- 3. new identity
step "3. Developer ID build, profile and access group"
if [ ! -d "${NEW_APP}" ]; then
    block "no Developer ID build at ${NEW_APP}"
else
    # Captured ONCE. Piping codesign into `grep -q` makes grep exit on the
    # first match, codesign take SIGPIPE, and `pipefail` report the whole
    # pipeline as failed — which is how this reported a correctly signed
    # bundle as not chaining to Apple.
    SIGINFO="$(codesign -dvvv "${NEW_APP}" 2>&1)"
    AUTH="$(printf '%s\n' "${SIGINFO}" | awk -F= '/^Authority/{print $2; exit}')"
    case "${AUTH}" in
        "Developer ID Application:"*"${APPLE_TEAM_ID}"*) ok "signed: ${AUTH}" ;;
        *) block "unexpected signing authority: ${AUTH}" ;;
    esac
    case "${SIGINFO}" in
        *"Authority=Apple Root CA"*) ok "chains to Apple Root CA" ;;
        *) block "does not chain to Apple Root CA" ;;
    esac

    TEAM="$(printf '%s\n' "${SIGINFO}" | awk -F= '/^TeamIdentifier/{print $2}')"
    [ "${TEAM}" = "${APPLE_TEAM_ID}" ] && ok "team identifier ${TEAM}" \
                                       || block "team identifier is '${TEAM}'"

    [ -f "${NEW_APP}/Contents/embedded.provisionprofile" ] \
        && ok "provisioning profile embedded" \
        || block "no embedded.provisionprofile in the bundle"

    GROUP="$(codesign -d --entitlements - --xml "${NEW_APP}" 2>/dev/null \
             | plutil -extract keychain-access-groups.0 raw - 2>/dev/null)"
    [ "${GROUP}" = "${KEYCHAIN_ACCESS_GROUP}" ] \
        && ok "authorized access group ${GROUP}" \
        || block "access group is '${GROUP}', expected ${KEYCHAIN_ACCESS_GROUP}"

    STORE="$("${NEW_APP}/Contents/MacOS/${APP_NAME}" --credential-store 2>/dev/null || true)"
    case "${STORE}" in
        *"data-protection true"*) ok "the build selects the data protection Keychain" ;;
        *) block "the build would NOT select the data protection Keychain" ;;
    esac
    case "${STORE}" in
        *"team-signed true"*) ok "reports itself team-signed" ;;
        *) block "does not report itself team-signed" ;;
    esac
fi

# ------------------------------------------------------------ 4. rollback
step "4. Rollback assets, checked against both identities"
NEW_DR="$(codesign -d -r- "${NEW_APP}" 2>/dev/null | grep '^designated' || echo none)"
OLD_DR="$(codesign -d -r- "${OLD_APP}" 2>/dev/null | grep '^designated' || echo none)"
printf '  installed now : %s\n' "${OLD_DR#designated => }"
printf '  after migration: %s\n' "${NEW_DR#designated => }"
[ "${NEW_DR}" != "${OLD_DR}" ] \
    && ok "the identity changes deliberately — expect one-time authorization per secret" \
    || warn "the identities are the same, which is unexpected for a Developer ID build"

BK="$(ls -d "${SUPPORT}/Backups"/*/ 2>/dev/null | while read -r d; do
        [ -f "${d}VacationRentalCalendar.sqlite" ] && printf '%s\n' "${d}"; done | tail -1)"
if [ -z "${BK}" ]; then
    block "no verified database backup found"
else
    ok "backup: ${BK}"
    sqlite3 "file:${BK}VacationRentalCalendar.sqlite?mode=ro" "PRAGMA integrity_check;" \
        2>/dev/null | grep -qx ok && ok "backup database integrity_check ok" \
                                  || block "backup database failed integrity_check"
    if [ -d "${BK}VacationRentalCalendar.app" ]; then
        BK_DR="$(codesign -d -r- "${BK}VacationRentalCalendar.app" 2>/dev/null \
                 | grep '^designated')"
        [ "${BK_DR}" = "${OLD_DR}" ] \
            && ok "preserved bundle matches the installed identity — rollback is a copy" \
            || block "the preserved bundle's identity does not match the installed one"
    else
        block "no preserved application bundle in the backup"
    fi
fi

# --------------------------------------------------------- 5. data at rest
step "5. Data that must not change (recorded now, to compare after)"
sqlite3 "file:${DB}?mode=ro" "
SELECT 'active events      ', COUNT(*) FROM events WHERE is_tombstoned=0
UNION ALL SELECT 'classifications    ', COUNT(*) FROM classifications
UNION ALL SELECT 'decisions          ', COUNT(*) FROM availability_decisions
UNION ALL SELECT 'publication UIDs   ', COUNT(*) FROM availability_decisions
         WHERE publication_uid LIKE 'vrc-%'
UNION ALL SELECT 'audit rows         ', COUNT(*) FROM availability_audit
UNION ALL SELECT 'connection events  ', COUNT(*) FROM listing_connection_events
UNION ALL SELECT 'max sync run       ', MAX(id) FROM sync_runs;" 2>/dev/null \
  | sed 's/|/ /' | sed 's/^/    /'
printf '    connection states  '
sqlite3 "file:${DB}?mode=ro" \
    "SELECT group_concat(id||'='||connection_state,' ') FROM platform_listings
     WHERE id IN (1,2,3);" 2>/dev/null
ok "recorded; the migration must leave every one of these unchanged"

# ------------------------------------------------------------------ verdict
step "Verdict"
if [ "${blockers}" -eq 0 ]; then
    printf '  \033[32mREADY\033[0m — no blockers. Migration still requires separate approval.\n'
    exit 0
fi
printf '  \033[31mNOT READY\033[0m — %s blocker(s). Do not migrate.\n' "${blockers}"
exit 1
