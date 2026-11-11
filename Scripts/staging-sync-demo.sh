#!/bin/bash
#
# End-to-end synchronisation over ACTUAL HTTP, with nothing live in it.
#
#   ./Scripts/staging-sync-demo.sh
#
# Publishes synthetic destination feeds, serves them over real HTTP on
# localhost with token-authenticated paths, fetches them back the way a
# platform would, and checks what arrived.
#
# WHY LOCALHOST AND NOT THE DEPLOYED ENDPOINT
#
# The staging endpoint is live and already serves ical/booking-v1.ics, whose
# grant lives in a Secrets Manager table SHARED with every other grant.
# Adding ours means rewriting that table, and a mistake there takes down a
# calendar a platform may be subscribed to. The HTTP path is identical either
# way -- token in the path, 404 for anything unrecognised, iCalendar bytes on
# success -- so the demonstration runs somewhere it cannot cost anything.
# Publishing to the shared staging table is an approval-gated step.
#
# Nothing here touches AWS, the live database, or any platform.

set -uo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
PORT=8787
trap 'kill %1 2>/dev/null; rm -rf "${WORK}"' EXIT

pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
step(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "1. Publish synthetic destination feeds"
swift run vrc-sync-demo --out "${WORK}" 2>&1 | sed 's/^/  /'
[ -f "${WORK}/manifest.txt" ] || { echo "  no manifest produced"; exit 1; }

AIRBNB_TOKEN="$(awk -F'\t' '$1=="airbnb"{print $2}' "${WORK}/manifest.txt")"
VRBO_TOKEN="$(awk -F'\t' '$1=="vrbo"{print $2}' "${WORK}/manifest.txt")"
[ -n "${AIRBNB_TOKEN}" ] && ok "minted a token per destination" || bad "no tokens minted"

step "2. Serve them over real HTTP, token in the path"
mkdir -p "${WORK}/www"
while IFS=$'\t' read -r dest token key; do
    [ -z "${token}" ] && continue
    cp "${WORK}/${dest}.ics" "${WORK}/www/${token}"
done < "${WORK}/manifest.txt"
( cd "${WORK}/www" && python3 -m http.server "${PORT}" >/dev/null 2>&1 ) &
for _ in $(seq 1 30); do
    curl -s -o /dev/null "http://127.0.0.1:${PORT}/" && break
    sleep 0.2
done
ok "server listening on ${PORT}"

step "3. Fetch as a platform would"
CODE="$(curl -s -o "${WORK}/fetched-airbnb.ics" -w '%{http_code}' \
        "http://127.0.0.1:${PORT}/${AIRBNB_TOKEN}")"
[ "${CODE}" = "200" ] && ok "valid token → HTTP ${CODE}" || bad "valid token → HTTP ${CODE}"
head -1 "${WORK}/fetched-airbnb.ics" | grep -q "BEGIN:VCALENDAR" \
    && ok "bytes on the wire are iCalendar" || bad "not a calendar"

step "4. Invalid and revoked tokens"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/not-a-real-token")"
[ "${CODE}" = "404" ] && ok "invalid token → 404" || bad "invalid token → ${CODE}"

rm -f "${WORK}/www/${VRBO_TOKEN}"       # revocation = the grant stops resolving
CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/${VRBO_TOKEN}")"
[ "${CODE}" = "404" ] && ok "revoked token → 404" || bad "revoked token → ${CODE}"

CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/${AIRBNB_TOKEN}")"
[ "${CODE}" = "200" ] \
    && ok "revoking one token leaves the other serving" \
    || bad "revocation affected an unrelated token (${CODE})"

step "5. What the destination actually received"
swift run vrc-sync-demo --verify "${WORK}/fetched-airbnb.ics" --out "${WORK}" 2>&1 | sed 's/^/  /'
grep -q "VERIFY ok" "${WORK}/verify.txt" 2>/dev/null \
    && ok "imported and attributed by our published UID" \
    || bad "verification failed: $(cat "${WORK}/verify.txt" 2>/dev/null | head -3)"

step "6. Privacy of what left the building"
for secret in "Dana" "BK12345678" "Booking.com" "@booking.com"; do
    if grep -qF "${secret}" "${WORK}/fetched-airbnb.ics"; then
        bad "\"${secret}\" leaked into the published feed"
    else
        ok "no \"${secret}\" in the feed"
    fi
done

step "7. A failed publication leaves the served feed standing"
BEFORE="$(shasum -a 256 < "${WORK}/www/${AIRBNB_TOKEN}")"
swift run vrc-sync-demo --simulate-publish-failure --out "${WORK}" 2>&1 | sed 's/^/  /'
AFTER="$(shasum -a 256 < "${WORK}/www/${AIRBNB_TOKEN}")"
[ "${BEFORE}" = "${AFTER}" ] \
    && ok "the previously published feed is byte-identical" \
    || bad "a failed publication modified the served feed"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/${AIRBNB_TOKEN}")"
[ "${CODE}" = "200" ] && ok "and is still being served" || bad "serving broke (${CODE})"

printf '\n  === %s passed, %s failed ===\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
