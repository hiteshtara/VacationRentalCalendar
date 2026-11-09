#!/bin/bash
#
# Moves the existing AWS staging credential to the newly installed `vrc`
# helper, WITHOUT rotating the IAM key.
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
# This is the one manual step after a helper rebuild. It does NOT create a new
# AWS key. It reads the secret you already stored, with your approval, and hands
# it to the new helper in memory so the new helper owns a readable copy.
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
