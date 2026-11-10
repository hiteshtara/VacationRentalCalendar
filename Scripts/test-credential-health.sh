#!/bin/bash
#
# Tests Scripts/credential-health.sh.
#
# The case that matters most is negative: the lookup must NEVER execute an
# application binary that has not declared support for --credential-health. An
# earlier version probed by running it, and on a build that ignores the flag
# that launches the GUI — it started a second copy of the installed app and
# hung the calling script until it was killed.

set -uo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; trap 'rm -rf "${ROOT}"' EXIT
MARKER="${ROOT}/was-executed"

# A stand-in for the app: records that it ran, and answers the flag.
make_app() {
    local declares="$1"
    local app="${ROOT}/Test.app"
    rm -rf "${app}"; mkdir -p "${app}/Contents/MacOS"
    cat > "${app}/Contents/Info.plist" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>test</string>
${declares}
</dict></plist>
XML
    cat > "${app}/Contents/MacOS/Test" <<'STUB'
#!/bin/bash
touch "${MARKER}"
printf 'store test\n'
printf 'readable\tairbnb-v6\tAirbnb\n'
printf 'unreadable\tbooking-v3\tBooking.com\n'
printf 'not-configured\tvrbo-p2\tVrbo — Test Cottage\n'
printf 'summary readable=1 unreadable=1 notConfigured=1\n'
STUB
    chmod +x "${app}/Contents/MacOS/Test"
    printf '%s' "${app}/Contents/MacOS/Test"
}

printf '\033[1m==> A binary that does NOT declare support is never executed\033[0m\n'
rm -f "${MARKER}"
BIN="$(make_app '')"
( export MARKER; export VRC_APP_BINARY="${BIN}"
  source Scripts/credential-health.sh
  credential_status airbnb-v6 >/dev/null )
[ -f "${MARKER}" ] && bad "the undeclared binary WAS executed — this is the GUI-launch bug" \
                   || ok "the undeclared binary was not executed"

( export VRC_APP_BINARY="${BIN}"
  source Scripts/credential-health.sh
  [ "$(credential_health_source)" = "security" ] ) \
    && ok "it falls back to the legacy lookup and says so" \
    || bad "the fallback did not announce itself"

printf '\n\033[1m==> A binary that DOES declare support is used\033[0m\n'
rm -f "${MARKER}"
BIN="$(make_app '  <key>VRCSupportsCredentialHealth</key><true/>')"
RESULT="$( export MARKER; export VRC_APP_BINARY="${BIN}"
           source Scripts/credential-health.sh
           printf '%s|%s|%s|%s' "$(credential_health_source)" \
             "$(credential_status airbnb-v6)" \
             "$(credential_status booking-v3)" \
             "$(credential_status vrbo-p2)" )"
[ -f "${MARKER}" ] && ok "the declaring binary was executed" || bad "it was not executed"
[ "${RESULT}" = "app|readable|unreadable|not-configured" ] \
    && ok "readable, unreadable and not-configured are each reported distinctly" \
    || bad "wrong statuses: ${RESULT}"

printf '\n\033[1m==> Unknown references\033[0m\n'
( export MARKER; export VRC_APP_BINARY="${BIN}"
  source Scripts/credential-health.sh
  [ "$(credential_status never-heard-of-it)" = "not-configured" ] ) \
    && ok "a reference the app did not mention is not-configured" \
    || bad "unknown reference mishandled"
( export MARKER; export VRC_APP_BINARY="${BIN}"
  source Scripts/credential-health.sh
  [ "$(credential_status "")" = "not-configured" ] ) \
    && ok "an empty reference is not-configured, not an error" \
    || bad "empty reference mishandled"

printf '\n  === %s passed, %s failed ===\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
