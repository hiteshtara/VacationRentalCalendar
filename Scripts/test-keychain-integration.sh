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
# The probes are real .app BUNDLES, not bare executables. That is not
# cosmetic: `keychain-access-groups` is a restricted entitlement on macOS, a
# signature that merely requests it is killed by AMFI on launch, and the claim
# must be authorised by a provisioning profile — which can only be embedded in
# a bundle, at Contents/embedded.provisionprofile, before signing.
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

PROFILE="${VRC_PROFILE:-Resources/Profiles/vrc-developer-id.provisionprofile}"

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -E "Developer ID Application|Apple Development" | head -1 \
            | sed -E 's/.*"(.*)"/\1/')"

if [ -z "${IDENTITY}" ]; then
    skip "no Apple-issued certificate on this machine"
    printf '\n  Needed: a "Developer ID Application" or "Apple Development" certificate\n'
    printf '  for team %s. See ./Scripts/package-developer-id.sh --preflight\n' "${APPLE_TEAM_ID}"
    printf '\n  === skipped (0 passed, 0 failed) ===\n'
    exit 0
fi
ok "signing identity: ${IDENTITY}"

if [ ! -f "${PROFILE}" ]; then
    skip "no provisioning profile at ${PROFILE}"
    printf '\n'
    printf '  This is a hard requirement, not a convenience. `keychain-access-groups`\n'
    printf '  is a RESTRICTED entitlement on macOS: a signature that only requests it\n'
    printf '  is killed by AMFI the moment the process launches — no error, no log.\n'
    printf '  Verified on this machine on 2026-11-10: unsigned runs, signed without\n'
    printf '  entitlements runs, signed WITH the entitlement is SIGKILLed.\n'
    printf '\n'
    printf '  Create an App ID with Keychain Sharing and a Developer ID profile, then\n'
    printf '  save it as %s\n' "${PROFILE}"
    printf '  Steps: docs/KEYCHAIN-MIGRATION.md\n'
    printf '\n  === skipped (0 passed, 0 failed) ===\n'
    exit 0
fi
ok "provisioning profile: ${PROFILE}"

cat > "${WORK}/entitlements.plist" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>keychain-access-groups</key>
  <array><string>${KEYCHAIN_ACCESS_GROUP}</string></array>
</dict></plist>
XML

# Builds a signed .app bundle around a probe binary.
#   $1 = bundle/executable name, $2 = marker that changes the code hash
build_probe() {
    local name="$1" marker="$2"
    local app="${WORK}/${name}.app"
    rm -rf "${app}"
    mkdir -p "${app}/Contents/MacOS"

    cat > "${app}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>${name}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST

    cat > "${WORK}/${name}.swift" <<SWIFT
import Foundation
import Security
// Marker ${marker}: exists only to make this build's code hash differ from the
// others, which is the entire point of these tests.
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
    swiftc -O "${WORK}/${name}.swift" -o "${app}/Contents/MacOS/${name}" 2>/dev/null || return 1

    # The profile is SEALED by the signature, so it must be in place first.
    cp "${PROFILE}" "${app}/Contents/embedded.provisionprofile" || return 1
    codesign --force --options runtime --timestamp=none \
             --entitlements "${WORK}/entitlements.plist" \
             -s "${IDENTITY}" "${app}" 2>/dev/null || return 1
}

run_probe() { local name="$1"; shift; "${WORK}/${name}.app/Contents/MacOS/${name}" "$@"; }
hash_of() { codesign -dvvv "${WORK}/$1.app" 2>&1 | sed -n 's/^CDHash=//p' | head -1; }

timed() {
    local start end
    start="$(python3 -c 'import time;print(time.time())')"
    OUTPUT="$(run_probe "$@" 2>&1)"
    end="$(python3 -c 'import time;print(time.time())')"
    ELAPSED="$(python3 -c "print(f'{${end}-${start}:.2f}')")"
}

printf '\n\033[1m-- A. Survives a rebuild\033[0m\n'
build_probe writer alpha && build_probe reader omega || { bad "could not build probes"; exit 1; }
[ "$(hash_of writer)" != "$(hash_of reader)" ] \
    && ok "the two builds have different code hashes — a real rebuild" \
    || bad "identical code hashes; the test would prove nothing"
timed writer write
[ "${OUTPUT}" = "0" ] && ok "probe A wrote the item (${ELAPSED}s)" || bad "write failed: ${OUTPUT}"
timed reader read
[ "${OUTPUT}" = "0|match" ] && ok "probe B read what probe A wrote (${ELAPSED}s)" \
    || bad "probe B could not read it: ${OUTPUT}"

printf '\n\033[1m-- B. Ten repeated rebuilds, no prompts\033[0m\n'
slowest=0; failures=0
for i in $(seq 1 10); do
    build_probe "cycle${i}" "rebuild-${i}" || { failures=$((failures+1)); continue; }
    timed "cycle${i}" read
    [ "${OUTPUT}" = "0|match" ] || failures=$((failures+1))
    slowest="$(python3 -c "print(max(${slowest}, ${ELAPSED}))")"
done
[ "${failures}" -eq 0 ] && ok "10 distinct builds all read the same item" \
    || bad "${failures} of 10 rebuilds failed to read"
python3 -c "import sys; sys.exit(0 if ${slowest} < 2 else 1)" \
    && ok "slowest read ${slowest}s — no authorization prompt appeared" \
    || bad "slowest read ${slowest}s — something waited, likely a prompt"

printf '\n\033[1m-- C. Two differently NAMED bundles, as the product has\033[0m\n'
build_probe VacationRentalCalendar gui && build_probe vrc helper || bad "could not build the named pair"
timed VacationRentalCalendar write gui-item
[ "${OUTPUT}" = "0" ] && ok "the GUI-named bundle wrote (${ELAPSED}s)" || bad "GUI write failed: ${OUTPUT}"
timed vrc read gui-item
[ "${OUTPUT}" = "0|match" ] && ok "the helper-named bundle read it (${ELAPSED}s)" \
    || bad "helper could not read the GUI's item: ${OUTPUT}"
timed vrc write helper-item
timed VacationRentalCalendar read helper-item
[ "${OUTPUT}" = "0|match" ] && ok "and the reverse direction works too (${ELAPSED}s)" \
    || bad "GUI could not read the helper's item: ${OUTPUT}"

printf '\n\033[1m-- D. A fresh process after the writer has exited\033[0m\n'
timed reader read
[ "${OUTPUT}" = "0|match" ] && ok "still readable from a new process (${ELAPSED}s)" \
    || bad "not readable from a new process: ${OUTPUT}"
printf '  \033[33mnote\033[0m a full logout or reboot was NOT performed; this covers process\n'
printf '       restart only. kSecAttrAccessibleAfterFirstUnlock covers the reboot\n'
printf '       case and is asserted by unit test.\n'

printf '\n\033[1m-- E. Under CPU load\033[0m\n'
cores="$(sysctl -n hw.ncpu)"
for _ in $(seq 1 "${cores}"); do ( while :; do :; done ) & done
LOADPIDS=$(jobs -p)
timed reader read
LOADRESULT="${OUTPUT}"; LOADTIME="${ELAPSED}"
for pid in ${LOADPIDS}; do kill "${pid}" 2>/dev/null; done
wait 2>/dev/null
[ "${LOADRESULT}" = "0|match" ] && ok "read succeeded with all ${cores} cores saturated (${LOADTIME}s)" \
    || bad "read failed under load: ${LOADRESULT}"
python3 -c "import sys; sys.exit(0 if ${LOADTIME} < 20 else 1)" \
    && ok "well inside the 20s deadline — the 4s bound failed this in production" \
    || bad "took ${LOADTIME}s, at or beyond the deadline"

printf '\n\033[1m-- F. Application update (replace in place)\033[0m\n'
rm -rf "${WORK}/installed.app"; cp -R "${WORK}/writer.app" "${WORK}/installed.app"
mv "${WORK}/installed.app/Contents/MacOS/writer" "${WORK}/installed.app/Contents/MacOS/installed"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable installed" "${WORK}/installed.app/Contents/Info.plist" >/dev/null 2>&1
codesign --force --options runtime --timestamp=none --entitlements "${WORK}/entitlements.plist" \
         -s "${IDENTITY}" "${WORK}/installed.app" 2>/dev/null
timed installed write update-item
[ "${OUTPUT}" = "0" ] && ok "version 1 installed and wrote a credential" || bad "v1 write failed: ${OUTPUT}"
rm -rf "${WORK}/installed.app"; cp -R "${WORK}/reader.app" "${WORK}/installed.app"
mv "${WORK}/installed.app/Contents/MacOS/reader" "${WORK}/installed.app/Contents/MacOS/installed"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable installed" "${WORK}/installed.app/Contents/Info.plist" >/dev/null 2>&1
codesign --force --options runtime --timestamp=none --entitlements "${WORK}/entitlements.plist" \
         -s "${IDENTITY}" "${WORK}/installed.app" 2>/dev/null
timed installed read update-item
[ "${OUTPUT}" = "0|match" ] && ok "version 2 at the same path read it (${ELAPSED}s)" \
    || bad "an update lost the credential: ${OUTPUT}"

printf '\n\033[1m-- Cleanup\033[0m\n'
cleaned=0
for item in probe-item gui-item helper-item update-item; do
    run_probe reader delete "${item}" >/dev/null 2>&1 && cleaned=$((cleaned+1))
done
ok "${cleaned} disposable test items deleted"

printf '\n  === %s passed, %s failed ===\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
