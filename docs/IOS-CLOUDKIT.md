# iPhone companion and iCloud sync

What is built, what it does, and what Apple requires before it can run on your
phone.

---

## Read this first: what this machine could and could not do

The Mac this was built on has the **Xcode Command Line Tools only**, not
Xcode.app. That is enough to build, sign and run the macOS app — and it is
**not** enough to build an iOS app. There is no iOS SDK, no Simulator, and no
device deployment without Xcode.

So:

| | Status |
|---|---|
| iPhone UI, view model, navigation | **Written and compiling** |
| CloudKit record mapping, merge rules, sync engine | **Written, compiling, and tested** (15 tests) |
| Entitlements and Xcode target scaffolding | **Written** |
| Compiled for iOS / run in Simulator / installed on a phone | **Not possible here — needs Xcode** |

Everything in `Sources/VacationRentalCalendarIOS` is written with cross-platform
SwiftUI on purpose, so `swift build` on the Mac type-checks it. That catches
real errors; it does not prove it looks right on a phone. Expect layout
adjustments the first time you run it.

---

## What you need from Apple

### 1. Xcode

Free, from the Mac App Store, about 10 GB. Required for any iOS build.

### 2. An Apple Developer account — and here the two paths diverge

**CloudKit requires a paid Apple Developer Program membership, US$99/year.**
This is the part worth knowing before you spend an evening on it. A free Apple
ID can sign and install an app on your own device, but it **cannot** enable the
iCloud/CloudKit capability — the entitlement is only issued to paid members.

| | Free Apple ID | Paid Developer Program ($99/yr) |
|---|---|---|
| Build and install on your own iPhone | Yes | Yes |
| App expires and must be reinstalled | **Every 7 days** | Every year |
| Devices | Up to 3 | 100 |
| **CloudKit / iCloud sync** | **No** | **Yes** |
| Push notifications, background refresh | No | Yes |

**If you do not want to pay $99/year**, the iPhone app still works — just
without iCloud. You would set the feed URLs up on the phone (the app already
supports this, under Sync) and let it import the calendars directly. You lose
shared classifications between Mac and phone; you keep the unified calendar,
conflict warnings and the review queue on both, independently. The
seven-day reinstall cycle is the bigger annoyance in practice.

Both your Mac and your iPhone 16 Pro Max use the same Apple Account, so once the
membership is in place the private CloudKit database is shared between them with
no further setup.

### 3. Setting it up in Xcode

1. `File → Open…` and choose `Package.swift`. Xcode opens the package directly.
2. Add an iOS App target (`File → New → Target → App`, name it
   `VacationRentalCalendar`, interface SwiftUI).
3. Delete the generated `ContentView.swift` and `…App.swift`, and add
   `iOSApp/VacationRentalCalendarApp.swift` instead.
4. Add `VacationRentalCalendarIOS` to the target's *Frameworks and Libraries*.
5. In *Signing & Capabilities*: pick your team, then add the **iCloud**
   capability, tick **CloudKit**, and select or create the container
   `iCloud.com.vacationrentalcalendar.app`.
6. Set the entitlements file to `iOSApp/VacationRentalCalendar.entitlements`.
7. Add the same iCloud capability to the macOS app so both talk to the same
   container.
8. Plug in the iPhone, select it as the run destination, and build.

The first run on a device asks you to trust the developer certificate under
*Settings → General → VPN & Device Management*.

---

## How sync actually works

### What is synced

Properties, listings (names and settings), imported events, and — the important
one — **classifications and review decisions**.

### What is deliberately not synced

- **Feed URLs.** Not in CloudKit, not in any record, ever. A feed URL is a
  bearer credential for your whole booking calendar.
- **Guest details.** The `details` field of an event, which for a confirmed
  Airbnb booking holds the reservation link and the guest's phone digits, is
  dropped at the mapping boundary.
- **Keychain references.**

A test (`no cloud record carries a feed URL or guest data`) asserts all of this,
and the sync engine re-checks every record against a forbidden-field list before
upload — so a future mapping mistake fails loudly instead of leaking quietly.

### Credentials are set up per device, on purpose

You asked not to assume Keychain items synchronise, and they do not here by
default. Each device is set up deliberately: on the iPhone, *Sync → Calendar
feeds on this iPhone → Add URL*. The URL goes into that device's Keychain.

This is slightly more work once, and it buys two things: a device you stop using
does not silently retain access to your calendars, and the phone works fine
without any URLs at all — it just shows what the Mac imported.

If you would rather type each URL once, `KeychainFeedCredentialStore` takes a
`synchronizable` flag that marks items for iCloud Keychain. It is off by
default and is a deliberate choice, not a default.

---

## Conflicting edits across devices

Plain last-writer-wins is not safe here, because the thing being merged decides
whether nights get blocked on another platform. Three rules sit on top:

1. **A human decision always beats an automatic one**, regardless of
   timestamps. An import on the Mac cannot overwrite something you classified by
   hand on the phone.
2. **If two devices disagree about what a block is, nobody wins.** Export
   approval is withdrawn, the item returns to the review queue, and the
   disagreement is recorded and shown to you under *Sync*. Two devices
   contradicting each other is exactly when the app should stop and ask.
3. **Export approval never merges upward.** A merge can withdraw it; a merge can
   never grant it. Suppression merges the other way — if either device said
   "don't share", it is not shared.

Ties on identical timestamps break deterministically on device identifier, so
two devices merging the same pair independently reach the same answer without
coordinating.

The guarantee that matters survives all of it: a test feeds the merge the worst
case — the other device insisting a cancellation block is an approved owner
block — and asserts the result is still not exportable.

---

## What is still missing

- **CloudKit subscriptions / push.** Sync currently runs on launch and on
  demand. Silent push notifications for near-instant propagation need the paid
  membership and a little more work.
- **Schema deployment.** CloudKit record types are created automatically in the
  development environment on first write. Promoting the schema to production is
  a manual step in the CloudKit Console before any non-development build.
- **Record deletion.** Tombstones sync, but records are never hard-deleted from
  CloudKit. Fine at this data volume; worth revisiting eventually.
- **iOS layout verification.** Nobody has seen this on a real screen yet.
