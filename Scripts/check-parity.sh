#!/bin/bash
#
# Proves the server and the Mac agree on every business rule, by running the
# same fixed inputs through both and comparing a digest of the output.
#
# Needs Docker only for the Linux side. If the digests differ, the rules have
# diverged and nothing should be deployed.

set -uo pipefail
cd "$(dirname "$0")/.."

IMAGE="swift:6.3-noble"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

printf '\033[1m==> macOS\033[0m\n'
MAC="$(swift run vrc-parity --digest 2>/dev/null | tail -1)"
echo "  ${MAC}"

printf '\033[1m==> Linux (%s)\033[0m\n' "${IMAGE}"
rsync -a --exclude='.build' --exclude='.git' Package.swift Sources "${WORK}/"
# --dns is not decoration. On 2026-11-11 Docker Desktop lost name resolution
# inside containers, apt-get could not reach ports.ubuntu.com, libsqlite3-dev
# was never installed and the build died with "could not build C module
# 'CSQLite'" — which reads like a source problem and is not one. An explicit
# resolver fixes it, so it is passed every time rather than diagnosed again.
LINUX="$(docker run --rm --platform linux/arm64 --dns 1.1.1.1 -v "${WORK}:/src" -w /src "${IMAGE}" \
    bash -lc 'apt-get update -qq && apt-get install -y -qq libsqlite3-dev >/dev/null 2>&1
              swift run vrc-parity --digest 2>/dev/null | tail -1')"
echo "  ${LINUX}"

echo ""
if [ "${MAC}" = "${LINUX}" ] && [ -n "${MAC}" ]; then
    printf '\033[32mIDENTICAL\033[0m — the rules agree on both platforms.\n'
    exit 0
fi
printf '\033[31mDIFFERENT\033[0m — the business rules have diverged. Do not deploy.\n'
exit 1
