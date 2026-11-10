#!/bin/bash
#
# Apple distribution settings, in one place so they cannot drift between the
# build script, the notarization step and the Keychain access group.
#
#   source Scripts/apple-config.sh
#
# The Team ID is public information — it appears in every signature and in the
# access group of every Keychain item this app creates. It is not a secret and
# is deliberately tracked in Git. The notarization CREDENTIAL is a secret and
# is never stored here; it lives in a notarytool keychain profile.

APPLE_TEAM_ID="26JLFSV9YS"
APPLE_ENROLLMENT="individual"

APP_NAME="VacationRentalCalendar"
APP_DISPLAY_NAME="Vacation Rental Calendar"
BUNDLE_ID="com.vacationrentalcalendar.app"
HELPER_BUNDLE_ID="com.vacationrentalcalendar.app.vrc"

# <TeamID>.<suffix>. Must match KeychainPolicy.groupSuffix in VRCCore, which
# is asserted by a test rather than left to agree by coincidence.
KEYCHAIN_GROUP_SUFFIX="com.vacationrentalcalendar.shared"
KEYCHAIN_ACCESS_GROUP="${APPLE_TEAM_ID}.${KEYCHAIN_GROUP_SUFFIX}"

# The certificate Developer ID distribution requires. An Individual enrolment
# can issue this; it is not limited to Organization accounts.
DEVELOPER_ID_IDENTITY="Developer ID Application: "

# The notarytool keychain profile name. Created once by the owner with
# `xcrun notarytool store-credentials` — never by this repository.
NOTARY_PROFILE="vrc-notary"

ENTITLEMENTS_DEVELOPER_ID="Resources/Entitlements/developer-id.entitlements"
ENTITLEMENTS_APP_STORE="Resources/Entitlements/app-store.entitlements"
ENTITLEMENTS_HELPER="Resources/Entitlements/helper-inherit.entitlements"
