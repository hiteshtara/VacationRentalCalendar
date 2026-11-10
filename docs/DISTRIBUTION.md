# Distribution architecture

**Vacation Rental Calendar — "One Calendar. Every Rental."**

Written for whoever does the Apple work, which may be future you. Assumes
familiarity with macOS distribution but not with this codebase.

Companion to [APP-STORE-READINESS.md](APP-STORE-READINESS.md), which assesses
blockers. This one decides the shape of the thing.

---

## Phase A — what exists today

Audited on branch `feature/distribution` at commit `9c85cac`. All facts below
were read from the repository, not recalled.

| | Current state |
|---|---|
| Bundle identifier | `com.vacationrentalcalendar.app` |
| Version | `CFBundleShortVersionString` **1.0.0**, `CFBundleVersion` **1** — both hard-coded |
| Signing identity | **self-signed**, `Vacation Rental Calendar Local Signing`, created by `Scripts/setup-signing.sh` with `openssl` |
| Timestamp | `--timestamp=none` |
| Hardened runtime | **not enabled** |
| Entitlements | **none exist** — no `.entitlements` file anywhere |
| Notarization | **no step exists** |
| Mach-O binaries | **two**: `Contents/MacOS/VacationRentalCalendar` and `Contents/MacOS/vrc` |
| Helper invocation | `HelperCloudClient` spawns `vrc` via `Process` |
| Credential storage | file keychain, ACL via `SecTrustedApplicationCreateFromPath` |
| Minimum macOS | 14.0 |
| Copyright | *"Local build. Not for distribution."* |

### Two paths, and what actually differs

The instinct is to treat Developer ID and the App Store as one project. They
are not, and conflating them is how both get delayed.

| | Developer ID (notarized) | Mac App Store |
|---|---|---|
| Certificate | Developer ID Application | 3rd Party Mac Developer Application |
| Sandbox | **optional** | **required** |
| Hardened runtime | **required** | not used (sandbox instead) |
| Notarization | **required** | not required (App Review instead) |
| Nested CLI helper | allowed | allowed, but scrutinised |
| Data location | `~/Library/Application Support/…` | `~/Library/Containers/…` — **relocated** |
| Keychain | data protection keychain + access group | same |
| Distribution | direct download / DMG | App Store Connect |
| Review latency | minutes (notarization) | days |
| Billing | none, or own | StoreKit only |

**Shared by both, and therefore worth doing first:**

* an Apple Developer Program membership and a real Team ID
* the **data protection keychain** migration — identical in both, and it fixes
  the rebuild-orphans-credentials problem that already costs real time
* a real `CFBundleVersion` scheme that increments
* an honest `NSHumanReadableCopyright`
* app icon, onboarding, and the free-tier gate

**Divergent, and therefore worth deferring:**

* App Sandbox entitlements and the container data migration
* removing or re-shaping the nested `vrc` helper
* StoreKit

### Recommended sequence

**Stage 1 — Developer ID, unsandboxed.** Adds membership, a real certificate,
hardened runtime, secure timestamp, notarization, stapling. Nothing about the
app's architecture changes. This is the shortest path to a product a stranger
can install.

**Stage 2 — Keychain modernisation.** Ship the data protection store (already
written and tested, see below) under Developer ID first, where the blast
radius is one machine and rollback is a DMG. Prove the migration on real
credentials before Apple ever sees it.

**Stage 3 — Sandbox.** Entitlements, container migration, and the helper
decision. Ship as a Developer ID update so the container move is proven on a
small population.

**Stage 4 — App Store, free tier only.** One property, no billing.

**Stage 5 — StoreKit.**

The ordering principle: **every stage is shippable, and each one de-risks the
next.** Nothing in stages 1–3 is wasted if the App Store never happens.

### Preserving the working application

Non-negotiable, and already tooled:

* `Scripts/backup-before-install.sh` takes a verified backup — database via
  `sqlite3 .backup`, the installed bundle, and credential **references only**.
  It refuses to call a backup safe if a feed URL appears anywhere in it.
* Every backup keeps the previous `.app`, so rollback is a copy.
* Credential migration never deletes a source entry.

---

## Phase B — the Keychain replacement (implemented, isolated)

Written and tested on this branch. **Not wired into the running app, and no
live credential has been touched.**

### Why the current scheme cannot continue

`KeychainFeedCredentialStore` attaches an access control list built with
`SecTrustedApplicationCreateFromPath`. macOS matches ACL entries by designated
requirement, which here has repeatedly meant the binary's code hash, so every
rebuild orphans every credential. On 2026-11-10 that caused three separate
failures, including one where the app and its own bundled helper disagreed
about whether the same item was readable.

It is also simply unavailable under App Sandbox.

### The replacement

`KeychainPolicy` → `KeychainItemSpec` → `DataProtectionFeedCredentialStore`.

* **Data protection keychain**, not the file keychain — the file keychain is
  where ACLs live.
* **Access group `<TeamID>.com.vacationrentalcalendar.shared`** — an access
  group belongs to the signing *team*, so the app and the helper share one and
  rebuilding changes nothing.
* **`kSecAttrAccessibleAfterFirstUnlock`** — imports run on a timer and the
  screen may lock while the app is open; `whenUnlocked` would fail those
  silently.
* **Never synchronizable** — a feed URL is a bearer token for a whole booking
  calendar. It does not go to iCloud.
* **No `kSecAttrAccess`.** Asserted by a test, so a regression is a failure
  rather than an absence nobody notices.
* **Refuses to write without a Team ID**, rather than silently creating
  ungrouped items only the creating binary can read — the original bug under a
  new name.

Policy is deliberately separate from the `kSec*` plumbing: the rules are
asserted on every platform including Linux, and the translation is checked
once, where it can run.

### Migration

`CredentialMigration` **plans before it writes**. Every credential incident in
this project came from a write whose effect nobody checked — an in-place save
that kept a stale access list, a verification that grepped a command which does
not exist, a summary contradicting its own per-item output. A plan can be read
and argued with before anything moves.

Four outcomes per reference: `willMigrate`, `alreadyPresent` (so migration is
repeatable), `sourceUnreadable` (named so it can be re-entered, never guessed
at), `notConfigured` (never configured is not broken).

Applying it **reads the copy back** and only then counts it migrated. Source
entries are never deleted. A plan's `description` carries a 12-character
digest and never the value, so it is safe to print.

### What is still required before it can be used

1. **An Apple Developer Program membership and a Team ID.** Without one,
   `KeychainPolicy.isUsable` is false and the store refuses to write. This is
   the single blocking dependency.
2. A `keychain-access-groups` entitlement naming the group.
3. Both binaries signed by the same team.

---

## Phase D — commercial packaging

### Branding

* App name **VacationRentalCalendar**, display name **Vacation Rental
  Calendar** (24 characters, inside the 30-character App Store limit).
* Tagline **"One Calendar. Every Rental."**
* The name is generic, which is weak for trademark and for search. Worth
  settling before launch rather than after.
* Airbnb, Vrbo and Booking.com are registered marks: usable in descriptive
  copy, never in the name, subtitle, icon or screenshots, and never implying
  partnership. No platform logos — the app currently uses coloured dots, which
  is the right call.

### Icon

`Scripts/make-icon.sh` exists. App Store requires 1024×1024 with no alpha and
no rounded corners.

### First-launch onboarding

Four screens, and the third is the one that matters:

1. **What this does** — one calendar, every rental.
2. **Add your first property** — name, address, time zone.
3. **What it will not do.** Honest up front: platforms regenerate iCal on
   their own schedule so changes take hours; blocks a platform *imported* from
   elsewhere are invisible in its own export; Booking.com labels reservations
   and owner blocks identically and the app refuses to guess; availability
   rules never export at all.
4. **Connect a calendar** — paste one iCal URL, see it work.

Screen 3 is a retention decision, not a legal one. Every one of those limits
will otherwise be discovered as "the app is broken".

### Free tier

One property free; additional properties paid.

* The gate is `PropertyRepository.active().count` — already the natural seam,
  and `archived_at` already exists.
* **A lapsed subscription must never withdraw availability.** Archive and
  lock, never delete, never unpublish. A billing event causing nights to go
  back on sale is this project's defining failure.
* Archived properties stay readable, because the history is what explains past
  nights.

### Upgrade flow, designed but inert

Reached from the portfolio when adding a second property. States the price,
what it unlocks, and that existing data is untouched. **No StoreKit, no
product identifiers, no purchase path** until Stage 5 — a dead upgrade button
is a review rejection.

---

## Open blockers

| | Blocks | Resolution |
|---|---|---|
| No Apple Developer Program membership | Stages 1–5, and the Keychain work | $99/year decision |
| No Team ID | `KeychainPolicy.isUsable` false | follows membership |
| `CFBundleVersion` hard-coded to 1 | any resubmission | build-number scheme |
| Nested `vrc` helper spawned via `Process` | Stage 3 | prefer in-process `VRCCore` |
| Container relocation | Stage 3 | migration + tests, not yet written |
| No StoreKit | Stage 5 | after paying customers exist |
| Generic product name | marketing, not shipping | naming decision |
