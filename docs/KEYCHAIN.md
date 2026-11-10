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


---

# Durable credential storage: where this goes next

Written 2026-11-10, after an app update silently disconnected Airbnb, Vrbo and
Booking.com. Option C is implemented; B and A are designs, **not built**.

## The invariant that actually governs this

`FeedCredentialStore.makeAccess()` writes items with
`SecTrustedApplicationCreateFromPath`. In the legacy file-based keychain that
call **pins the binary's code hash at the moment the item is written**. Rebuild
the binary and the hash changes, so the entry no longer matches — even when the
signing certificate and the designated requirement are byte-identical. macOS
then returns `errSecAuthFailed` (-25293) and does not prompt, because the
requester is not on the list.

**A stable designated requirement does not preserve Keychain access.** The
codebase asserted the opposite in three places (`build-app.sh` twice, and a
property literally named `survivesRebuild`), and that claim caused the outage:
it was believed, so nobody checked a live read. Those claims are now corrected
and the property is `identityIsStable`, which is what it always measured.

## Option C — authorized migration (IMPLEMENTED)

`Scripts/migrate-cloud-credential.sh` now carries the feed URLs as well as the
AWS key. For each listing it asks macOS for permission to read the existing
item, pipes the value to the newly installed helper, and verifies the helper
can read it afterwards.

- The URL never reaches disk, a log, argv, or shell history — only a pipe.
- Old entries are left in place; nothing is deleted and nothing is rotated.
- An item that cannot be read is reported as **needing re-entry**, never as
  migrated. The script exits 2 in that case so a caller can tell.
- `vrc set-url --stdin` exists for this path alone. It skips the interactive
  confirmation but keeps every check: https only, fetched and parsed before
  saving, never printed.

**What it does not do:** prevent the breakage. It repairs it, at the cost of
one macOS prompt per item per rebuild.

## Option B — a stable credential helper (DESIGNED, NOT BUILT)

A small binary, built once, signed once, installed once, and **not rebuilt with
the application**. It owns every Keychain item; the GUI and `vrc` ask it.

**Security.** Strictly better than today in one respect and no worse in any
other: the ACL names exactly one code object instead of two, and that object is
tiny enough to audit in full. It must return only what the caller needs — the
existing `vrc cloud check --json` precedent returns sanitised JSON, never the
credential — and for feed URLs it must *use* the URL (fetch and return parsed
events) rather than hand it back, or it becomes a confused deputy that launders
credentials to any local process that asks.

**Upgrade procedure.** This is the hard part, and the reason it is not built
yet. "Never rebuilt" is not a property a build system enforces; it is a
promise. It needs:
  * its own version number and its own release step, separate from the app;
  * a refusal to rebuild it as part of `build-app.sh`;
  * and when it genuinely must change, a deliberate migration — which is
    Option C again, so C remains necessary even once B exists.

**Failure recovery.** If the helper is replaced accidentally, every credential
becomes unreadable at once — a larger blast radius than today, where the app
and the CLI fail independently. Recovery is Option C. This is the trade: fewer
breakages, each one bigger.

**Verdict.** Worth building only if rebuild-induced breakage keeps happening
after C is in place. C removes the pain; B removes the recurrence, at the cost
of a constraint the build system cannot enforce.

## Option A — Data Protection Keychain + access group (FUTURE)

`kSecUseDataProtectionKeychain` selects the iOS-style keychain, where items are
scoped by **access group** rather than by code hash. Any build signed with the
same team identifier and the same `keychain-access-groups` entitlement can read
them, regardless of rebuilds. This is the only option that removes the problem
rather than managing it.

**Blocked on identity.** The app is signed with a self-signed certificate and
reports `TeamIdentifier=not set`. Access groups are normally prefixed by a team
identifier, so this likely requires a paid Apple Developer account and a
provisioning profile.

**Unverified.** Whether a self-signed certificate can carry a usable access
group on macOS has not been tested here, and should be, before anyone commits
to it. Treat the above as the shape of the answer, not as a promise.

## The rule that comes out of all this

**Verify readability; never infer it.** Stored connection status reflects the
last fetch, which may predate an install. `build-app.sh` now performs a real
read after installing and says plainly when credentials need migrating, and
`vrc doctor` distinguishes "a Keychain reference exists" from "this build can
read it" — a distinction it previously blurred, and the one that hid this
failure in plain sight.
