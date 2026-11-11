# Provisioning profiles

Not tracked in Git. A profile is tied to one team and one App ID and has no
value in a public repository, so this directory holds only this note.

`keychain-access-groups` is a **restricted entitlement** on macOS. A signature
that merely requests it is not enough — AMFI kills the process on launch, with
no log and no error, which is exactly what happened here on 2026-11-10. The
claim has to be authorised by a provisioning profile.

Place the downloaded profile here as:

    Resources/Profiles/vrc-developer-id.provisionprofile

`Scripts/test-keychain-integration.sh` and `Scripts/package-developer-id.sh`
look for it at that path, and skip with an explanation when it is absent.

See docs/KEYCHAIN-MIGRATION.md for how to create it.
