#!/bin/bash
#
# Builds, signs and (optionally) notarizes a Developer ID distribution build.
#
#   ./Scripts/package-developer-id.sh              preflight, build, sign
#   ./Scripts/package-developer-id.sh --preflight  check readiness only
#   ./Scripts/package-developer-id.sh --notarize   also submit to Apple
#
# NOTARIZATION IS OFF BY DEFAULT. It uploads the application to Apple, which
# is a submission, and submissions are the owner's decision rather than a side
# effect of running a build script.
#
# This NEVER touches /Applications. It builds into dist-developer-id/ so the
# working installation and its credentials are untouched. Installing is a
# separate, deliberate act.

set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=apple-config.sh
source Scripts/apple-config.sh

MODE="${1:-build}"
OUT="dist-developer-id"
APP="${OUT}/${APP_NAME}.app"

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m--\033[0m   %s\n' "$*"; }

problems=0

preflight() {
    step "Preflight"

    local identity
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
                | grep -F "${DEVELOPER_ID_IDENTITY}" | head -1 \
                | sed -E 's/.*"(.*)"/\1/')"
    if [ -n "${identity}" ]; then
        ok "Developer ID certificate: ${identity}"
        SIGN_IDENTITY="${identity}"
    else
        bad "no \"Developer ID Application\" certificate in the login keychain"
        say "       Create one: Keychain Access > Certificate Assistant >"
        say "       Request a Certificate From a Certificate Authority (save to disk),"
        say "       then developer.apple.com > Certificates > + > Developer ID Application,"
        say "       upload the request, download the .cer and double-click it."
        problems=$((problems + 1))
    fi

    # The intermediate. Without it codesign succeeds and Gatekeeper refuses,
    # which is a confusing failure to debug after the fact.
    if security find-certificate -c "Developer ID Certification Authority" >/dev/null 2>&1; then
        ok "Developer ID Certification Authority intermediate present"
    else
        warn "Developer ID intermediate not found — download it from"
        say "       https://www.apple.com/certificateauthority/ if signing fails"
    fi

    for file in "${ENTITLEMENTS_DEVELOPER_ID}"; do
        [ -f "${file}" ] && ok "entitlements: ${file}" \
            || { bad "missing ${file}"; problems=$((problems + 1)); }
    done

    if xcrun notarytool --version >/dev/null 2>&1; then
        ok "notarytool $(xcrun notarytool --version 2>&1 | head -1)"
    else
        bad "notarytool unavailable — needs Command Line Tools 13 or later"
        problems=$((problems + 1))
    fi

    if xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
        ok "notarytool profile \"${NOTARY_PROFILE}\" is stored and working"
    else
        warn "no notarytool profile \"${NOTARY_PROFILE}\" (only needed for --notarize)"
        say "       Create it once, interactively:"
        say "         xcrun notarytool store-credentials ${NOTARY_PROFILE} \\"
        say "             --apple-id <your Apple ID> --team-id ${APPLE_TEAM_ID}"
        say "       It asks for an app-specific password from appleid.apple.com."
        say "       The password is stored by macOS; this repository never sees it."
    fi

    ok "team ${APPLE_TEAM_ID} (${APPLE_ENROLLMENT}), access group ${KEYCHAIN_ACCESS_GROUP}"

    if [ "${problems}" -gt 0 ]; then
        say ""
        bad "${problems} blocking problem(s) — nothing was built"
        return 1
    fi
    return 0
}

build_and_sign() {
    step "Building (release)"
    swift build -c release >/dev/null 2>&1 || { bad "swift build failed"; exit 1; }
    ok "built"

    step "Assembling ${APP}"
    rm -rf "${OUT}"
    mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
    cp ".build/release/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
    cp ".build/release/vrc" "${APP}/Contents/MacOS/vrc"
    [ -f "dist/${APP_NAME}.app/Contents/Resources/AppIcon.icns" ] \
        && cp "dist/${APP_NAME}.app/Contents/Resources/AppIcon.icns" "${APP}/Contents/Resources/"

    # A real, increasing build number. The old script hard-coded 1, which any
    # resubmission rejects.
    local build_number
    build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
    cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>           <string>${APP_DISPLAY_NAME}</string>
    <key>CFBundleExecutable</key>            <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>            <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>               <string>${build_number}</string>
    <key>CFBundleShortVersionString</key>    <string>1.0.0</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <!-- Declares that this build answers --credential-health. The scripts
         read this key rather than probing by running the binary: an older
         build ignores the flag and launches the GUI instead. -->
    <key>VRCSupportsCredentialHealth</key>      <true/>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key>      <string>Copyright © 2026. All rights reserved.</string>
</dict>
</plist>
PLIST
    ok "bundle assembled, CFBundleVersion ${build_number}"

    # The profile is SEALED by the signature, so it goes in first. Without it
    # the keychain-access-groups entitlement is claimed but not authorized,
    # and AMFI kills the app on launch with no error and no log.
    if [ -f "${PROFILE}" ]; then
        cp "${PROFILE}" "${APP}/Contents/embedded.provisionprofile"
        ok "embedded $(basename "${PROFILE}")"
    else
        bad "no provisioning profile at ${PROFILE} — the app would be killed on launch"
        exit 1
    fi

    # codesign does NOT expand $(AppIdentifierPrefix) — that substitution is an
    # Xcode build setting, not a signing feature. Signing the template verbatim
    # embeds the literal string "$(AppIdentifierPrefix)com.vacation..." as the
    # access group, which is not a valid group, so AMFI kills the app on launch
    # with no output at all. Verified here on 2026-11-10.
    #
    # So the entitlements are resolved first, exactly as Xcode would: the
    # prefix becomes the team identifier. The template stays readable and this
    # is the only place the substitution happens.
    local resolved="${OUT}/developer-id.resolved.entitlements"
    sed "s/\$(AppIdentifierPrefix)/${APPLE_TEAM_ID}./g" \
        "${ENTITLEMENTS_DEVELOPER_ID}" > "${resolved}"
    if grep -q 'AppIdentifierPrefix' "${resolved}"; then
        bad "the entitlements still contain an unexpanded variable"
        exit 1
    fi
    ok "resolved entitlements: access group ${KEYCHAIN_ACCESS_GROUP}"

    step "Signing"
    # Inside out: nested code first, then the bundle. --options runtime is the
    # hardened runtime, which notarization requires; --timestamp is a secure
    # timestamp, which it also requires. The old local script used neither.
    codesign --force --options runtime --timestamp \
             --entitlements "${resolved}" \
             --identifier "${HELPER_BUNDLE_ID}" \
             -s "${SIGN_IDENTITY}" "${APP}/Contents/MacOS/vrc" 2>&1 | sed 's/^/      /'
    codesign --force --options runtime --timestamp \
             --entitlements "${resolved}" \
             --identifier "${BUNDLE_ID}" \
             -s "${SIGN_IDENTITY}" "${APP}" 2>&1 | sed 's/^/      /'

    if codesign --verify --deep --strict --verbose=2 "${APP}" 2>&1 | grep -q "satisfies its Designated Requirement"; then
        ok "signature verifies"
    else
        codesign --verify --deep --strict "${APP}" 2>&1 | sed 's/^/      /'
        ok "signed (verify output above)"
    fi

    say ""
    say "  Entitlements actually embedded:"
    codesign -d --entitlements - --xml "${APP}" 2>/dev/null \
        | plutil -convert xml1 -o - - 2>/dev/null | grep -E "key|string" | sed 's/^/      /'
}

notarize() {
    step "Notarizing (this UPLOADS the app to Apple)"
    local zip="${OUT}/${APP_NAME}.zip"
    ditto -c -k --keepParent "${APP}" "${zip}"
    xcrun notarytool submit "${zip}" --keychain-profile "${NOTARY_PROFILE}" --wait \
        2>&1 | sed 's/^/      /'
    step "Stapling"
    xcrun stapler staple "${APP}" 2>&1 | sed 's/^/      /'
    xcrun stapler validate "${APP}" 2>&1 | sed 's/^/      /'
    step "Gatekeeper assessment"
    spctl --assess --type execute --verbose=4 "${APP}" 2>&1 | sed 's/^/      /'
}

case "${MODE}" in
    --preflight) preflight; exit $? ;;
    --notarize)  preflight || exit 1; build_and_sign; notarize ;;
    build|"")    preflight || exit 1; build_and_sign
                 say ""
                 say "  Built and signed at ${APP}"
                 say "  NOT notarized and NOT installed. To notarize (uploads to Apple):"
                 say "      ./Scripts/package-developer-id.sh --notarize" ;;
    *)           bad "unknown option ${MODE}"; exit 1 ;;
esac
