#!/bin/bash
#
# Inspects a provisioning profile and reports whether it actually authorizes
# this app's Keychain access group.
#
#   ./Scripts/inspect-provisioning-profile.sh [path]
#
# Written because "it should work" is not evidence. A profile is a signed
# plist with an Entitlements dictionary listing what the profile ALLOWS a
# signature to claim; if `keychain-access-groups` is absent from that
# dictionary, or present but not covering our group, the app is killed by AMFI
# on launch with no error and no log. That is the failure this machine hit on
# 2026-11-10, and it is cheap to rule out before building anything.
#
# Reads only. Touches no credential, no keychain, and no installed app.

set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/apple-config.sh

PROFILE="${1:-Resources/Profiles/vrc-developer-id.provisionprofile}"

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m--\033[0m   %s\n' "$*"; }

if [ -z "${VRC_PROFILE_PLIST:-}" ] && [ ! -f "${PROFILE}" ]; then
    bad "no profile at ${PROFILE}"
    say "       Create one — see docs/KEYCHAIN-MIGRATION.md — and save it there."
    exit 1
fi

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
PLIST="${WORK}/profile.plist"

# A profile is CMS-signed; this extracts the payload. It verifies nothing about
# Apple's signature, which is fine: we are reading what the profile claims, and
# macOS does the verifying at launch.
#
# VRC_PROFILE_PLIST supplies an already-decoded payload instead, so the
# matching logic below can be tested without a real signed profile. A verifier
# nobody has tested is not a verifier — a bug in the wildcard matching would
# report PASS for a profile that authorizes nothing.
if [ -n "${VRC_PROFILE_PLIST:-}" ]; then
    cp "${VRC_PROFILE_PLIST}" "${PLIST}"
elif ! security cms -D -i "${PROFILE}" > "${PLIST}" 2>/dev/null; then
    bad "could not decode ${PROFILE} — is it really a provisioning profile?"
    exit 1
fi

read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "${PLIST}" 2>/dev/null; }

step "Profile"
printf '  %-22s %s\n' "name"        "$(read_key Name)"
printf '  %-22s %s\n' "App ID name" "$(read_key AppIDName)"
printf '  %-22s %s\n' "team"        "$(read_key TeamIdentifier:0)"
printf '  %-22s %s\n' "team name"   "$(read_key TeamName)"
printf '  %-22s %s\n' "platform"    "$(read_key Platform:0)"
printf '  %-22s %s\n' "created"     "$(read_key CreationDate)"
printf '  %-22s %s\n' "expires"     "$(read_key ExpirationDate)"
# Developer ID profiles provision all devices; a development profile lists UDIDs.
if read_key ProvisionsAllDevices >/dev/null 2>&1; then
    printf '  %-22s %s\n' "kind" "Developer ID / distribution (provisions all devices)"
else
    printf '  %-22s %s\n' "kind" "development or App Store (device-limited)"
fi

step "Team"
PROFILE_TEAM="$(read_key TeamIdentifier:0)"
if [ "${PROFILE_TEAM}" = "${APPLE_TEAM_ID}" ]; then
    ok "profile team ${PROFILE_TEAM} matches apple-config.sh"
else
    bad "profile team is ${PROFILE_TEAM}, this project expects ${APPLE_TEAM_ID}"
fi

step "Authorized entitlements"
/usr/libexec/PlistBuddy -c "Print :Entitlements" "${PLIST}" 2>/dev/null \
    | sed 's/^/      /' | head -40

step "Keychain access group"
# NOT named GROUPS: bash reserves that as a readonly array of the user's group
# IDs, so the assignment is silently ignored and ${GROUPS} returns a gid. The
# inspector then reported that a perfectly good profile authorized nothing —
# caught only because the inspector itself has tests.
AUTHORIZED="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:keychain-access-groups" "${PLIST}" 2>/dev/null \
          | grep -vE '^(Array|\{|\})' | sed 's/^ *//; s/ *$//' | grep -v '^$')"

if [ -z "${AUTHORIZED}" ]; then
    bad "the profile authorizes NO keychain-access-groups at all"
    say "       Signing with that entitlement would be killed by AMFI on launch."
    say "       This is the check worth doing before building anything."
    exit 1
fi

say "  authorized:"
printf '%s\n' "${AUTHORIZED}" | sed 's/^/      /'

WANTED="${KEYCHAIN_ACCESS_GROUP}"
matched=0
while IFS= read -r entry; do
    [ -z "${entry}" ] && continue
    case "${entry}" in
        *\*)
            # A trailing wildcard authorizes any group with that prefix.
            prefix="${entry%\*}"
            case "${WANTED}" in
                "${prefix}"*) ok "\"${entry}\" covers ${WANTED}"; matched=1 ;;
            esac ;;
        "${WANTED}")
            ok "exactly authorized: ${WANTED}"; matched=1 ;;
    esac
done <<EOF
${AUTHORIZED}
EOF

if [ "${matched}" -eq 1 ]; then
    step "Verdict"
    ok "this profile authorizes ${WANTED}"
    say ""
    say "  Next: ./Scripts/test-keychain-integration.sh"
    exit 0
else
    bad "nothing in this profile authorizes ${WANTED}"
    say "       The entitlement would be claimed but not allowlisted, and the"
    say "       process would be killed on launch."
    exit 1
fi
