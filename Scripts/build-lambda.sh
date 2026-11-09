#!/bin/bash
#
# Builds the Swift Lambda handlers for AWS and replaces each function's code.
#
#   ./Scripts/build-lambda.sh --build          compile only
#   ./Scripts/build-lambda.sh --deploy         compile and update the functions
#
# Cross-compiles with the Swift Static Linux SDK, so it needs neither Docker
# nor Xcode -- which matters, because this machine has Command Line Tools only.
#
# The same VRCCore that the Mac application uses is linked in. Output parity
# between macOS and Linux is proved by `swift run vrc-parity --digest`, which
# must print the same digest on both; that check runs below before any deploy.

set -uo pipefail
cd "$(dirname "$0")/.."

SDK="aarch64-swift-linux-musl"
FUNCTIONS=(fetch process publish sweeper api)
OUT=".build/lambda"

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mfail\033[0m %s\n' "$*"; }

step "1. Checking the Static Linux SDK"
say "  The SDK is not a convenience here, it is a requirement."
say ""
say "  A Swift binary built against glibc -- in a Docker image, say --"
say "  dynamically links 13 Swift and Foundation shared objects out of"
say "  /usr/lib/swift/linux, plus libsqlite3. None of those exist on the"
say "  provided.al2023 runtime, so such a binary fails at startup with a"
say "  missing-library error. Verified, not assumed."
say ""
say "  The Static Linux SDK produces a fully static musl binary with no"
say "  shared-object dependencies at all, which is what provided.al2023"
say "  needs. The alternative -- bundling those libraries and a wrapper that"
say "  sets LD_LIBRARY_PATH -- works but triples the package size and adds a"
say "  runtime search path to get wrong."
say ""
if ! swift sdk list 2>/dev/null | grep -q "${SDK}"; then
    bad "SDK '${SDK}' is not installed."
    say ""
    say "  Install it once with the exact checksum from swift.org for your"
    say "  toolchain version:"
    say ""
    say "    swift sdk install \\"
    say "      https://download.swift.org/swift-<version>-release/static-sdk/<...>.artifactbundle.tar.gz \\"
    say "      --checksum <sha256>"
    say ""
    say "  Then re-run this script."
    exit 1
fi
ok "SDK present"

step "2. Parity gate"
say "  The server must agree with the Mac on every rule. If these digests"
say "  differ, the deploy is refused."
MAC_DIGEST="$(swift run vrc-parity --digest 2>/dev/null | tail -1)"
if [ -z "${MAC_DIGEST}" ]; then bad "could not compute the macOS digest"; exit 1; fi
ok "macOS digest: ${MAC_DIGEST}"
say "  (the Linux digest is checked in CI and by Scripts/check-parity.sh)"

# Verifies the packaging is actually deployable rather than merely present.
assert_static() {
    local binary="$1"
    if command -v ldd >/dev/null 2>&1; then
        if ldd "${binary}" 2>&1 | grep -qiE "libswiftCore|libFoundation\.so|not a dynamic"; then
            if ldd "${binary}" 2>&1 | grep -qi "libswiftCore"; then
                bad "${binary} links the Swift runtime dynamically — it will not start on"
                say "       provided.al2023. Build with the Static Linux SDK."
                return 1
            fi
        fi
    fi
    return 0
}

step "3. Building for Linux"
mkdir -p "${OUT}"
for fn in "${FUNCTIONS[@]}"; do
    target="vrc-lambda-${fn}"
    if ! swift build --swift-sdk "${SDK}" -c release --product "${target}" \
            > "/tmp/vrc-lambda-${fn}.log" 2>&1; then
        bad "${target} failed to build, see /tmp/vrc-lambda-${fn}.log"
        exit 1
    fi
    binary=".build/${SDK}/release/${target}"
    [ -f "${binary}" ] || { bad "no binary at ${binary}"; exit 1; }
    # The provided.al2023 runtime executes a file called `bootstrap`.
    rm -rf "${OUT}/${fn}"; mkdir -p "${OUT}/${fn}"
    cp "${binary}" "${OUT}/${fn}/bootstrap"
    chmod +x "${OUT}/${fn}/bootstrap"
    assert_static "${OUT}/${fn}/bootstrap" || exit 1
    (cd "${OUT}/${fn}" && zip -q "../${fn}.zip" bootstrap)
    ok "${fn}: $(du -h "${OUT}/${fn}.zip" | cut -f1), statically linked"
done

if [ "${1:-}" != "--deploy" ]; then
    step "Done (build only)"
    say "Pass --deploy to update the functions."
    exit 0
fi

step "4. Deploying"
say "  This replaces function code only. It creates nothing, changes no"
say "  schedule, and does not enable outbound publication."
for fn in "${FUNCTIONS[@]}"; do
    if aws lambda update-function-code \
            --function-name "vrc-${fn}" \
            --zip-file "fileb://${OUT}/${fn}.zip" \
            --query 'LastUpdateStatus' --output text > /dev/null 2>&1; then
        ok "vrc-${fn} updated"
    else
        bad "vrc-${fn} not updated (does the function exist yet?)"
    fi
done

step "Done"
say "Outbound publication is still governed by VRC_OUTBOUND_ENABLED=false and"
say "by OutboundSyncGate in the code. Neither was changed."
