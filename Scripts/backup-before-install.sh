#!/bin/bash
#
# Takes a verified backup before installing a new build or running a migration.
#
#   ./Scripts/backup-before-install.sh              take a backup
#   ./Scripts/backup-before-install.sh --verify DIR check an existing backup
#   ./Scripts/backup-before-install.sh --restore DIR  put it back
#
# What it captures:
#
#   * the SQLite database, through `sqlite3 .backup` — never a file copy. The
#     WAL holds recent writes, and copying the .sqlite alone reads stale data.
#     That has already produced one wrong conclusion in this project.
#   * the installed application bundle, if one is found.
#   * a MANIFEST describing what was taken, with row counts to verify against.
#   * the credential REFERENCES — the Keychain account names only.
#
# What it deliberately does NOT capture: any credential value. Feed URLs are
# bearer tokens; anyone holding one can read a listing's whole booking
# calendar. They are never written to a backup, because a backup is an
# unencrypted directory that gets copied to places nobody is thinking about.
# `security find-generic-password` is called WITHOUT -w, so it reads attributes
# only and cannot prompt, cannot block, and never touches secret material.
#
# Restoring the database does not restore credentials. If a Keychain entry is
# lost, the URL is re-entered through the app — see docs/KEYCHAIN.md.

set -uo pipefail
cd "$(dirname "$0")/.."

# Overridable so the restore path can be exercised by tests against a
# throwaway database. Untestable backup tooling is how you find out it never
# worked at the moment you need it.
# shellcheck source=credential-health.sh
source "$(dirname "$0")/credential-health.sh"

SUPPORT="${VRC_SUPPORT_DIR:-${HOME}/Library/Application Support/VacationRentalCalendar}"
DB="${SUPPORT}/VacationRentalCalendar.sqlite"
SERVICE="com.vacationrentalcalendar.feed-url"

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

counts_of() {
    sqlite3 "$1" "
      SELECT 'schema_version='||COALESCE(MAX(version),0) FROM schema_migrations
      UNION ALL SELECT 'properties='||COUNT(*) FROM properties
      UNION ALL SELECT 'listings='||COUNT(*) FROM platform_listings
      UNION ALL SELECT 'events_active='||COUNT(*) FROM events WHERE is_tombstoned=0
      UNION ALL SELECT 'events_all='||COUNT(*) FROM events
      UNION ALL SELECT 'classifications='||COUNT(*) FROM classifications
      UNION ALL SELECT 'decisions='||COUNT(*) FROM availability_decisions
      UNION ALL SELECT 'audit='||COUNT(*) FROM availability_audit
      UNION ALL SELECT 'publication_uids='||COUNT(DISTINCT publication_uid) FROM availability_decisions
      ORDER BY 1;" 2>/dev/null
}

find_app() {
    for candidate in "/Applications/VacationRentalCalendar.app" \
                     "${HOME}/Applications/VacationRentalCalendar.app" \
                     "dist/VacationRentalCalendar.app"; do
        [ -d "${candidate}" ] && { printf '%s' "${candidate}"; return 0; }
    done
    return 1
}

take_backup() {
    local stamp dir
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    dir="${SUPPORT}/Backups/${stamp}"
    mkdir -p "${dir}" || { bad "could not create ${dir}"; exit 1; }

    step "1. Database"
    if [ ! -f "${DB}" ]; then bad "no database at ${DB}"; exit 1; fi
    # .backup is a live, consistent snapshot including the WAL.
    if sqlite3 "${DB}" ".backup '${dir}/VacationRentalCalendar.sqlite'" 2>/dev/null; then
        ok "database snapshot taken ($(wc -c < "${dir}/VacationRentalCalendar.sqlite" | tr -d ' ') bytes)"
    else
        bad "sqlite3 .backup failed"; exit 1
    fi

    step "2. Application bundle"
    local app
    if app="$(find_app)"; then
        ditto "${app}" "${dir}/VacationRentalCalendar.app" 2>/dev/null \
            && ok "copied ${app}" || bad "could not copy ${app}"
    else
        say "  (no installed bundle found — nothing to copy)"
    fi

    step "3. Credential references (names only, never values)"
    : > "${dir}/credential-references.txt"
    sqlite3 "${DB}" "SELECT platform||'  '||credential_ref FROM platform_listings
                     WHERE credential_ref <> '' ORDER BY platform;" 2>/dev/null \
        >> "${dir}/credential-references.txt"
    while read -r ref; do
        [ -z "${ref}" ] && continue
        # Asked through the signed app where one is installed, because
        # /usr/bin/security cannot see data protection Keychain items at all.
        # No secret is read either way.
        printf '%-15s %s\n' "$(credential_status "${ref}")" "${ref}" \
            >> "${dir}/keychain-presence.txt"
    done < <(sqlite3 "${DB}" "SELECT credential_ref FROM platform_listings WHERE credential_ref <> '';" 2>/dev/null)
    ok "$(wc -l < "${dir}/credential-references.txt" | tr -d ' ') reference(s) recorded, no values"
    say "  health source: $(credential_health_source)"

    step "4. Manifest"
    {
        printf 'taken_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'git_commit=%s\n' "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
        printf 'git_branch=%s\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
        printf 'source_db=%s\n' "${DB}"
        counts_of "${dir}/VacationRentalCalendar.sqlite"
    } > "${dir}/MANIFEST.txt"
    ok "manifest written"

    verify_backup "${dir}"
    step "Done"
    say "  ${dir}"
    say ""
    say "  Restore with:  ./Scripts/backup-before-install.sh --restore '${dir}'"
}

verify_backup() {
    local dir="$1" failures=0
    step "Verifying ${dir}"
    local copy="${dir}/VacationRentalCalendar.sqlite"
    [ -f "${copy}" ] || { bad "no database in the backup"; return 1; }

    local integrity; integrity="$(sqlite3 "${copy}" "PRAGMA integrity_check;" 2>/dev/null)"
    [ "${integrity}" = "ok" ] && ok "integrity_check ok" \
        || { bad "integrity_check: ${integrity}"; failures=$((failures+1)); }

    # The backup must still agree with the live database it came from, or it is
    # a snapshot of something that no longer exists.
    if [ -f "${DB}" ]; then
        local live backup
        live="$(counts_of "${DB}")"; backup="$(counts_of "${copy}")"
        if [ "${live}" = "${backup}" ]; then
            ok "row counts match the live database"
        else
            bad "row counts differ from live — the database changed after the backup"
            diff <(printf '%s\n' "${live}") <(printf '%s\n' "${backup}") | sed 's/^/      /'
            failures=$((failures+1))
        fi
    fi

    # A backup containing a credential would be the whole point missed.
    if grep -rqE 'airbnb\.com/calendar/ical|vrbo\.com/icalendar|ical\.booking\.com|lambda-url' \
        "${dir}" 2>/dev/null; then
        bad "a feed URL appears inside the backup — refusing to call this safe"
        failures=$((failures+1))
    else
        ok "no feed URL anywhere in the backup"
    fi

    [ "${failures}" -eq 0 ] && ok "backup verified" || bad "${failures} problem(s)"
    return "${failures}"
}

restore_backup() {
    local dir="$1"
    local copy="${dir}/VacationRentalCalendar.sqlite"
    [ -f "${copy}" ] || { bad "no database in ${dir}"; exit 1; }

    step "Restoring from ${dir}"
    say "  This replaces ${DB}."
    say "  Quit Vacation Rental Calendar first, or the running app will overwrite it."
    if [ "${VRC_RESTORE_CONFIRMED:-}" = "yes" ]; then
        say "  (confirmation supplied by VRC_RESTORE_CONFIRMED)"
    else
        printf '  Type RESTORE to continue: '
        read -r answer
        [ "${answer}" = "RESTORE" ] || { say "  Cancelled."; exit 1; }
    fi

    # Keep whatever is there now, so a restore is itself reversible.
    if [ -f "${DB}" ]; then
        local aside="${DB}.replaced-$(date -u +%Y%m%dT%H%M%SZ)"
        sqlite3 "${DB}" ".backup '${aside}'" 2>/dev/null && ok "current database set aside at ${aside}"
    fi
    cp "${copy}" "${DB}" && ok "database restored"
    rm -f "${DB}-wal" "${DB}-shm"
    say ""
    say "  Credentials are NOT restored — they were never in the backup."
    say "  If a feed reports that its URL cannot be read, re-enter it in the app."
}

case "${1:-}" in
    --verify)  [ -n "${2:-}" ] || { bad "--verify needs a directory"; exit 1; }
               verify_backup "$2"; exit $? ;;
    --restore) [ -n "${2:-}" ] || { bad "--restore needs a directory"; exit 1; }
               restore_backup "$2"; exit $? ;;
    "")        take_backup ;;
    *)         bad "unknown option $1"; exit 1 ;;
esac
