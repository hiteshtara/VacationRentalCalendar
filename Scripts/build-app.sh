#!/bin/bash
#
# Builds VacationRentalCalendar.app — a real double-clickable macOS application.
#
#   ./Scripts/build-app.sh              build into ./dist
#   ./Scripts/build-app.sh --install    build, then copy into /Applications
#
# Works with the Xcode Command Line Tools alone; full Xcode is not required.

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="VacationRentalCalendar"
BUNDLE_ID="com.vacationrentalcalendar.app"
VERSION="1.0.0"
BUILD="${VRC_BUILD_NUMBER:-1}"
IDENTITY_NAME="Vacation Rental Calendar Local Signing"
DIST="dist"
APP="${DIST}/${APP_NAME}.app"
INSTALL=false
[ "${1:-}" = "--install" ] && INSTALL=true

step() { printf '\n==> %s\n' "$*"; }

# ------------------------------------------------------------------ build

step "Compiling (release)"
swift build -c release --product "${APP_NAME}"
swift build -c release --product vrc

BIN_DIR="$(swift build -c release --show-bin-path)"

step "Rendering the icon"
if [ ! -f Resources/AppIcon.icns ]; then
    ./Scripts/make-icon.sh
else
    echo "Resources/AppIcon.icns already present"
fi

# ------------------------------------------------------------------ assemble

step "Assembling the bundle"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BIN_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
# Shipped inside the bundle on purpose: it sits beside the app binary, so both
# are named in the Keychain item's access list and one approval covers both.
cp "${BIN_DIR}/vrc" "${APP}/Contents/MacOS/vrc"
cp Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"

# Build provenance. Without this, "is the installed app the build I just made?"
# is unanswerable from the bundle, which is exactly the question that wasted an
# afternoon. `git describe` is not used: this works in a dirty tree too, and
# says so.
GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
if git diff --quiet HEAD 2>/dev/null; then GIT_STATE="clean"; else GIT_STATE="modified"; fi
BUILD_DATE="$(date -u '+%Y-%m-%d %H:%M:%SZ')"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>           <string>Vacation Rental Calendar</string>
    <key>CFBundleExecutable</key>            <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>            <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>               <string>${BUILD}</string>
    <key>CFBundleShortVersionString</key>    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <!-- false: the app keeps a Dock icon as well as its menu-bar item. -->
    <key>LSUIElement</key>                   <false/>
    <key>NSHumanReadableCopyright</key>      <string>Local build. Not for distribution.</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key>   <false/>
    <key>VRCGitCommit</key>                  <string>${GIT_COMMIT}</string>
    <key>VRCGitBranch</key>                  <string>${GIT_BRANCH}</string>
    <key>VRCWorkingTree</key>                <string>${GIT_STATE}</string>
    <key>VRCBuildDate</key>                  <string>${BUILD_DATE}</string>
</dict>
</plist>
PLIST

cat > "${APP}/Contents/PkgInfo" <<< "APPL????"

# ------------------------------------------------------------------ sign

step "Signing"

# codesign needs the certificate's private key, and the first time it asks the
# Keychain for it macOS puts up a dialog. If nobody is there to click it the
# command waits for ever, so every signing attempt is given a time limit and
# falls back to ad-hoc rather than hanging the build.
sign_bounded() {
    local identity="$1" identifier="$2" target="$3" seconds=25
    codesign --force --timestamp=none -s "${identity}" -i "${identifier}" "${target}" \
        >/tmp/vrc-codesign.log 2>&1 &
    local pid=$!
    local waited=0
    while kill -0 "${pid}" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [ "${waited}" -ge "${seconds}" ]; then
            kill -9 "${pid}" 2>/dev/null || true
            wait "${pid}" 2>/dev/null || true
            rm -f "${target}.cstemp"
            return 124
        fi
    done
    wait "${pid}" 2>/dev/null
}

SIGN_WITH="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "${IDENTITY_NAME}"; then
    echo "Found the local signing identity; trying it."
    if sign_bounded "${IDENTITY_NAME}" "${BUNDLE_ID}.probe" "${APP}/Contents/MacOS/vrc"; then
        SIGN_WITH="${IDENTITY_NAME}"
        echo "Signed with the certificate."
    else
        echo ""
        echo "  !! macOS is waiting for you to approve codesign's access to the"
        echo "     certificate's private key, and no one answered."
        echo ""
        echo "     Run this once, in Terminal, and choose ALWAYS ALLOW:"
        echo "         codesign --force -s \"${IDENTITY_NAME}\" ${APP}/Contents/MacOS/vrc"
        echo "     then re-run this script."
        echo ""
        echo "     Falling back to ad-hoc signing for now. The app works, but macOS"
        echo "     will ask for Keychain permission again after each rebuild."
        echo ""
    fi
else
    echo "No local signing identity. Using ad-hoc."
    echo "Run ./Scripts/setup-signing.sh once to make Keychain grants permanent."
fi

# Nested binary first, then the bundle, as codesign requires inside-out order.
sign_bounded "${SIGN_WITH}" "${BUNDLE_ID}.vrc" "${APP}/Contents/MacOS/vrc" \
    || { echo "signing the helper failed"; exit 1; }
sign_bounded "${SIGN_WITH}" "${BUNDLE_ID}" "${APP}" \
    || { echo "signing the bundle failed"; exit 1; }

codesign --verify --deep --strict "${APP}" && echo "signature verifies"

# Record the designated requirement and compare it with the previous build.
#
# A stable requirement is worth having, but it does NOT preserve Keychain
# access. Items here are created with SecTrustedApplicationCreateFromPath,
# which pins the binary's CODE HASH at the moment the item is written. A
# rebuild changes that hash even when the certificate and the designated
# requirement are byte-identical, and macOS then refuses without prompting.
# Earlier versions of this script claimed the opposite and that claim caused a
# real outage: an update silently disconnected Airbnb, Vrbo and Booking.com.
# Run ./Scripts/migrate-cloud-credential.sh after an install.
REQ_FILE=".build/last-designated-requirement"
# stdout only, and normalised — see Scripts/fix-signing.sh for why.
CURRENT_REQ="$(codesign -d -r- "${APP}" 2>/dev/null | grep 'designated' | head -1 \
    | sed -e 's/^[[:space:]]*#[[:space:]]*//' -e 's/[[:space:]]\{1,\}/ /g' \
          -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
if [ -f "${REQ_FILE}" ]; then
    PREVIOUS_REQ="$(cat "${REQ_FILE}")"
    if [ "${CURRENT_REQ}" = "${PREVIOUS_REQ}" ]; then
        echo "designated requirement unchanged since the last build"
    else
        echo ""
        echo "  !! The signature changed since the last build."
        echo "     previous: ${PREVIOUS_REQ}"
        echo "     current:  ${CURRENT_REQ}"
        echo "     macOS will ask for Keychain permission again."
        echo "     Fix it permanently with:  ./Scripts/fix-signing.sh"
        echo ""
    fi
fi
printf '%s' "${CURRENT_REQ}" > "${REQ_FILE}"

case "${CURRENT_REQ}" in
    *"certificate root"*|*"certificate leaf"*|*anchor*)
        echo "  signed with a certificate — stable identity, but see the Keychain note above"
        ;;
    *cdhash*)
        echo "  note: ad-hoc signed. Run ./Scripts/fix-signing.sh once to stop"
        echo "        the repeated Keychain prompts."
        ;;
esac

# ------------------------------------------------------------------ install

if [ "${INSTALL}" = true ]; then
    step "Installing to /Applications"
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP}" "/Applications/${APP_NAME}.app"
    echo "Installed at /Applications/${APP_NAME}.app"
    TARGET="/Applications/${APP_NAME}.app"

    # Verify what the previous version merely asserted. Stored connection
    # status is not evidence: it reflects the last fetch, which may predate
    # this install. Only an actual read proves anything.
    step "Verifying credential readability (not stored status)"
    UNREADABLE="$("/Applications/${APP_NAME}.app/Contents/MacOS/vrc" keychain 2>/dev/null \
                  | grep -c "^  FAIL" || true)"
    if [ "${UNREADABLE:-0}" -gt 0 ]; then
        echo "  ${UNREADABLE} stored credential(s) are NOT readable by this build."
        echo "  This is expected after a rebuild and is NOT a failed install."
        echo "  Fix it without rotating anything:"
        echo "      ./Scripts/migrate-cloud-credential.sh"
        echo "  Any item that cannot be migrated must be re-entered under Feeds."
        KEYCHAIN_NEEDS_MIGRATION=1
    else
        echo "  all stored credentials are readable by this build"
        KEYCHAIN_NEEDS_MIGRATION=0
    fi

    # A rebuilt helper has a new code hash, so it can no longer read the AWS
    # credential a previous build stored (see docs/KEYCHAIN.md). If a credential
    # is present but unreadable, offer to migrate it in place -- this reads the
    # existing secret with your approval and hands it to the new helper. It does
    # NOT create or rotate an AWS key. Skipped when there is nothing to migrate,
    # and skippable entirely with VRC_SKIP_KEYCHAIN_MIGRATION=1.
    HELPER_BIN="/Applications/${APP_NAME}.app/Contents/MacOS/vrc"
    if [ "${VRC_SKIP_KEYCHAIN_MIGRATION:-0}" != "1" ] \
       && "${HELPER_BIN}" cloud status 2>/dev/null | grep -q "could not be read"; then
        echo ""
        echo "The rebuilt helper cannot yet read its stored AWS credential."
        echo "Running ./Scripts/migrate-cloud-credential.sh to re-own it."
        echo "macOS will ask permission to read the existing secret — choose Always Allow."
        ./Scripts/migrate-cloud-credential.sh || \
            echo "  (migration skipped or declined; run it later to restore the Cloud pane)"
    fi
else
    TARGET="$(pwd)/${APP}"
fi

step "Done"
cat <<SUMMARY
Application: ${TARGET}
Size:        $(du -sh "${TARGET}" | cut -f1)
Signature:   $(codesign -dvvv "${TARGET}" 2>&1 | sed -n 's/^Authority=/signed by /p' | head -1)
Requirement: ${CURRENT_REQ}

Open it by double-clicking in Finder, or:
    open "${TARGET}"
SUMMARY
