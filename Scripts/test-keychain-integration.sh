#!/bin/bash
#
# Proves the data protection Keychain actually survives a rebuild.
#
#   ./Scripts/test-keychain-integration.sh
#
# This is the one claim the unit tests cannot make. They assert the POLICY —
# which keychain, which access group, no ACL — but whether a credential
# written by one build is readable by a DIFFERENT build is a property of
# macOS, not of our code, and only a real signed binary can settle it.
#
# How it works: build a tiny probe, sign it, write an item. Change the probe's
# source so its code hash differs, sign THAT, and read the item back. Under
# the old file-keychain ACL scheme the second read fails — that is the bug
# this whole piece of work exists to remove. Under an access group it should
# succeed.
#
# Isolated by construction: a service name that exists nowhere else in the
# product, a dummy value, and deletion at the end. It cannot see or alter a
# real feed credential, and it reads none.

set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/apple-config.sh

SERVICE="com.vacationrentalcalendar.keychain-integration-test"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

pass=0; fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
skip() { printf '  \033[33mskip\033[0m %s\n' "$*"; }

printf '\033[1m==> Data protection Keychain, across a rebuild\033[0m\n'

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -E "Developer ID Application|Apple Development" | head -1 \
            | sed -E 's/.*"(.*)"/\1/')"

if [ -z "${IDENTITY}" ]; then
    skip "no Apple-issued certificate on this machine"
    printf '\n'
    printf '  This test cannot run without one, and the reason is not a limitation\n'
    printf '  of the test. A probe on 2026-11-10 confirmed that SecItemAdd to the\n'
    printf '  data protection keychain returns -34018 (missing entitlement) from an\n'
    printf '  unsigned binary, with AND without an access group. An entitlement is\n'
    printf '  only honoured when it is signed by a certificate Apple issued.\n'
    printf '\n'
    printf '  Needed: a "Developer ID Application" or "Apple Development" certificate\n'
    printf '  for team %s. See ./Scripts/package-developer-id.sh --preflight\n' "${APPLE_TEAM_ID}"
    printf '\n  === skipped (0 passed, 0 failed) ===\n'
    exit 0
fi
ok "signing identity: ${IDENTITY}"

cat > "${WORK}/entitlements.plist" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>keychain-access-groups</key>
  <array><string>${KEYCHAIN_ACCESS_GROUP}</string></array>
</dict></plist>
XML

# $1 = output name, $2 = a marker that changes the code hash between builds,
# $3 = optional service override (used by the load test to stay isolated).
build_probe() {
    local name="$1" marker="$2"
    cat > "${WORK}/${name}.swift" <<SWIFT
import Foundation
import Security
// Marker ${marker}: present solely to make this build's code hash differ from
// the others, which is the entire point of these tests.
let service = "${SERVICE}"
let group = "${KEYCHAIN_ACCESS_GROUP}"
let account = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "probe-item"
let dummy = "https://example.invalid/not-a-real-credential.ics"
func base() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account,
     kSecAttrAccessGroup as String: group,
     kSecUseDataProtectionKeychain as String: true,
     kSecAttrSynchronizable as String: false,
     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
}
switch CommandLine.arguments.dropFirst().first ?? "" {
case "write":
    var q = base(); q[kSecValueData as String] = Data(dummy.utf8)
    SecItemDelete(base() as CFDictionary)
    print(SecItemAdd(q as CFDictionary, nil))
case "read":
    var q = base()
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &item)
    let value = (item as? Data).flatMap { String(data: \$0, encoding: .utf8) } ?? ""
    print("\(status)|\(value == dummy ? "match" : "mismatch")")
case "delete":
    print(SecItemDelete(base() as CFDictionary))
default: print("usage")
}
SWIFT
    swiftc -O "${WORK}/${name}.swift" -o "${WORK}/${name}" 2>/dev/null || return 1
    codesign --force --options runtime --timestamp=none \
             --entitlements "${WORK}/entitlements.plist" \
             -s "${IDENTITY}" "${WORK}/${name}" 2>/dev/null || return 1
}

hash_of() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -1; }

# A prompt would block indefinitely, so elapsed time is the detector. Anything
# answered in under two seconds cannot have waited for a human.
timed() {
    local start end
    start="$(python3 -c 'import time;print(time.time())')"
    OUTPUT="$("$@" 2>&1)"
    end="$(python3 -c 'import time;print(time.time())')"
    ELAPSED="$(python3 -c "print(f'{${end}-${start}:.2f}')")"
}

printf '\n\033[1m-- A. Survives a rebuild\033[0m\n'
build_probe writer alpha && build_probe reader omega || { bad "could not build probes"; exit 1; }
[ "$(hash_of "${WORK}/writer")" != "$(hash_of "${WORK}/reader")" ] \
    && ok "the two builds have different code hashes — a real rebuild" \
    || bad "identical code hashes; the test would prove nothing"

timed "${WORK}/writer" write
[ "${OUTPUT}" = "0" ] && ok "probe A wrote the item (${ELAPSED}s)" || bad "write failed: ${OUTPUT}"
timed "${WORK}/reader" read
[ "${OUTPUT}" = "0|match" ] && ok "probe B read what probe A wrote (${ELAPSED}s)" \
    || bad "probe B could not read it: ${OUTPUT}"

printf '\n\033[1m-- B. Ten repeated rebuilds, no prompts\033[0m\n'
slowest=0; failures=0
for i in $(seq 1 10); do
    build_probe "cycle${i}" "rebuild-${i}" || { failures=$((failures+1)); continue; }
    timed "${WORK}/cycle${i}" read
    [ "${OUTPUT}" = "0|match" ] || failures=$((failures+1))
    slowest="$(python3 -c "print(max(${slowest}, ${ELAPSED}))")"
done
[ "${failures}" -eq 0 ] && ok "10 distinct builds all read the same item" \
    || bad "${failures} of 10 rebuilds failed to read"
python3 -c "import sys; sys.exit(0 if ${slowest} < 2 else 1)" \
    && ok "slowest read ${slowest}s — no authorization prompt appeared" \
    || bad "slowest read ${slowest}s — something waited, likely a prompt"

printf '\n\033[1m-- C. Two differently NAMED binaries, as the bundle has\033[0m\n'
build_probe VacationRentalCalendar gui && build_probe vrc helper \
    || bad "could not build the named pair"
timed "${WORK}/VacationRentalCalendar" write gui-item
[ "${OUTPUT}" = "0" ] && ok "the GUI-named binary wrote (${ELAPSED}s)" || bad "GUI write failed: ${OUTPUT}"
timed "${WORK}/vrc" read gui-item
[ "${OUTPUT}" = "0|match" ] && ok "the helper-named binary read it (${ELAPSED}s)" \
    || bad "helper could not read the GUI's item: ${OUTPUT}"
timed "${WORK}/vrc" write helper-item
timed "${WORK}/VacationRentalCalendar" read helper-item
[ "${OUTPUT}" = "0|match" ] && ok "and the reverse direction works too (${ELAPSED}s)" \
    || bad "GUI could not read the helper's item: ${OUTPUT}"

printf '\n\033[1m-- D. A fresh process after the writer has exited\033[0m\n'
timed "${WORK}/reader" read
[ "${OUTPUT}" = "0|match" ] && ok "still readable from a new process (${ELAPSED}s)" \
    || bad "not readable from a new process: ${OUTPUT}"
printf '  \033[33mnote\033[0m a full logout or reboot was NOT performed; this covers process\n'
printf '       restart only. kSecAttrAccessibleAfterFirstUnlock is what makes the\n'
printf '       reboot case work, and it is asserted by unit test.\n'

printf '\n\033[1m-- E. Under CPU load\033[0m\n'
cores="$(sysctl -n hw.ncpu)"
for _ in $(seq 1 "${cores}"); do ( while :; do :; done ) & done
LOADPIDS=$(jobs -p)
timed "${WORK}/reader" read
LOADRESULT="${OUTPUT}"; LOADTIME="${ELAPSED}"
for pid in ${LOADPIDS}; do kill "${pid}" 2>/dev/null; done
wait 2>/dev/null
[ "${LOADRESULT}" = "0|match" ] && ok "read succeeded with all ${cores} cores saturated (${LOADTIME}s)" \
    || bad "read failed under load: ${LOADRESULT}"
python3 -c "import sys; sys.exit(0 if ${LOADTIME} < 20 else 1)" \
    && ok "well inside the 20s deadline — the 4s bound failed this in production" \
    || bad "took ${LOADTIME}s, at or beyond the deadline"

printf '\n\033[1m-- F. Application update (replace in place)\033[0m\n'
cp "${WORK}/writer" "${WORK}/installed"
codesign --force --options runtime --timestamp=none --entitlements "${WORK}/entitlements.plist" \
         -s "${IDENTITY}" "${WORK}/installed" 2>/dev/null
timed "${WORK}/installed" write update-item
[ "${OUTPUT}" = "0" ] && ok "version 1 installed and wrote a credential" || bad "v1 write failed"
cp "${WORK}/reader" "${WORK}/installed"
codesign --force --options runtime --timestamp=none --entitlements "${WORK}/entitlements.plist" \
         -s "${IDENTITY}" "${WORK}/installed" 2>/dev/null
timed "${WORK}/installed" read update-item
[ "${OUTPUT}" = "0|match" ] && ok "version 2 at the same path read it (${ELAPSED}s)" \
    || bad "an update lost the credential: ${OUTPUT}"

printf '\n\033[1m-- Cleanup\033[0m\n'
cleaned=0
for item in probe-item gui-item helper-item update-item; do
    "${WORK}/reader" delete "${item}" >/dev/null 2>&1 && cleaned=$((cleaned+1))
done
ok "${cleaned} disposable test items deleted"

printf '\n  === %s passed, %s failed ===\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
