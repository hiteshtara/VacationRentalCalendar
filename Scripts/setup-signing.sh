#!/bin/bash
#
# Creates a stable local code-signing identity, once.
#
# WHY THIS EXISTS
#
# macOS remembers "this program may read this Keychain item" by recording the
# program's code signature. An ad-hoc signature (`codesign -s -`) is just a hash
# of the binary, so every rebuild produces a different identity and macOS asks
# for permission all over again. Signed with a certificate instead, the
# permission is tied to the certificate and survives every rebuild.
#
# The certificate is self-signed and never leaves this Mac. It is not for
# distributing the app — only for giving the app a stable identity so your
# Keychain grant sticks.
#
# Run this once:   ./Scripts/setup-signing.sh
# Undo it with:    ./Scripts/remove-signing.sh

set -euo pipefail

IDENTITY_NAME="Vacation Rental Calendar Local Signing"
WORK_DIR="${HOME}/.vacationrentalcalendar/signing"
LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------- already done?

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "${IDENTITY_NAME}"; then
    say "The signing identity \"${IDENTITY_NAME}\" already exists and is valid."
    say "Nothing to do. Build with ./Scripts/build-app.sh"
    exit 0
fi

step "Generating a self-signed code-signing certificate"

mkdir -p "${WORK_DIR}"
chmod 700 "${WORK_DIR}"
cd "${WORK_DIR}"

if [ ! -f key.pem ]; then
    openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
        -subj "/CN=${IDENTITY_NAME}/O=Local Development" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
    chmod 600 key.pem
    say "Created a 10-year certificate in ${WORK_DIR}"
else
    say "Reusing the certificate already in ${WORK_DIR}"
fi

# Apple's importer rejects OpenSSL 3's modern PKCS#12 defaults, so ask for the
# older algorithms it understands.
step "Packaging the certificate for the Keychain"
rm -f identity.p12
openssl pkcs12 -export -out identity.p12 -inkey key.pem -in cert.pem \
    -name "${IDENTITY_NAME}" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -passout pass:vrclocal >/dev/null 2>&1
chmod 600 identity.p12

step "Importing into your login keychain"
say "macOS may ask for your login password here."
security import identity.p12 -k "${LOGIN_KEYCHAIN}" -P vrclocal \
    -T /usr/bin/codesign -A

step "Marking the certificate as valid for code signing"
security add-trusted-cert -r trustRoot -p codeSign -k "${LOGIN_KEYCHAIN}" cert.pem

step "Checking the result"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "${IDENTITY_NAME}"; then
    say "Identity is valid and ready."
else
    say "ERROR: the identity was imported but is not valid for code signing."
    say "Open Keychain Access, find \"${IDENTITY_NAME}\", and set"
    say "Trust > Code Signing to \"Always Trust\"."
    exit 1
fi

cat <<'NOTE'

==> One more thing, and it only happens once

The first time something signs with this certificate, macOS will ask whether
codesign may use its private key. Choose "Always Allow", not "Allow" — "Allow"
grants it a single time and you will be asked again on the next build.

Then, the first time the app reads a feed URL, macOS will ask whether the app
may use that Keychain item. Choose "Always Allow" there too.

After those two clicks you will not be asked again, including after rebuilds
and after restarting your Mac.

Next: ./Scripts/build-app.sh
NOTE
