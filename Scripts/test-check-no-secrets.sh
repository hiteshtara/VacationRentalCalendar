#!/bin/bash
#
# Tests for Scripts/check-no-secrets.sh.
#
# The scanner gained one exemption — AWS's published SigV4 documentation
# example key — and an exemption in a security gate is exactly the kind of
# change that must be proved not to have opened a hole. These tests exist to
# show that it did not.
#
#   ./Scripts/test-check-no-secrets.sh
#
# Each case builds a throwaway git repository, drops the scanner into it, puts
# one synthetic string in a file, and asserts the scanner's verdict. Nothing
# here is a real credential: the AKIA-shaped values are invented, and the feed
# URLs are obvious fakes. See the assembly note below for why none of them is
# written out literally.

set -uo pipefail
cd "$(dirname "$0")/.."
SCANNER="$(pwd)/Scripts/check-no-secrets.sh"

pass=0; fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }

# Every fixture is ASSEMBLED from fragments rather than written out, so this
# file does not itself trip the scanner it is testing.
#
# That is not a style choice. A test for a secret scanner must contain strings
# shaped like secrets, and a literal one turns the gate permanently red against
# its own test suite — then gets committed, and the history scan carries it
# forever. The AKIA fixtures below were assembled for exactly that reason and
# the other five were not, which made the scanner report its own tests from the
# moment they landed. Each split point is chosen so that neither half matches
# the pattern alone; the strings handed to the scanner are unchanged.
#
# None of these is a credential: the hex runs are 0123456789…, the key block has
# no key in it, and "Dana" is not a guest.
DOC_EXAMPLE="$(printf '%s%s' 'AKIA' 'IOSFODNN7EXAMPLE')"
OTHER_AKIA="$(printf '%s%s' 'AKIA' 'QQQQWWWWEEEERRRR')"
OTHER_ASIA="$(printf '%s%s' 'ASIA' 'ZZZZXXXXCCCCVVVV')"

# Split before the token: the prefix alone has no 16-hex query parameter.
FAKE_AIRBNB_URL="$(printf '%s%s' 'https://www.airbnb.com/calendar/ical/12345.ics?t=' '0123456789abcdef')"
# Split before the id: the prefix alone has no 24-hex path segment.
FAKE_VRBO_URL="$(printf '%s%s' 'https://www.vrbo.com/icalendar/' '0123456789abcdef01234567')"
# Split before the token: the prefix alone has no 30-character token.
FAKE_BOOKING_URL="$(printf '%s%s' 'https://ical.booking.com/v1/export?t=' '0123456789-abcdef-0123456789abcd')"
# Split mid-phrase: "-----BEGIN [A-Z ]*PRIVATE KEY-----" needs both halves.
FAKE_KEY_BLOCK="$(printf '%s%s' '-----BEGIN RSA ' 'PRIVATE KEY-----')"
# Split after the quote: the pattern requires a capital letter following it.
FAKE_GUEST_NAME="$(printf '%s%s' 'guestName = "' 'Dana"')"

# Runs the scanner over a repo containing exactly `content`, and echoes its
# exit code. 0 means clean.
verdict() {
    local content="$1" tmp
    tmp="$(mktemp -d)"
    mkdir -p "${tmp}/Scripts"
    cp "${SCANNER}" "${tmp}/Scripts/check-no-secrets.sh"
    printf '%s\n' "${content}" > "${tmp}/sample.txt"
    (
        cd "${tmp}" || exit 99
        git init -q . 2>/dev/null
        git config user.email t@t; git config user.name t
        git add -A 2>/dev/null
        git commit -qm "fixture" 2>/dev/null
        ./Scripts/check-no-secrets.sh >/dev/null 2>&1
        echo $?
    )
    rm -rf "${tmp}"
}

expect() {
    local label="$1" content="$2" want="$3"
    local got; got="$(verdict "${content}" | tail -1)"
    if [ "${got}" = "${want}" ]; then ok "${label}"
    else bad "${label} — scanner exited ${got}, expected ${want}"; fi
}

printf '\033[1m==> Secret scanner behaviour\033[0m\n'

# 1. The documented example is allowed — the whole point of the exemption.
expect "AWS's documented example key is allowed" \
       "let key = \"${DOC_EXAMPLE}\"" 0

# 2. Any other key of the same shape is still rejected. If this ever passes,
#    the exemption has become a pattern relaxation and must be reverted.
expect "a different AKIA-shaped string is still rejected" \
       "let key = \"${OTHER_AKIA}\"" 1
expect "an ASIA-shaped string is still rejected" \
       "let key = \"${OTHER_ASIA}\"" 1

# 3. The exemption must not be a suffix rule. A made-up key that merely ENDS in
#    EXAMPLE is not the documented value and must still be caught.
expect "a different key ending in EXAMPLE is still rejected" \
       "let key = \"$(printf '%s%s' 'AKIA' 'ZZZZZZZZZEXAMPLE')\"" 1

# 4. The exemption must not be usable to smuggle a real credential through by
#    putting it beside the example. Only the exact token is removed; whatever
#    shares the line is still scanned.
expect "a real-shaped key hiding beside the example is still caught" \
       "example=${DOC_EXAMPLE} real=${OTHER_AKIA}" 1

# 5. Private calendar URLs are untouched by any of this.
expect "an Airbnb export URL is still rejected" \
       "${FAKE_AIRBNB_URL}" 1
expect "a Vrbo export URL is still rejected" \
       "${FAKE_VRBO_URL}" 1
expect "a Booking.com export URL is still rejected" \
       "${FAKE_BOOKING_URL}" 1

# 6. The other credential shapes still fire.
expect "a private key block is still rejected" \
       "${FAKE_KEY_BLOCK}" 1
expect "guest data is still rejected" \
       "${FAKE_GUEST_NAME}" 1

# 7. And a file with nothing sensitive is clean, so the suite can fail.
expect "ordinary content is clean" "let greeting = \"hello\"" 0

printf '\n  === %s passed, %s failed ===\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
