#!/bin/bash
#
# Tests Scripts/inspect-provisioning-profile.sh against fabricated profiles.
#
# The inspector exists to answer one question before anything is built: does
# this profile authorize our Keychain access group? A false PASS there would
# send us straight back into the AMFI kill it is meant to prevent, so its
# matching logic is tested against profiles that should pass and profiles that
# should not.

set -uo pipefail
cd "$(dirname "$0")/.."
INSPECT="$(pwd)/Scripts/inspect-provisioning-profile.sh"

pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# $1 = file, $2 = team, $3... = authorized groups (omit for none)
make_profile() {
    local out="$1" team="$2"; shift 2
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>\n'
        printf '  <key>Name</key><string>Test Profile</string>\n'
        printf '  <key>AppIDName</key><string>Vacation Rental Calendar</string>\n'
        printf '  <key>TeamName</key><string>hitesh tara</string>\n'
        printf '  <key>Platform</key><array><string>OSX</string></array>\n'
        printf '  <key>CreationDate</key><date>2026-11-10T00:00:00Z</date>\n'
        printf '  <key>ExpirationDate</key><date>2027-11-10T00:00:00Z</date>\n'
        printf '  <key>ProvisionsAllDevices</key><true/>\n'
        printf '  <key>TeamIdentifier</key><array><string>%s</string></array>\n' "${team}"
        printf '  <key>Entitlements</key><dict>\n'
        printf '    <key>application-identifier</key><string>%s.com.vacationrentalcalendar.app</string>\n' "${team}"
        if [ "$#" -gt 0 ]; then
            printf '    <key>keychain-access-groups</key><array>\n'
            for g in "$@"; do printf '      <string>%s</string>\n' "${g}"; done
            printf '    </array>\n'
        fi
        printf '  </dict>\n</dict></plist>\n'
    } > "${out}"
}

verdict() { VRC_PROFILE_PLIST="$1" "${INSPECT}" >/dev/null 2>&1; echo $?; }

printf '\033[1m==> Profiles that SHOULD authorize our group\033[0m\n'

make_profile "${WORK}/wildcard.plist" 26JLFSV9YS "26JLFSV9YS.*"
[ "$(verdict "${WORK}/wildcard.plist")" = "0" ] \
    && ok "a TEAMID.* wildcard covers our group" \
    || bad "the wildcard case was rejected — this is what Apple actually issues"

make_profile "${WORK}/exact.plist" 26JLFSV9YS "26JLFSV9YS.com.vacationrentalcalendar.shared"
[ "$(verdict "${WORK}/exact.plist")" = "0" ] \
    && ok "an exactly-matching group is accepted" || bad "exact match rejected"

make_profile "${WORK}/multi.plist" 26JLFSV9YS "26JLFSV9YS.com.something.else" "26JLFSV9YS.*"
[ "$(verdict "${WORK}/multi.plist")" = "0" ] \
    && ok "a wildcard alongside unrelated groups still counts" || bad "multi-entry case rejected"

printf '\n\033[1m==> Profiles that must NOT be accepted\033[0m\n'

make_profile "${WORK}/none.plist" 26JLFSV9YS
[ "$(verdict "${WORK}/none.plist")" != "0" ] \
    && ok "a profile authorizing no keychain groups is rejected" \
    || bad "a profile with NO keychain-access-groups was accepted"

make_profile "${WORK}/other.plist" 26JLFSV9YS "26JLFSV9YS.com.unrelated.group"
[ "$(verdict "${WORK}/other.plist")" != "0" ] \
    && ok "an unrelated group does not count as authorization" \
    || bad "an unrelated group was accepted"

# The dangerous near-miss: another team's wildcard. Prefix matching on the
# string alone would wrongly accept it if the team digits happened to align.
make_profile "${WORK}/wrongteam.plist" ABCDE12345 "ABCDE12345.*"
[ "$(verdict "${WORK}/wrongteam.plist")" != "0" ] \
    && ok "another team's wildcard is rejected" || bad "another team's wildcard was accepted"

# A wildcard that is a prefix of our team but not our team: 26JLFSV9Y vs
# 26JLFSV9YS. Sloppy matching would accept this.
make_profile "${WORK}/nearmiss.plist" 26JLFSV9YS "26JLFSV9Y.*"
[ "$(verdict "${WORK}/nearmiss.plist")" != "0" ] \
    && ok "a near-miss team prefix is rejected" \
    || bad "a shorter team prefix was wrongly accepted"

printf '\n  === %s passed, %s failed ===\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
