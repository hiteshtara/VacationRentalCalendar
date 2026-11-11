#!/bin/bash
#
# Installs the Developer ID build — but only in the right order.
#
#   ./Scripts/install-developer-id.sh
#
# The order is not advice in a document, it is enforced here. Every one of
# these must already be true or this refuses to copy anything:
#
#   1. no copy of the application is running;
#   2. a VERIFIED backup exists, taken after the application stopped, holding
#      both the database and the currently installed bundle;
#   3. the preflight passes — 18 source items, no missing configured secret,
#      Developer ID signature, embedded profile, authorized access group.
#
# "Never install before backup" is the rule it exists to make unbreakable: an
# install replaces the only copy of the bundle a rollback needs.

set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=apple-config.sh
source Scripts/apple-config.sh

SUPPORT="${HOME}/Library/Application Support/VacationRentalCalendar"
NEW_APP="dist-developer-id/${APP_NAME}.app"
INSTALLED="/Applications/${APP_NAME}.app"

step()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()    { printf '  \033[32mok\033[0m    %s\n' "$*"; }
refuse() { printf '  \033[31mREFUSED\033[0m %s\n' "$*"; exit 1; }

step "1. The application must not be running"
RUNNING="$(pgrep -f "${INSTALLED}/Contents/MacOS/" || true)"
[ -n "${RUNNING}" ] && refuse "pid ${RUNNING} is running. Quit it first: a credential
          read racing its refresh timer is what disconnected two feeds on
          2026-11-10."
ok "nothing running"

step "2. A verified backup, newer than the application stopped"
BK=""
for candidate in "${SUPPORT}/Backups"/*; do
    [ -f "${candidate}/VacationRentalCalendar.sqlite" ] || continue
    [ -d "${candidate}/${APP_NAME}.app" ] || continue
    BK="${candidate}"
done
[ -z "${BK}" ] && refuse "no backup containing BOTH a database and an application
          bundle. Run ./Scripts/backup-before-install.sh first."
ok "backup: ${BK}"

# It must hold the bundle that is installed RIGHT NOW, or a rollback would
# restore something else.
INSTALLED_CD="$(codesign -dvvv "${INSTALLED}" 2>&1 | awk -F= '/^CDHash/{print $2}')"
BACKUP_CD="$(codesign -dvvv "${BK}/${APP_NAME}.app" 2>&1 | awk -F= '/^CDHash/{print $2}')"
[ -n "${INSTALLED_CD}" ] && [ "${INSTALLED_CD}" != "${BACKUP_CD}" ] \
    && refuse "the backup holds bundle ${BACKUP_CD} but ${INSTALLED_CD} is installed.
          Take a fresh backup so the rollback target is the build being replaced."
ok "the backup holds the bundle being replaced (${BACKUP_CD})"

INTEGRITY="$(sqlite3 "file:${BK}/VacationRentalCalendar.sqlite?mode=ro" \
             "PRAGMA integrity_check;" 2>/dev/null | head -1)"
[ "${INTEGRITY}" = "ok" ] || refuse "the backup database fails integrity_check: ${INTEGRITY}"
ok "backup database integrity_check ok"

step "3. Preflight"
if ./Scripts/preflight-migration.sh >/tmp/vrc-preflight.log 2>&1; then
    ok "preflight READY (full output: /tmp/vrc-preflight.log)"
else
    printf '%s\n' "$(tail -20 /tmp/vrc-preflight.log)"
    refuse "preflight reported blockers. Nothing was copied."
fi

step "4. Install"
[ -d "${NEW_APP}" ] || refuse "no build at ${NEW_APP}. Run ./Scripts/package-developer-id.sh"
codesign --verify --deep --strict "${NEW_APP}" 2>/dev/null \
    || refuse "the new bundle fails codesign --verify --deep --strict"

# /Applications is drwxrwxr-x root:admin, and an admin user writes there
# without elevation — which is how Scripts/build-app.sh has always installed.
# Asking for sudo unconditionally made this step block on a password prompt in
# a non-interactive run, so privilege is requested only if it is actually
# needed.
as_needed() {
    if [ -w /Applications ]; then "$@"; else sudo "$@"; fi
}

printf '  replacing %s\n' "${INSTALLED}"
as_needed rm -rf "${INSTALLED}" || refuse "could not remove the installed bundle"
as_needed cp -R "${NEW_APP}" /Applications/ || refuse "could not copy the new bundle"
ok "installed"

step "5. What is now installed"
codesign -dvvv "${INSTALLED}" 2>&1 | grep -E "^Authority|^TeamIdentifier|^CDHash" | sed 's/^/    /'
codesign -d -r- "${INSTALLED}" 2>&1 | grep '^designated' | sed 's/^/    /'
printf '\n'
"${INSTALLED}/Contents/MacOS/${APP_NAME}" --credential-store 2>&1 | sed 's/^/    /'

printf '\n  Next: --migrate-credentials --dry-run, then --migrate-credentials.\n'
printf '  Rollback: see docs/MIGRATION-RUNBOOK.md. It deletes NO credential.\n'
