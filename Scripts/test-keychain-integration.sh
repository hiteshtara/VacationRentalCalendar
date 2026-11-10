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

# $1 = output name, $2 = a marker that changes the code hash between builds.
build_probe() {
    local name="$1" marker="$2"
    cat > "${WORK}/${name}.swift" <<SWIFT
import Foundation
import Security
// Marker ${marker}: present solely to make this build's code hash differ from
// the other one, which is the entire point of the test.
let service = "${SERVICE}"
let group = "${KEYCHAIN_ACCESS_GROUP}"
let account = "probe-item"
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

build_probe writer "alpha" && ok "built and signed probe A" || { bad "could not build probe A"; exit 1; }
build_probe reader "omega" && ok "built and signed probe B" || { bad "could not build probe B"; exit 1; }

HASH_A="$(codesign -dvvv "${WORK}/writer" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
HASH_B="$(codesign -dvvv "${WORK}/reader" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
if [ "${HASH_A}" != "${HASH_B}" ]; then
    ok "the two builds have different code hashes — a real rebuild"
else
    bad "identical code hashes; the test would prove nothing"
fi

WRITE="$("${WORK}/writer" write 2>&1)"
[ "${WRITE}" = "0" ] && ok "probe A wrote the item" \
    || { bad "probe A could not write (OSStatus ${WRITE})"; "${WORK}/writer" delete >/dev/null 2>&1; }

READ="$("${WORK}/reader" read 2>&1)"
if [ "${READ}" = "0|match" ]; then
    ok "probe B read the item written by probe A — survives a rebuild"
else
    bad "probe B could not read it (${READ}) — the access group is not working"
fi

DEL="$("${WORK}/reader" delete 2>&1)"
[ "${DEL}" = "0" ] && ok "test item deleted" || bad "cleanup failed (OSStatus ${DEL})"

printf '\n  === %s passed, %s failed ===\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
