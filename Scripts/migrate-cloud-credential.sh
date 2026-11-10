#!/bin/bash
#
# Moves the existing credentials — the AWS staging key AND each platform's
# private feed URL — to the newly installed `vrc` helper, WITHOUT rotating
# anything.
#
#   ./Scripts/migrate-cloud-credential.sh
#
# WHY THIS EXISTS
#
# On this machine a login-keychain item is readable only by the exact code
# object that created it: macOS pins the creating binary's code hash in the
# item's partition list, and a rebuild changes that hash. So when the helper is
# rebuilt, it can no longer read the credential a previous build stored, and the
# partition list cannot be widened without your login password. See
# docs/KEYCHAIN.md for the full investigation.
#
# This is the one manual step after a helper rebuild. It creates no new AWS key
# and no new feed URL. It reads what you already stored, with your approval, and
# hands it to the new helper in memory so the new helper owns a readable copy.
#
# Feed URLs are included because they break in exactly the same way and had no
# migration path: an app update silently disconnected Airbnb, Vrbo and
# Booking.com, and the only remedy was re-typing URLs the owner had to find
# again. A credential that cannot be read is reported as needing re-entry — it
# is never reported as migrated.
#
# WHAT IT DOES NOT DO
#
#   - It never writes the secret to disk, a log, or your shell history.
#   - It never prints the secret.
#   - It never calls AWS. No key is created, rotated, or deleted.
#
# macOS will prompt once per item for permission to read it. Choose "Always
# Allow" so a later run is silent. The prompt is macOS's own; this script never
# sees your login password.

set -uo pipefail

SERVICE="com.vacationrentalcalendar.feed-url"
HELPER="/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc"
KEY_ID_REF="aws-access-key-id"
SECRET_REF="aws-secret-access-key"

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

[ -x "$HELPER" ] || { say "No installed helper at $HELPER — run ./Scripts/build-app.sh --install first."; exit 1; }

step "Checking whether the new helper already reads its credential"
if "$HELPER" cloud status 2>/dev/null | grep -q "readable"; then
    say "The helper already reads its AWS credential. Nothing to migrate."
    exit 0
fi

step "Reading the existing credential (macOS will ask your permission)"
say "Choose \"Always Allow\" at each prompt."

# -w prints only the password field to stdout; captured into a shell variable,
# never displayed, never written to a file.
KEY_ID="$(security find-generic-password -s "$SERVICE" -a "$KEY_ID_REF" -w 2>/dev/null)"
SECRET="$(security find-generic-password -s "$SERVICE" -a "$SECRET_REF" -w 2>/dev/null)"

if [ -z "${KEY_ID}" ] || [ -z "${SECRET}" ]; then
    say ""
    say "Could not read the existing credential. Either the prompt was declined,"
    say "or no credential is stored. Nothing was changed, and your IAM key is"
    say "untouched. You can store it again with:  $HELPER cloud set-credentials"
    exit 1
fi

step "Handing it to the new helper, in memory"
# Two lines on stdin: key id, then secret. Never on the command line.
printf '%s\n%s\n' "${KEY_ID}" "${SECRET}" | "$HELPER" cloud set-credentials --stdin
rc=$?
unset KEY_ID SECRET

if [ "$rc" -ne 0 ]; then
    say "The helper did not store the credential (exit $rc)."
    exit "$rc"
fi

step "Verifying the helper can now reach the service"
if "$HELPER" cloud check >/dev/null 2>&1; then
    say "Done. The new helper owns a readable copy. The same IAM key — not a new one."
    say "The old keychain entry is left in place; nothing was deleted."
else
    say "Stored, but the service did not answer on the first try. Open the app and"
    say "press Refresh from AWS, or run:  $HELPER cloud check"
fi

# ---------------------------------------------------------------- feed URLs --
#
# Same failure, same remedy. Each listing's URL lives under its own reference,
# which `vrc status` prints and the database records. The URL itself is never
# printed, never written to a file, and never placed on a command line — it
# travels from `security` to the helper through a pipe and nothing else.

step "Migrating private feed URLs"

DB="${HOME}/Library/Application Support/VacationRentalCalendar/VacationRentalCalendar.sqlite"
if [ ! -f "$DB" ]; then
    say "No local database at the expected path; skipping feed URLs."
    exit 0
fi

migrated=0; already=0; needs_entry=0

# `.backup` rather than reading the live file: a plain read misses the WAL.
TMPDB="$(mktemp -t vrcmig).sqlite"
sqlite3 "$DB" ".backup '${TMPDB}'" 2>/dev/null || { say "Could not read the database; skipping feed URLs."; exit 0; }

while IFS='|' read -r listing_id platform ref label; do
    [ -n "${ref:-}" ] || continue
    say ""
    say "  ${platform} (listing ${listing_id}) — reference ${ref}"

    # Does the new helper already read it? Then leave it completely alone.
    if "$HELPER" keychain 2>/dev/null | grep -F "[${ref}]" | grep -q "^  ok"; then
        say "    already readable by this build — nothing to do"
        already=$((already + 1))
        continue
    fi

    # Read the old item. macOS prompts; choose "Always Allow". The value is
    # captured into a shell variable and never echoed.
    URL="$(security find-generic-password -s "$SERVICE" -a "$ref" -w 2>/dev/null)"
    if [ -z "${URL:-}" ]; then
        say "    could not be read, even with authorization."
        say "    ACTION REQUIRED: re-enter this URL under Feeds in the app."
        say "    (The old entry is untouched. Nothing was deleted or rotated.)"
        needs_entry=$((needs_entry + 1))
        continue
    fi

    # Hand it over through a pipe. --stdin skips the interactive confirmation
    # but keeps every check: https only, fetched and parsed before saving.
    if printf '%s\n' "${URL}" | "$HELPER" set-url --listing "${listing_id}" --stdin --rehome >/dev/null 2>&1; then
        unset URL
        if "$HELPER" keychain 2>/dev/null | grep -F "${platform}" | grep -q "^  ok"; then
            say "    migrated and verified readable"
        else
            say "    migrated; the helper still cannot read it — re-entry may be required"
        fi
        migrated=$((migrated + 1))
    else
        unset URL
        say "    the helper refused to store it (the URL may no longer be valid)."
        say "    ACTION REQUIRED: re-enter this URL under Feeds in the app."
        needs_entry=$((needs_entry + 1))
    fi
done <<EOF
$(sqlite3 "$TMPDB" "SELECT id, platform, credential_ref, label FROM platform_listings WHERE credential_ref <> '' ORDER BY id;" 2>/dev/null)
EOF

rm -f "$TMPDB"

step "Feed URL summary"
say "  migrated:           ${migrated}"
say "  already readable:   ${already}"
say "  need manual re-entry: ${needs_entry}"
if [ "${needs_entry}" -gt 0 ]; then
    say ""
    say "Some URLs could not be migrated. They are bearer credentials this script"
    say "cannot recover; re-enter them under Feeds in the app. Nothing was deleted,"
    say "nothing was rotated, and no platform availability was touched."
    exit 2
fi
