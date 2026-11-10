#!/bin/bash
#
# Shared credential-health lookup for the installation, backup and migration
# scripts.
#
#   source Scripts/credential-health.sh
#   credential_status <reference>     -> readable | unreadable | not-configured
#   credential_health_source          -> which mechanism answered
#
# WHY THIS EXISTS
#
# These scripts used `security find-generic-password` to ask whether a
# credential was present. That cannot survive the move to the data protection
# Keychain: `/usr/bin/security` operates on the FILE keychain only and has no
# flag to do otherwise. After migration it would keep running and quietly
# report the wrong answer — backup calling every live credential missing, the
# migration skipping everything.
#
# The supported answer comes from the signed application binary, which is the
# only code object that can carry the `keychain-access-groups` entitlement. A
# bare executable cannot, so this deliberately does NOT ask the `vrc` helper.
#
# Nothing here reads a secret value. The app checks presence with `exists`,
# which reads attributes only and never prompts, and reads a value only for
# references that actually have an item behind them.

APP_BINARY="${VRC_APP_BINARY:-/Applications/VacationRentalCalendar.app/Contents/MacOS/VacationRentalCalendar}"
CREDENTIAL_SERVICE="${CREDENTIAL_SERVICE:-com.vacationrentalcalendar.feed-url}"
_VRC_HEALTH_CACHE=""
_VRC_HEALTH_SOURCE=""

_load_credential_health() {
    [ -n "${_VRC_HEALTH_SOURCE}" ] && return 0

    # NEVER probe by running the binary to see what happens. An older build
    # does not recognise --credential-health, ignores it, and LAUNCHES THE
    # GUI — which is exactly what this did on first write: it started a second
    # copy of the installed app and hung the script until it was killed.
    #
    # So support is declared, not discovered. The build writes
    # VRCSupportsCredentialHealth into Info.plist, and this reads that key
    # without executing anything.
    local plist="${APP_BINARY%/Contents/MacOS/*}/Contents/Info.plist"
    local declares=""
    if [ -f "${plist}" ]; then
        declares="$(/usr/libexec/PlistBuddy -c "Print :VRCSupportsCredentialHealth" \
                    "${plist}" 2>/dev/null)"
    fi

    if [ -x "${APP_BINARY}" ] && [ "${declares}" = "true" ]; then
        # Bounded even so: a hung Keychain call must not hang an install.
        _VRC_HEALTH_CACHE="$( "${APP_BINARY}" --credential-health 2>/dev/null & \
                              local pid=$!; ( sleep 30; kill "${pid}" 2>/dev/null ) & \
                              wait "${pid}" 2>/dev/null )"
        if printf '%s' "${_VRC_HEALTH_CACHE}" | grep -q '^summary '; then
            _VRC_HEALTH_SOURCE="app"
            return 0
        fi
    fi

    # The installed app is the supported source. Falling back to `security`
    # keeps these scripts usable before the app is installed, and is correct
    # only while credentials still live in the file keychain — which is why
    # the fallback announces itself rather than pretending to be equivalent.
    _VRC_HEALTH_SOURCE="security"
    return 0
}

credential_health_source() { _load_credential_health; printf '%s' "${_VRC_HEALTH_SOURCE}"; }

# readable | unreadable | not-configured
credential_status() {
    local reference="$1"
    [ -z "${reference}" ] && { printf 'not-configured'; return; }
    _load_credential_health

    if [ "${_VRC_HEALTH_SOURCE}" = "app" ]; then
        local line
        line="$(printf '%s\n' "${_VRC_HEALTH_CACHE}" \
                | awk -v r="${reference}" -F'\t' '$2 == r { print $1; exit }')"
        printf '%s' "${line:-not-configured}"
        return
    fi

    # Legacy path: attributes only, never -w, so it cannot prompt and cannot
    # read a secret. It can only distinguish present from absent, so a present
    # item is reported as readable — which is what the old scripts assumed.
    if security find-generic-password -s "${CREDENTIAL_SERVICE}" -a "${reference}" \
         >/dev/null 2>&1; then
        printf 'readable'
    else
        printf 'not-configured'
    fi
}
