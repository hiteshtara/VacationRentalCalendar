#!/bin/bash
#
# Makes code signing stable, once, so macOS stops asking for Keychain
# permission after every rebuild.
#
#   ./Scripts/fix-signing.sh
#
# WHAT THE PROBLEM ACTUALLY IS
#
# macOS records "this program may read this Keychain item" against the
# program's code signature. An ad-hoc signature is a hash of the binary, so
# every rebuild looks like a different program and the permission no longer
# matches — hence a fresh prompt each time, and feeds that suddenly cannot be
# read.
#
# Signing with a certificate fixes that: the permission is recorded against the
# certificate, which does not change when you rebuild.
#
# One step needs you, and cannot be automated: macOS will not hand the
# certificate's private key to `codesign` until the key's partition list says
# it may, and changing that requires your login password. You type it into
# macOS's own prompt. This script never sees it and never stores it.

set -uo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Vacation Rental Calendar Local Signing"
LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
APP="/Applications/VacationRentalCalendar.app"

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mfail\033[0m %s\n' "$*"; }

# Runs a command with a time limit so a hidden prompt cannot wedge the script.
bounded() {
    local seconds="$1"; shift
    "$@" >/tmp/vrc-signing-step.log 2>&1 &
    local pid=$!
    local waited=0
    while kill -0 "${pid}" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [ "${waited}" -ge "${seconds}" ]; then
            kill -9 "${pid}" 2>/dev/null
            wait "${pid}" 2>/dev/null
            return 124
        fi
    done
    wait "${pid}" 2>/dev/null
}

# ------------------------------------------------------------------ 1. identity

step "1. Checking the signing identity"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "${IDENTITY}"; then
    ok "\"${IDENTITY}\" exists and is valid for code signing"
else
    say "  Not found. Creating it…"
    ./Scripts/setup-signing.sh || { bad "could not create the identity"; exit 1; }
fi

# ------------------------------------------------------------- 2. the key itself

step "2. Checking whether codesign may use the certificate's private key"
cp "${APP}/Contents/MacOS/vrc" /tmp/vrc-sign-probe 2>/dev/null \
    || cp .build/arm64-apple-macosx/debug/vrc /tmp/vrc-sign-probe 2>/dev/null \
    || { bad "no binary to test with — run ./Scripts/build-app.sh first"; exit 1; }

if bounded 15 codesign --force --timestamp=none -s "${IDENTITY}" \
        -i probe.test /tmp/vrc-sign-probe; then
    ok "codesign can already use the key"
    KEY_OK=true
else
    bad "codesign is blocked waiting for permission to use the key"
    KEY_OK=false
fi

if [ "${KEY_OK}" = false ]; then
    cat <<'EXPLAIN'

  This is the one step that needs you.

  macOS keeps a "partition list" on each private key saying which programs may
  use it. The key this certificate uses does not yet list codesign, and only
  your login password can change that.

  The next command is macOS's own tool. It will ask for your login password in
  its own prompt. This script does not see it, log it, or store it.

EXPLAIN
    read -r -p "  Run it now? [y/N] " answer
    case "${answer}" in
        [yY]*)
            step "Updating the key's partition list"
            say "  When prompted, enter your macOS login password."
            if security set-key-partition-list \
                    -S apple-tool:,apple:,codesign: \
                    -s "${LOGIN_KEYCHAIN}"; then
                ok "partition list updated"
            else
                bad "that did not succeed"
                say ""
                say "  Alternative, which needs one click instead of a password:"
                say "    codesign --force -s \"${IDENTITY}\" ${APP}/Contents/MacOS/vrc"
                say "  Choose ALWAYS ALLOW — not Allow, which grants a single use."
                exit 1
            fi
            ;;
        *)
            say ""
            say "  Skipped. Either run this script again, or do it by hand:"
            say "    codesign --force -s \"${IDENTITY}\" ${APP}/Contents/MacOS/vrc"
            say "  and choose ALWAYS ALLOW."
            exit 1
            ;;
    esac

    if bounded 15 codesign --force --timestamp=none -s "${IDENTITY}" \
            -i probe.test /tmp/vrc-sign-probe; then
        ok "codesign can now use the key"
    else
        bad "still blocked — see the manual alternative above"
        exit 1
    fi
fi

# --------------------------------------------------- 3. two consecutive rebuilds

step "3. Building twice and comparing the signatures"
say "  A stable identity means both builds must produce the same requirement."

./Scripts/build-app.sh --install >/tmp/vrc-build-1.log 2>&1 \
    || { bad "first build failed, see /tmp/vrc-build-1.log"; exit 1; }
FIRST=$(codesign -d -r- "${APP}" 2>&1 | grep "designated" | head -1)
FIRST_AUTH=$(codesign -dv "${APP}" 2>&1 | grep -c "Authority=${IDENTITY}" || true)
ok "build 1: ${FIRST}"

# Force a genuinely different binary so the comparison means something.
touch Sources/VacationRentalCalendar/App.swift
./Scripts/build-app.sh --install >/tmp/vrc-build-2.log 2>&1 \
    || { bad "second build failed, see /tmp/vrc-build-2.log"; exit 1; }
SECOND=$(codesign -d -r- "${APP}" 2>&1 | grep "designated" | head -1)
ok "build 2: ${SECOND}"

if [ "${FIRST}" = "${SECOND}" ] && [ "${FIRST_AUTH}" -gt 0 ]; then
    ok "the two builds share one designated requirement"
    say ""
    say "  That is the fix. A Keychain permission granted once now keeps"
    say "  working across every future rebuild."
else
    bad "the requirement changed between builds"
    say "  build 1: ${FIRST}"
    say "  build 2: ${SECOND}"
    say "  If both say \"cdhash\", the builds are still ad-hoc signed."
    exit 1
fi

# ------------------------------------------------------- 4. can it read a feed?

step "4. Checking the app can read its stored feed URLs"
say "  macOS may prompt once more, for the app rather than for codesign."
say "  Choose ALWAYS ALLOW."

if bounded 30 "${APP}/Contents/MacOS/vrc" doctor; then
    grep -E "^(ok|FAIL)" /tmp/vrc-signing-step.log | sed 's/^/  /'
else
    bad "the app is still waiting for Keychain permission"
    say "  Look for a prompt and choose Always Allow, then run:"
    say "    ${APP}/Contents/MacOS/vrc doctor"
    exit 1
fi

step "Done"
say "Rebuild freely from now on. Signatures stay stable and Keychain"
say "permissions stick."
