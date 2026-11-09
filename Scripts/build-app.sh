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
BUILD="1"
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
        echo "Signed with the certificate — Keychain approvals will survive rebuilds."
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
# A stable requirement is the whole point of signing with a certificate: it is
# what lets a Keychain permission survive a rebuild.
REQ_FILE=".build/last-designated-requirement"
CURRENT_REQ="$(codesign -d -r- "${APP}" 2>&1 | grep 'designated' | head -1)"
if [ -f "${REQ_FILE}" ]; then
    PREVIOUS_REQ="$(cat "${REQ_FILE}")"
    if [ "${CURRENT_REQ}" = "${PREVIOUS_REQ}" ]; then
        echo "signature is stable across rebuilds — Keychain permissions will stick"
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
else
    TARGET="$(pwd)/${APP}"
fi

step "Done"
cat <<SUMMARY
Application: ${TARGET}
Size:        $(du -sh "${TARGET}" | cut -f1)
Signature:   $(codesign -dv "${TARGET}" 2>&1 | grep -E '^Signature' | head -1)

Open it by double-clicking in Finder, or:
    open "${TARGET}"
SUMMARY
