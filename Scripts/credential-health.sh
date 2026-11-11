#!/bin/bash
#
# Shared credential-presence lookup for the installation, backup and migration
# scripts.
#
#   source Scripts/credential-health.sh
#   credential_status <reference>  -> present | unverified | not-configured
#   credential_health_source       -> which mechanism answered
#
# THIS SCRIPT NEVER READS A CREDENTIAL VALUE, AND NEVER EXECUTES THE APP.
#
# It used to do both, and the damage is worth recording. An earlier version
# preferred "the supported source", which meant launching
# `VacationRentalCalendar --credential-health` and letting the signed app read
# every credential in process. Reading a value requires Keychain
# authorization. On 2026-11-10 at 23:05 a backup did exactly that while the
# running app's hourly refresh fired; two code objects asked for authorization
# on the same items in the same second; two reads came back -128; and the
# import path latched `credentialUnreadable` on Airbnb and Vrbo, which is
# never retried. A backup — an operation whose entire purpose is to be safe to
# run — permanently disconnected two live calendars.
#
# So the rules here are absolute, and the tests in test-credential-health.sh
# enforce them:
#
#   * never execute the app bundle or the `vrc` helper, for any reason;
#   * never pass -w to `security`, which is what reads a secret;
#   * only ever ask whether an item EXISTS, which reads attributes and cannot
#     prompt;
#   * never silently substitute a weaker check for a stronger one — where
#     presence cannot be established, say so.
#
# WHAT THIS CANNOT DO, AND SAYS SO
#
# `/usr/bin/security` operates on the file keychain only and has no flag to do
# otherwise, so it cannot see data protection Keychain items. There is no
# command-line tool that can: reaching them needs the `keychain-access-groups`
# entitlement, which only the signed application carries — and asking the
# application is precisely what caused the incident above.
#
# Therefore, when the installed build is one that would use the data
# protection Keychain, this reports `unverified` rather than guessing. An
# unverifiable answer is strictly better than a confident wrong one: a backup
# that reports `not-configured` for six live credentials looks like data loss,
# and one that reports them readable by reading them is the bug that caused
# this file to be rewritten.

APP_BUNDLE="${VRC_APP_BUNDLE:-/Applications/VacationRentalCalendar.app}"
CREDENTIAL_SERVICE="${CREDENTIAL_SERVICE:-com.vacationrentalcalendar.feed-url}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-26JLFSV9YS}"
_VRC_HEALTH_SOURCE=""

# Which Keychain the INSTALLED build would use, decided by inspecting its
# signature rather than running it. `CredentialStoreSelection` selects the data
# protection Keychain only when the running code is signed by the team, so the
# same question is answered here with codesign, which executes nothing.
_vrc_detect_keychain() {
    [ -n "${_VRC_HEALTH_SOURCE}" ] && return 0

    if [ "${VRC_FORCE_HEALTH_SOURCE:-}" != "" ]; then
        _VRC_HEALTH_SOURCE="${VRC_FORCE_HEALTH_SOURCE}"
        return 0
    fi

    local team=""
    if [ -d "${APP_BUNDLE}" ]; then
        team="$(codesign -dvvv "${APP_BUNDLE}" 2>&1 \
                | awk -F'=' '/^TeamIdentifier=/ { print $2; exit }')"
    fi

    if [ "${team}" = "${APPLE_TEAM_ID}" ]; then
        # A team-signed build uses the data protection Keychain, which no
        # command-line tool can inspect. Say so instead of guessing.
        _VRC_HEALTH_SOURCE="unverifiable"
    else
        _VRC_HEALTH_SOURCE="security"
    fi
    return 0
}

credential_health_source() { _vrc_detect_keychain; printf '%s' "${_VRC_HEALTH_SOURCE}"; }

# present | unverified | not-configured
#
# `present` deliberately does NOT claim readable. Whether this code object is
# allowed to read a value can only be learned by reading it, and that is the
# thing this script must not do.
credential_status() {
    local reference="$1"
    [ -z "${reference}" ] && { printf 'not-configured'; return; }
    _vrc_detect_keychain

    if [ "${_VRC_HEALTH_SOURCE}" = "unverifiable" ]; then
        printf 'unverified'
        return
    fi

    # Attributes only. No -w, so no secret is read, no authorization is
    # requested, and no dialog can appear.
    if security find-generic-password -s "${CREDENTIAL_SERVICE}" -a "${reference}" \
         >/dev/null 2>&1; then
        printf 'present'
    else
        printf 'not-configured'
    fi
}

# A sentence for the manifest, so a reader knows what the statuses mean.
credential_health_caveat() {
    _vrc_detect_keychain
    case "${_VRC_HEALTH_SOURCE}" in
        unverifiable)
            printf '%s' "presence NOT verified: the installed build uses the data protection Keychain, which no command-line tool can inspect. Nothing was read."
            ;;
        *)
            printf '%s' "presence only, from Keychain item attributes. No value was read and no authorization was requested, so this does not prove readability."
            ;;
    esac
}
