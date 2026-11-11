# Mac App Store readiness

**Vacation Rental Calendar — "One Calendar. Every Rental."**

Audit performed 2026-11-10 against commit `63e7d86` on `feature/multi-property`.
Nothing here has been changed, submitted, or deployed; this is an assessment.

The headline: the app is in good shape as *software* — 437 tests, enforced
cross-platform parity, a real safety model — and a long way from shippable as
an *Apple product*. Nothing found is unsolvable, but two of the blockers go to
the core of how credentials and the helper process work, and they are not
afternoon jobs.

---

## Summary of blockers

| # | Blocker | Severity | Rough effort |
|---|---|---|---|
| 1 | No App Sandbox at all — no entitlements file exists | **Blocking** | 1–2 weeks |
| 2 | Keychain uses the legacy file-keychain ACL API, unavailable when sandboxed | **Blocking** | 1–2 weeks |
| 3 | Sandbox relocates the database; existing data would be stranded | **Blocking** | 2–4 days |
| 4 | Nested `vrc` CLI spawned via `Process` from the app bundle | **Blocking** | 1–3 weeks |
| 5 | Self-signed local identity; no Developer Program, no notarization | **Blocking** | 1–2 days + $99/yr |
| 6 | No StoreKit; free/paid tiers do not exist in code | **Blocking for paid** | 1–2 weeks |
| 7 | AWS is single-tenant; no customer identity or per-tenant isolation | **Blocking for cloud features** | 1–3 months |
| 8 | Guest data arrives from feeds — privacy labels and handling | High | 3–5 days |
| 9 | Platform integration is iCal-only, with real functional ceilings | High (product risk) | n/a — design |
| 10 | Name is generic; platform marks need careful handling | Medium | 1–2 days |

Estimates assume one experienced macOS developer and exclude App Review
turnaround. They are estimates, not quotes.

---

## 1. App Sandbox — not started

**Finding.** There is no `.entitlements` file anywhere in the repository.
`Scripts/build-app.sh` writes `Info.plist` by hand and signs without passing
any entitlements. The app is therefore entirely unsandboxed today.

The Mac App Store requires App Sandbox. At minimum this app needs:

* `com.apple.security.app-sandbox`
* `com.apple.security.network.client` — it fetches three iCal feeds and, for
  cloud features, AWS
* `com.apple.security.files.user-selected.read-write` — only if file export is
  kept

Everything the app does is otherwise sandbox-friendly: no AppleScript, no
scripting other apps, no arbitrary filesystem access.

**Why it is not just "add a file":** see blockers 2, 3 and 4, each of which is
a consequence of enabling the sandbox.

## 2. Keychain — the architecture is incompatible with sandboxing

**Finding.** `FeedCredentialStore` builds an access control list with
`SecTrustedApplicationCreateFromPath` and `SecAccessCreate`, and attaches it
with `kSecAttrAccess`
([FeedCredentialStore.swift:98–150](../Sources/VRCCore/Platform/FeedCredentialStore.swift)).

These are **file-based keychain** APIs. A sandboxed, App Store app uses the
data protection keychain, where items are scoped by **access group** via the
`keychain-access-groups` entitlement and a Team ID — not by code hash. The
existing ACL machinery has no effect there.

This is already written up as **Option A** in
[docs/KEYCHAIN.md](KEYCHAIN.md#option-a--data-protection-keychain--access-group-future),
where it is described as needing a verified Team ID and marked untested.

**The upside is real.** Code-hash pinning is the single largest source of
operational pain in this project — it is why feeds disconnect after every
rebuild, and it cost two rounds of debugging today alone. The data protection
keychain removes the problem rather than managing it. Sandboxing is a
prerequisite for the fix, not just a tax.

**Migration risk:** existing items are in the login keychain under the current
ACL scheme. Moving to an access group means re-entering all feed URLs once.
Acceptable for the owner; it must not be a silent failure for a paying
customer, so the app needs an explicit "re-enter your calendar URLs" flow with
a clear explanation.

## 3. The sandbox container moves the database

**Finding.** `AppPaths` resolves `applicationSupportDirectory`
([AppPaths.swift:7–9](../Sources/VRCCore/AppPaths.swift)). Unsandboxed that is
`~/Library/Application Support/VacationRentalCalendar/`. Sandboxed it becomes
`~/Library/Containers/com.vacationrentalcalendar.app/Data/Library/Application Support/…`.

The first sandboxed build will therefore find **an empty database** and look,
to the owner, like total data loss — 9 observations, 10 classifications, two
approved-then-cancelled decisions and their publication UIDs.

**Required:** a one-time migration that detects a populated legacy path,
copies the SQLite database via `.backup`/`VACUUM INTO` (never a raw file copy —
the WAL holds recent writes, and that has already produced one wrong
conclusion in this project), verifies row counts, and leaves the original in
place. This must be covered by tests before it is run anywhere real.

## 4. The nested CLI helper

**Finding.** `HelperCloudClient` spawns `vrc` from inside the app bundle via
`Process` ([HelperCloudClient.swift:28–45](../Sources/VacationRentalCalendar/HelperCloudClient.swift)),
and `Contents/MacOS/` ships both `VacationRentalCalendar` and `vrc`.

Under App Sandbox a child process must be sandboxed too and inherit the
parent's container (`com.apple.security.inherit`). App Review also scrutinises
nested executables, and `vrc` is a **general-purpose CLI** with `set-url`,
`import`, `doctor`, `rehearse` and more — a shape reviewers tend to question.

**Options, in order of preference:**

1. **Call `VRCCore` in-process.** The helper exists for historical reasons
   (the GUI reads cloud status through it). The logic is already a library.
   Cleanest, and removes the two-code-objects Keychain problem entirely.
2. **An XPC service.** Correct Apple-shaped answer if a separate process is
   genuinely wanted.
3. Keep the CLI, sandboxed and inheriting. Likeliest to draw review friction.

Recommendation: (1). It also deletes a whole class of bug — "the GUI can read
the credential but the CLI cannot" has cost real time today.

## 5. Signing, notarization, distribution

**Finding.** `Scripts/setup-signing.sh` mints a **self-signed** identity with
`openssl` and imports it locally. `build-app.sh` signs with
`--timestamp=none`, no hardened runtime, no entitlements, and there is no
notarization step. `Info.plist` says *"Local build. Not for distribution."*

**Required for the Mac App Store:**

* Apple Developer Program membership — **$99/year, still an open decision**
* A `3rd Party Mac Developer Application` certificate and a provisioning
  profile with the app's entitlements
* `CFBundleVersion` must increase per submission (currently fixed at `1`)
* A real `NSHumanReadableCopyright`

**For direct distribution outside the store** (worth keeping as an option,
since it sidesteps blockers 1–4 entirely): Developer ID certificate, hardened
runtime, secure timestamp, and notarization + stapling.

## 6. Subscriptions

**Finding.** No StoreKit code exists anywhere in the repository.

Free tier = one property, paid = multiple, is clean to enforce: the multi-
property work on this branch already has the property count behind
`PropertyRepository`, and `active()` is the natural gate.

**Required:** StoreKit 2 auto-renewable subscriptions, App Store Connect
products, a restore path, correct handling of expiry (**never delete a
property when a subscription lapses** — archive-and-lock, which the new
`archived_at` already supports), and the usual review requirements around
clearly presenting pricing and terms.

**Guard to build now, before any paywall exists:** lapsing must never withdraw
calendar availability. A customer whose card fails must not have nights
silently go back on sale — that is this project's defining failure mode, and a
billing event must not be able to cause it.

## 7. AWS for multiple customers

**Finding.** The staging stack is single-tenant by construction: one Aurora
cluster, one feed-token secret, IAM-authenticated management API, and a public
feed endpoint whose tokens map to object keys with no notion of a customer.

For SaaS this needs customer identity (Sign in with Apple is the natural fit
for a Mac App Store product), per-tenant data partitioning, per-tenant
credential storage, and quota/abuse controls on the public feed endpoint.

**This is the largest item in the audit and the least urgent.** The app is
fully functional with no cloud at all — local SQLite, local Keychain, local
imports. **Recommended: ship v1 entirely local.** A local-only app is also a
dramatically better privacy story, which matters for blocker 8.

## 8. Privacy and customer data

**Finding.** Imported feeds carry guest information — `guestName`,
`guestEmail` and reservation URLs appear in real Airbnb payloads, and the
secret scanner specifically watches for them.

Current posture is strong and should be stated plainly in the privacy label:

* data stays on the owner's Mac
* feed URLs live in the Keychain, never in the database, logs or Git
* outbound feeds carry **no** guest fields by construction, and a test asserts it

**Required:** App Privacy nutrition labels; a privacy policy URL; and, if
cloud sync ever ships, a decision recorded in writing about whether guest
names may leave the device. The current answer is no, and keeping it that way
is worth real money in positioning.

## 9. Platform integration ceilings

These are product limits, not bugs, and they shape what can honestly be
promised in the App Store description.

* **iCal only.** All three platforms are integrated by user-supplied iCal URLs.
  Official APIs need partner agreements none of which this app holds.
* **Platforms do not re-export imported blocks.** A block Airbnb imported from
  Booking.com is invisible in Airbnb's own export. Discovered the hard way on
  2026-11-10 (HANDOFF §20). Any claim of "complete sync" is false.
* **Booking.com labels reservations and owner blocks identically** as
  `CLOSED - Not available`. The app cannot distinguish them and correctly
  refuses to guess.
* **Export lag.** Platforms regenerate iCal on their own schedule, often
  hours. "Real-time" cannot be claimed.
* **Availability rules never export** — advance notice, preparation time, trip
  length. Nights blocked by a rule are invisible to iCal entirely.

**Marketing implication:** describe the product as *calendar unification with
safety*, not as a channel manager. The honest differentiator is the thing the
paid channel managers get wrong — not propagating cancellation blocks and
ambiguous holds — and that is defensible and demonstrable.

## 10. Naming and branding

* **"Vacation Rental Calendar"** is 24 characters, inside the 30-character App
  Store limit. It is also extremely generic — weak as a trademark and hard to
  rank for. Worth a naming conversation before launch, not after.
* **The tagline is fine** and not a trademark risk.
* **Airbnb, Vrbo and Booking.com are registered marks.** They must not appear
  in the app name, subtitle, icon, or screenshots in any way implying
  partnership. Nominative use in the description ("works with your Airbnb
  calendar export") is normally acceptable, but each platform has brand
  guidelines and the App Review guideline on intellectual property is enforced
  unevenly. Budget for one rejection and a wording revision.
* The app currently displays platform names in its UI, which is nominative and
  fine; it uses no platform logos, which is the right call.

---

## Recommended release sequence

**Stage 1 — Direct distribution, local only.** Developer ID, hardened runtime,
notarization. No sandbox, no StoreKit, no AWS. Skips blockers 1–4 and 6–7
entirely and gets a real product into real hands. *Effort: ~1 week + $99.*

**Stage 2 — Sandbox and the Keychain rewrite.** Blockers 1–4 together, because
they are one piece of work: entitlements, data protection keychain, container
migration, and removing the CLI helper. Ship as a direct-distribution update
first so the migration is proven on a small population before Apple sees it.
*Effort: ~4–6 weeks.*

**Stage 3 — Mac App Store, free tier only.** One property, no subscriptions.
Gets through App Review with the smallest possible surface. *Effort: ~1–2 weeks
plus review.*

**Stage 4 — Subscriptions.** StoreKit 2, multi-property unlock, lapse handling
that archives rather than withdraws. *Effort: ~2–3 weeks.*

**Stage 5 — Cloud, if the demand is demonstrated.** Multi-tenant AWS and
accounts. *Effort: months. Do not start before Stage 4 has paying customers.*

The sequencing point: **Stages 1 and 2 are worth doing regardless**, because
the sandbox work fixes the Keychain fragility that is already the worst
recurring problem in daily use. Even if the App Store never happens, that work
pays for itself.

## What was explicitly not done

No subscriptions introduced, no production infrastructure deployed, no live
availability changed, nothing submitted to Apple. 39 G Street and its three
credentials are untouched.


---

# Addendum — 2026-11-10, branch `feature/distribution`

Two of the ten blockers have moved. The rest stand as assessed.

## Blocker 2 (Keychain) — implementation written and tested

No longer "needs a verified Team ID; untested". `KeychainPolicy`,
`KeychainItemSpec`, `DataProtectionFeedCredentialStore` and
`CredentialMigration` exist, with 26 tests covering the policy, the `kSec*`
translation, and migration planning and application.

It is **isolated**: not wired into the running app, and no live credential has
been touched. The one blocking dependency is unchanged — an Apple Developer
Program membership, because without a Team ID `KeychainPolicy.isUsable` is
false and the store refuses to write rather than creating ungrouped items.

Effort revised from 1–2 weeks to **2–4 days**, and most of that is the live
migration rehearsal rather than the code.

## Blocker 3 (container relocation) — unchanged, and now the larger half

With the Keychain work done, this is the biggest remaining piece of the
sandbox move. Nothing has been written. The risk is unchanged and worth
restating: the first sandboxed launch finds an **empty database** and looks
like total data loss.

`Scripts/backup-before-install.sh` is a prerequisite and now exists, verified,
with a tested restore.

## A note on the diagnostics

Three scripts verified credential readability by grepping `vrc keychain`, a
subcommand that **has never existed**. It failed silently, so:

* `migrate-cloud-credential.sh` reported every successful migration as a
  failure, and its "already readable" count was always zero;
* `build-app.sh` reported "all stored credentials are readable" after every
  install, whether they were or not.

All three now use `vrc doctor`, which distinguishes *not configured* from
*unreadable*. This matters for distribution specifically: an install script
that always claims success is worse than one with no check, and it would have
shipped that way.

## Sequence

Unchanged, and reinforced by the Keychain work landing early: Developer ID
first, then the Keychain migration under Developer ID where rollback is a DMG,
then sandbox, then the store, then billing. See
[DISTRIBUTION.md](DISTRIBUTION.md).
