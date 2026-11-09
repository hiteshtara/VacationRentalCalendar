#!/bin/bash
#
# Builds and packages the five Swift Lambda handlers for provided.al2023.
#
#   ./Scripts/build-lambda.sh            build and package
#   ./Scripts/build-lambda.sh --deploy   also replace the function code
#
# WHY THIS USES DOCKER AND NOT THE STATIC LINUX SDK
#
# The official Static Linux SDK (swift-6.3.3-RELEASE_static-linux-0.1.0,
# checksum verified against swift.org) installs cleanly, and would be the
# tidier answer: a fully static musl binary with no shared objects at all.
# Two things stop it being usable here, both verified rather than assumed:
#
#   1. Its prebuilt Foundation was compiled by the open-source swift.org
#      6.3.3 toolchain. This machine has Apple's 6.3.3 from Command Line
#      Tools, and the module formats differ:
#        "compiled module was created by an older version of the compiler;
#         rebuild 'Foundation' and try again"
#      Using it from the host needs the swift.org toolchain installed
#      alongside Xcode's, which is a system change.
#
#   2. The musl SDK ships no sqlite3 headers, so the CSQLite target cannot
#      build. VRCCore needs SQLite for the Mac path even though the handlers
#      never touch it, so the whole module fails. Fixing that means either
#      vendoring the SQLite amalgamation (~9 MB of C in the repository) or
#      splitting VRCCore in two.
#
# Building inside swift:6.3.3-amazonlinux2023 avoids both. The container's
# toolchain matches the SDK, and its OS is exactly the Lambda runtime --
# Amazon Linux 2023, glibc 2.34 -- so the binary's ABI matches by
# construction rather than by luck. The Swift runtime is bundled into lib/,
# which Lambda already has on LD_LIBRARY_PATH (/var/task/lib), so no wrapper
# script is needed.

set -uo pipefail
cd "$(dirname "$0")/.."

IMAGE="swift:6.3.3-amazonlinux2023"
# Which environment's functions to update. Staging by default, so a careless
# --deploy cannot reach production: that needs the prefix stated explicitly.
PREFIX="${VRC_FUNCTION_PREFIX:-vrc-staging}"
FUNCTIONS=(fetch process publish api sweeper)
OUT=".build/lambda"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mfail\033[0m %s\n' "$*"; }

step "1. Parity gate"
say "  The server must agree with the Mac on every business rule. If these"
say "  digests differ the rules have diverged and nothing should ship."
MAC_DIGEST="$(swift run vrc-parity --digest 2>/dev/null | tail -1)"
[ -n "${MAC_DIGEST}" ] || { bad "could not compute the macOS digest"; exit 1; }
ok "macOS:  ${MAC_DIGEST}"

step "2. Building in ${IMAGE}"
command -v docker >/dev/null 2>&1 || { bad "docker is required"; exit 1; }
# Migrations is not optional: SQLScannerTests reads
# Migrations/postgres/*.sql from the working directory, so without it that
# test fails inside the container for want of a file. That failure was once
# written off as "a timing flake"; it was this.
rsync -a --exclude='.build' --exclude='.git' Package.swift Sources Migrations "${WORK}/"

docker run --rm --platform linux/arm64 -v "${WORK}:/src" -w /src "${IMAGE}" bash -lc '
set -e
dnf install -y -q sqlite-devel zip binutils >/dev/null 2>&1

echo "LINUX_DIGEST=$(swift run vrc-parity --digest 2>/dev/null | tail -1)"
swift run vrc-test > /tmp/vrc-test.log 2>&1 || true
grep -E "tests passed|tests failed" /tmp/vrc-test.log | sed "s/^/TESTS /" || true
grep "FAILED" /tmp/vrc-test.log | sed "s/^/TESTFAIL /" || true

for f in fetch process publish api sweeper; do
  swift build -c release --product "vrc-lambda-$f" >/tmp/b.log 2>&1 || {
    echo "BUILD_FAILED $f"; grep -E "error:" /tmp/b.log | head -3; exit 1; }
done

mkdir -p /src/pkg && rm -rf /src/pkg/*
for f in fetch process publish api sweeper; do
  d="/src/pkg/$f"; mkdir -p "$d/lib"
  cp ".build/release/vrc-lambda-$f" "$d/bootstrap"; chmod +x "$d/bootstrap"
  ldd "$d/bootstrap" 2>/dev/null | awk "{print \$3}" | grep -E "^/" | while read -r so; do
    case "$so" in
      /usr/lib/swift/*|*/libsqlite3*|*/libcurl*|*/libxml2*|*/libz.*|*/libcrypto*|*/libssl*|*/libnghttp*|*/libidn*|*/liblber*|*/libldap*|*/libsasl*|*/libssh*|*/libbrotli*|*/libzstd*|*/liblzma*|*/libpsl*|*/libunistring*|*/libgssapi*|*/libkrb5*|*/libk5crypto*|*/libcom_err*|*/libkeyutils*|*/libselinux*|*/libpcre*|*/libresolv*)
        cp -n "$so" "$d/lib/" 2>/dev/null || true ;;
    esac
  done
  # Refuse to ship a package whose dependencies do not all resolve.
  unresolved=$(LD_LIBRARY_PATH="$d/lib" ldd "$d/bootstrap" 2>/dev/null | grep -c "not found" || true)
  arch=$(readelf -h "$d/bootstrap" | awk "/Machine/ {print \$NF}")
  [ "$unresolved" = "0" ] || { echo "UNRESOLVED $f $unresolved"; exit 1; }
  [ "$arch" = "AArch64" ] || { echo "WRONG_ARCH $f $arch"; exit 1; }
  (cd "$d" && zip -qr "../$f.zip" bootstrap lib)
  echo "PACKAGED $f $(du -h /src/pkg/$f.zip | cut -f1) libs=$(ls $d/lib | wc -l) arch=$arch unresolved=$unresolved"
done
' > "${WORK}/container.log" 2>&1 || true

# The classification loop reads from a FILE, not a pipe.
#
# This used to be `docker ... | while read`, which put the loop in a subshell:
# `exit 1` there left the subshell, and because this script sets -uo pipefail
# but NOT -e, a non-zero pipeline did not stop it. The script carried on,
# copied the packages and exited 0 — so a DIVERGED parity digest printed a
# failure and then shipped anyway, and with --deploy it would have deployed.
# Verified by reproducing the shell semantics directly before changing this.
gate_failed=0
while IFS= read -r line; do
    case "${line}" in
        LINUX_DIGEST=*)
            LINUX="${line#LINUX_DIGEST=}"
            if [ "${LINUX}" = "${MAC_DIGEST}" ]; then ok "Linux:  ${LINUX} (identical)"
            else bad "Linux:  ${LINUX} — DIVERGED from macOS"; gate_failed=1; fi ;;
        TESTS*)
            # A failing suite is a failing build. This arm printed "ok"
            # unconditionally, which is how "1 of 369 tests failed" was
            # displayed in green and shipped.
            case "${line}" in
                *"tests failed"*) bad "${line#TESTS }"; gate_failed=1 ;;
                *)                ok  "${line#TESTS }" ;;
            esac ;;
        TESTFAIL*)     bad "${line#TESTFAIL }" ;;
        PACKAGED*)     ok "${line#PACKAGED }" ;;
        BUILD_FAILED*) bad "${line}"; gate_failed=1 ;;
        UNRESOLVED*)   bad "${line} — missing shared objects, would fail at startup"; gate_failed=1 ;;
        WRONG_ARCH*)   bad "${line}"; gate_failed=1 ;;
        *)             say "  ${line}" ;;
    esac
done < "${WORK}/container.log"

if [ "${gate_failed}" -ne 0 ]; then
    bad "a gate failed above — not packaging, not deploying"
    exit 1
fi

mkdir -p "${OUT}"
cp "${WORK}"/pkg/*.zip "${OUT}/" 2>/dev/null || { bad "no packages produced"; exit 1; }
step "3. Packages"
for f in "${FUNCTIONS[@]}"; do
    [ -f "${OUT}/${f}.zip" ] && ok "${OUT}/${f}.zip ($(du -h "${OUT}/${f}.zip" | cut -f1))"
done

if [ "${1:-}" != "--deploy" ]; then
    step "Done (build only)"
    say "Pass --deploy to replace the function code. Nothing was deployed."
    exit 0
fi

step "4. Deploying function code"
say "  This replaces code only. It creates nothing, enables no schedule, and"
say "  does not turn on outbound publication."
for f in "${FUNCTIONS[@]}"; do
    if aws lambda update-function-code --function-name "${PREFIX}-${f}" \
            --zip-file "fileb://${OUT}/${f}.zip" --query 'LastUpdateStatus' \
            --output text >/dev/null 2>&1; then
        ok "${PREFIX}-${f} updated"
    else
        bad "${PREFIX}-${f} not updated (does the function exist yet?)"
    fi
done
step "Done"
say "OutboundSyncGate and VRC_OUTBOUND_ENABLED are unchanged — both still off."
