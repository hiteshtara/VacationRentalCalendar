#!/bin/bash
#
# Scans for credentials and reservation data before they reach a public
# repository.
#
#   ./Scripts/check-no-secrets.sh            working tree + full history
#   ./Scripts/check-no-secrets.sh --staged   only what is about to be committed
#
# This repository is public by choice, which makes the boundary permanent
# rather than a one-off audit: the architecture, the schema and the code are
# meant to be readable; the feed URLs, the AWS keys, the guest data and the
# SQLite database are not.
#
# Useful as a pre-push hook:
#   ln -s ../../Scripts/check-no-secrets.sh .git/hooks/pre-push

set -uo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-all}"
found=0

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFOUND\033[0m %s\n' "$*"; found=$((found+1)); }

# Portable SHA-256 of stdin. macOS ships `shasum`, Linux `sha256sum`.
digest() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256
    else sha256sum
    fi | awk '{print $1}'
}

# The historical baseline.
#
# Five synthetic fixtures were committed in d262eda, inside this scanner's own
# test file, and that commit is already on a public remote. Rewriting it would
# mean a force-push; leaving it means a gate that always fails, which is worse
# than no gate because people stop reading it.
#
# The baseline records the SHA-256 of each KNOWN match, so those exact strings
# are accepted in history and nothing else is. It is deliberately not a path
# exemption: skipping the fixture file wholesale would blind the scan to a real
# credential committed to that path later. A new finding — in any file, of any
# pattern, including a different value of the same SHAPE — hashes differently
# and still fails.
#
# The file stores hashes, never the strings, so it does not itself contain the
# values it is describing.
BASELINE_FILE="Scripts/secret-history-baseline.txt"

is_baselined() {
    [ -f "${BASELINE_FILE}" ] || return 1
    LC_ALL=C grep -qiE "^$1([[:space:]]|$)" "${BASELINE_FILE}" 2>/dev/null
}

# Patterns are shapes, not values, so this file carries no secret itself.
#
# `--` because a pattern starting with "-" (the private key block) would
# otherwise be parsed as options, which silently matched nothing for as long as
# that pattern had existed. LC_ALL=C because history blobs are binary and a
# UTF-8 locale makes grep and sed refuse the input entirely.
scan() {
    local label="$1" pattern="$2" target="$3" allow_baseline="${4:-no}"
    local matches unknown=0 known=0 line hash
    # -a because history blobs are binary: without it grep prints
    # "Binary file matches" instead of the matches, and -o yields nothing.
    # That silently emptied this scan the first time it was written.
    matches=$(printf '%s' "${target}" | LC_ALL=C grep -aoE -- "${pattern}" 2>/dev/null | sort -u || true)
    [ -z "${matches}" ] && return 0

    while IFS= read -r line; do
        [ -z "${line}" ] && continue
        hash=$(printf '%s' "${line}" | digest)
        if [ "${allow_baseline}" = "yes" ] && is_baselined "${hash}"; then
            known=$((known+1))
            continue
        fi
        unknown=$((unknown+1))
    done <<EOF
${matches}
EOF

    if [ "${unknown}" -gt 0 ]; then
        bad "${label} (${unknown} occurrence(s))"
    elif [ "${known}" -gt 0 ]; then
        printf '  \033[33mbaselined\033[0m %s (%s known historical match(es))\n' "${label}" "${known}"
    fi
}


# The one exemption, and the reasoning for it.
#
# AWS publishes a fixed example access key id throughout its SigV4
# documentation. It is not a credential, has never belonged to any account, and
# appears in this repository's signing tests and in one commit message. Without
# an exemption the history scan fails permanently, and a gate that always fails
# is a gate people stop reading.
#
# The exemption is deliberately the narrowest possible: ONE exact 20-character
# value, removed by literal string substitution. It is NOT a rule about the
# suffix "EXAMPLE", NOT a relaxation of the pattern, and NOT a per-file
# allowlist. Any other AKIA/ASIA-shaped string — including one sharing a line
# with the example — still matches, because only the exact token is removed and
# everything around it is left intact.
#
# The value is assembled from two pieces so that this file does not itself
# contain the 20-character token, which would otherwise make the scanner report
# its own source.
documented_example_key() { printf '%s%s' 'AKIA' 'IOSFODNN7EXAMPLE'; }

without_documented_example() {
    local filtered
    # LC_ALL=C: history blobs are binary, and a UTF-8 locale makes macOS sed
    # abort with "illegal byte sequence" and emit NOTHING — which would hand
    # back empty content and silently disable this check. That is precisely
    # the hole an exemption must not open, so the result is validated below.
    filtered="$(printf '%s' "$1" | LC_ALL=C sed "s/$(documented_example_key)//g")"
    # Fail closed: if filtering produced nothing from non-empty input, the
    # exemption is not working and the UNFILTERED content is scanned instead.
    # A false positive is recoverable; a false negative is not.
    if [ -n "$1" ] && [ -z "${filtered}" ]; then
        printf '%s' "$1"
    else
        printf '%s' "${filtered}"
    fi
}

patterns() {
    local content="$1" allow_baseline="${2:-no}"
    scan "Airbnb iCal export URL"   'airbnb\.com/calendar/ical/[0-9]+\.ics\?t=[0-9a-f]{16}' "${content}" "${allow_baseline}"
    scan "Vrbo iCal export URL"     'vrbo\.com/icalendar/[0-9a-f]{24}' "${content}" "${allow_baseline}"
    scan "Booking.com iCal export"  'ical\.booking\.com/v1/export\?t=[0-9a-f-]{30}' "${content}" "${allow_baseline}"
    scan "AWS access key id"        '\b(AKIA|ASIA)[0-9A-Z]{16}\b' "$(without_documented_example "${content}")" "${allow_baseline}"
    scan "AWS secret access key"    'aws_secret_access_key[[:space:]]*[=:]' "${content}" "${allow_baseline}"
    scan "private key block"        '-----BEGIN [A-Z ]*PRIVATE KEY-----' "${content}" "${allow_baseline}"
    scan "guest email"              'guestEmail[[:space:]]*[=:][[:space:]]*"[^"]+@' "${content}" "${allow_baseline}"
    scan "guest name"               'guestName[[:space:]]*[=:][[:space:]]*"[A-Z]' "${content}" "${allow_baseline}"
}

step "1. Files that must never be committed"
for forbidden in "*.sqlite" "*.sqlite-wal" "*.sqlite-shm" "*.tfstate" "*.tfvars.local" \
                 "*.p12" "*.pem" "id_rsa"; do
    tracked=$(git ls-files -- "${forbidden}" 2>/dev/null | head -3)
    if [ -n "${tracked}" ]; then
        bad "${forbidden} is tracked: ${tracked}"
    fi
done
[ "${found}" -eq 0 ] && ok "no database, state or key files tracked"

step "2. Content"
if [ "${MODE}" = "--staged" ]; then
    say "  scanning staged changes only"
    patterns "$(git diff --cached 2>/dev/null)"
else
    say "  scanning the working tree"
    patterns "$(git ls-files -z 2>/dev/null | xargs -0 cat 2>/dev/null)"

    step "3. Full history"
    say "  every blob in every commit"
    objects=$(git rev-list --all --objects 2>/dev/null | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
    say "  ${objects} objects"
    history=$(git rev-list --all --objects 2>/dev/null | awk '{print $1}' | sort -u \
              | git cat-file --batch 2>/dev/null)
    # The working tree above is scanned with NO baseline: it must be clean.
    patterns "${history}" "yes"
fi

step "Result"
if [ "${found}" -eq 0 ]; then
    printf '  \033[32mclean\033[0m — no credentials or guest data found.\n'
    say ""
    say "  What IS public, and is meant to be: the architecture, the schema,"
    say "  the business rules, the property address and the platform listing"
    say "  ids. Those identify a listing that is already advertised publicly."
    exit 0
fi
printf '  \033[31m%s finding(s)\033[0m — do not push.\n' "${found}"
say ""
say "  A credential that reached a public commit is compromised even after it"
say "  is removed: rewrite is not revocation. Rotate it at the platform first,"
say "  then clean the history."
exit 1
