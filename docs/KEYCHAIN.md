# Keychain access: why the GUI could not read the AWS credential, and the fix

This documents a real failure the owner hit — the Cloud pane showing "AWS
credentials stored but unreadable" even though `vrc cloud check` worked from the
command line — the investigation that explained it, and the design that fixes
it. It is written so the next person does not repeat the dead ends.

## Symptom

- The command-line `vrc cloud check` reached AWS and returned status.
- The SwiftUI app's Cloud pane reported the AWS credential, and the feed URLs,
  as unreadable.
- Rotating the IAM key "fixed" it until the next rebuild, then it broke again.

## Root cause

On this machine the credentials live in the **login keychain** (the file-based
keychain, not the data-protection keychain). A generic-password item there is
guarded by **two independent checks**, and both must pass on every read:

1. **A trusted-application ACL**, which matches code by its *designated
   requirement* — for a certificate-signed binary that is
   `identifier "…" and certificate root = H"…"`. This is **stable across
   rebuilds**.
2. **A partition list**, which pins the **code-directory hash (cdhash)** of the
   binary that created the item. A rebuild produces a new cdhash, so this
   **breaks on every rebuild**, and it cannot be widened without the login
   password.

The app bundle ships **two separate executables**:

| Executable | Identifier | Role |
|---|---|---|
| `VacationRentalCalendar` | `com.vacationrentalcalendar.app` | the SwiftUI GUI |
| `vrc` | `com.vacationrentalcalendar.app.vrc` | the CLI / helper |

They are different code objects with **different cdhashes**. An item the CLI
created (via `vrc cloud set-credentials`) is therefore unreadable by the GUI —
the partition list names the CLI's cdhash, not the GUI's. The feed URLs, created
by a still-earlier build, are unreadable by both current binaries for the same
reason. The CLI "worked" only because it was the creator.

## What was ruled out, with evidence

Each of these was tested with two separately-signed probe binaries, not assumed:

| Attempt | Result |
|---|---|
| Different identifier, same certificate, B reads A's item | refused (`-25293`) |
| **Same** identifier + certificate, different cdhash, B reads A's item | **refused** — the partition pins cdhash, so a shared identifier does not help |
| Creator re-signed (a rebuild) reads its own item | refused |
| Creator widens its own partition list in process (`SecKeychainItemSetAccess`) | refused (`-25293`) — the partition can only be changed with the login password |
| Data-protection keychain with a self-asserted `keychain-access-groups` entitlement | process killed / `errSecMissingEntitlement` — needs a provisioned entitlement (an Apple Developer team), which this project does not have |
| `/usr/bin/security` read | prompts for the login password (user-approvable) |

Conclusion: **two different code objects cannot share a login-keychain item**
without the login password, and for a self-signed certificate with no team
there is no partition token that is stable across rebuilds. The project's older
claim that certificate signing alone makes grants "survive rebuilds" is only
half true — it fixes the ACL check, not the partition check.

## The fix: the GUI asks the helper

The GUI no longer reads the AWS credential at all. It cannot, and chasing a way
to make it was the wrong goal. Instead:

- The GUI runs the bundled helper: `Contents/MacOS/vrc cloud check --json`.
- The helper is the **one code object** that owns the credential. It reads the
  keychain, signs the request, and prints **`CloudStatusPayload`** — counts,
  booleans, service status strings and date ranges. By construction it contains
  **no secret**: no access key, no secret key, no session token, no feed URL. A
  test asserts the exhaustive field list.
- The GUI decodes that one JSON line from stdout and shows it. stderr and a
  non-zero body are never parsed as status.

The invocation is deliberately rigid (`HelperCloudClient`): a fixed executable
path resolved from the bundle, a fixed argument vector, no shell, a timeout, and
output accepted only if it decodes to the expected type. Nothing the GUI holds
is interpolated into a command.

This satisfies the constraint directly: only the helper touches the credential,
so the two-code-object problem disappears.

## The remaining manual step, and why it is unavoidable

The helper's own keychain access still breaks when **the helper binary itself**
is rebuilt, because its cdhash changes and Swift builds are **not
byte-reproducible** (they embed build paths and timestamps). Verified in this
project: two builds of identical source produced different cdhashes.

So after an install that changes the helper, its stored credential must be
re-owned. `./Scripts/build-app.sh --install` does this automatically by calling
`./Scripts/migrate-cloud-credential.sh`, which:

- reads the existing secret **with the owner's approval** (a macOS prompt — choose
  *Always Allow* so later migrations are silent),
- hands it to the new helper in memory (never to disk, a log, or the shell
  history),
- **does not call AWS** — no key is created, rotated, or deleted,
- leaves the old keychain entry in place.

A GUI-only rebuild (changing `VacationRentalCalendar` but not `vrc`) does **not**
break anything, because the helper's cdhash is unchanged. Only a helper rebuild
needs the step.

### Why not just re-enter it?

An AWS secret access key cannot be read back from AWS after creation. Re-entering
it would mean rotating the key, which the owner explicitly ruled out. Migrating
the existing value preserves the exact IAM key.

## What a reviewer should check

- `CloudStatusPayload` has no field that can hold a secret (there is a test).
- `HelperCloudClient` uses a fixed path and fixed arguments and runs no shell.
- `vrc cloud check --json` writes JSON to stdout only; errors go to stderr and
  are secret-free.
- The migration script never echoes a value and never writes one to disk.
