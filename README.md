# Vacation Rental Calendar

Start with the [project documentation](docs/README.md), including [how the application works and its diagrams](docs/PROJECT-GUIDE.md). The Mac app works locally; the AWS service is written but not deployed according to [the handoff](HANDOFF.md). Outbound publication remains disabled.

A native macOS application that imports your Airbnb, Vrbo and Booking.com
calendars into one view, finds double bookings, and produces a **filtered**
outbound calendar — without a channel-manager subscription and without sending
anything to a booking platform.

In the current local workflow, records stay in SQLite on your Mac and feed
credentials stay in macOS Keychain. The planned AWS service will import calendars
while the Mac sleeps; see the [current architecture guide](docs/PROJECT-GUIDE.md).

---

## The problem this exists to solve

When a host cancels a reservation, **Airbnb blocks those dates on your Airbnb
calendar as a penalty.** Those nights are not booked. They are still perfectly
sellable on Vrbo and Booking.com.

A naive channel sync reads them as "unavailable" and propagates the block, and
you lose the inventory without ever being told.

Here is what the real Airbnb export for one of these listings actually contains:

```
BEGIN:VEVENT
DTSTAMP:20261109T003143Z
DTSTART;VALUE=DATE:20270501
DTEND;VALUE=DATE:20271110
SUMMARY:Airbnb (Not available)
UID:7f662ec65913-6a41ff926e335216bcdc0dbd3483a678@airbnb.com
END:VEVENT
```

No `DESCRIPTION`. No reservation link. No guest. Nothing. A confirmed booking, a
block you made by hand, and a block Airbnb imposed after a cancellation are
**byte-for-byte identical** in that feed. On that one listing, four such events
covered 206 nights — 193 of them in a single run — every one of which a naive
sync would have blocked everywhere else on no evidence at all.

So this app does not guess. It classifies only on positive evidence of a
booking, routes everything else to you, and refuses to export anything you have
not personally decided.

---

## How the protection works

Every imported date range gets one of five classifications:

| Classification | Meaning | Exported to other platforms? |
|---|---|---|
| **Confirmed reservation** | A real guest is staying | Yes, automatically |
| **Owner block** | You are holding the dates | Only after you classify *and* approve it |
| **Maintenance block** | The unit is unusable | Only after you classify *and* approve it |
| **Cancellation block** | Airbnb took the dates after a cancellation | **Never. No override exists.** |
| **Unknown unavailable** | Cause unknown | **Never, until you decide what it is** |

Four exclusions are absolute and cannot be overridden anywhere in the app:
cancellation blocks, unknown blocks, anything still awaiting review, and
anything you suppressed by hand. The export gate re-derives this from scratch
on every run rather than trusting a stored flag — see
[`ExportPolicy.swift`](Sources/VRCCore/Logic/ExportPolicy.swift).

Confidence is only ever raised by positive evidence: a reservation URL in the
description, a confirmation code, guest contact details, or a `SUMMARY` the
platform uses exclusively for bookings. **The absence of a marker never means
"safe".**

### Outbound synchronisation is off

The app reads platform calendars and writes `.ics` files to your Mac. It never
contacts a platform to change availability, and there is no code path that
could. The switch is a hard-coded constant, not a setting:

```swift
public enum OutboundSyncGate {
    public static let isEnabled = false
}
```

A test asserts it stays that way.

---

## Installing

### Requirements

- macOS 14 or newer
- Xcode Command Line Tools (`xcode-select --install`) — **full Xcode is not
  required**

### One-time setup

```bash
git clone https://github.com/hiteshtara/VacationRentalCalendar.git
cd VacationRentalCalendar
./Scripts/setup-signing.sh      # once — see "Why signing matters" below
./Scripts/build-app.sh --install
```

That puts `VacationRentalCalendar.app` in `/Applications`. Double-click it in
Finder like any other app. Without `--install` the bundle is left in `./dist`.

### Why signing matters

macOS remembers "this program may read this Keychain item" by recording the
program's **code signature**. An ad-hoc signature is just a hash of the binary,
so every rebuild looks like a different program and macOS asks permission again.

`Scripts/setup-signing.sh` creates a self-signed certificate that never leaves
your Mac, giving the app a stable identity so a permission you grant once keeps
working across rebuilds and restarts. You will see exactly two prompts, both the
first time:

1. *"codesign wants to use the private key…"* → **Always Allow**
2. *"Vacation Rental Calendar wants to use your confidential information…"* →
   **Always Allow**

Choose **Always Allow**, not **Allow** — the latter grants a single use and you
will be asked again.

If you skip the signing step the app still works; it just asks again after each
rebuild.

---

## Using it

1. **Add your feed URLs.** Open **Feeds**, choose *Add URL* next to a platform,
   and paste that listing's iCal export URL. It goes straight to the Keychain —
   never to the database, never to a file in this project.

   | Platform | Where to find the export URL |
   |---|---|
   | Airbnb | Calendar → Availability → Connect to another website → Export calendar |
   | Vrbo | Calendar → Import/Export → Export calendar |
   | Booking.com | Calendar → Sync calendars → Export |

2. **Refresh** (⌘R, or the toolbar button). Automatic refresh runs on a timer
   you set while the app is open.

3. **Work the review queue.** Anything the app could not identify with
   confidence waits there, showing what the platform actually sent, what the app
   concluded and why, and what each choice will mean. Your decision is permanent
   — later imports never overwrite it.

4. **Check Conflicts.** Two confirmed reservations overlapping on one unit is a
   double booking and raises a native notification. A check-out and a check-in on
   the same day is a normal turnover and is not flagged.

5. **Build a filtered export.** The Export screen shows two columns — what will
   be shared and what is being held back, each with the reason — plus a running
   count of nights kept sellable. Save it as `.ics` when you are satisfied.

### Menu bar and login

The app keeps a menu-bar item showing sync status, the review backlog and any
double bookings, with a Refresh command. **Launch at login** is in
Settings (⌘,).

---

## Command line

The same core is available headlessly, which is also how the app is tested:

```bash
swift run vrc status                  # properties, feeds, counts, review backlog
swift run vrc import                  # read every feed, read-only
swift run vrc review                  # what needs a decision, and why
swift run vrc classify --key <k> --kind cancellation_block
swift run vrc conflicts
swift run vrc export --property 1 --to vrbo --write /tmp/out.ics
swift run vrc doctor                  # schema, Keychain, signature, outbound gate
```

`vrc set-url --listing <id>` reads a URL from stdin, so the credential never
appears in your shell history or the process list.

---

## Tests

```bash
swift run vrc-test              # the whole suite
swift run vrc-test --list       # names only
swift run vrc-test Required     # filter
```

**60 tests, 217 assertions, all passing.** They cover the nine scenarios in the
brief end-to-end through the real database, importer, classifier, conflict
detector and export pipeline:

1. An Airbnb confirmed booking blocks those dates in the filtered export
2. An Airbnb cancellation block is excluded from other platforms' exports
3. An unknown Airbnb block stays pending review
4. A Vrbo reservation appears in the unified calendar
5. A Booking.com reservation appears correctly
6. Overlapping confirmed reservations raise a warning
7. Re-importing a feed creates no duplicates
8. A changed event updates the existing record
9. Reviewed classifications survive a restart and later imports

Plus migrations, RFC 5545 parsing corner cases, export escaping and folding,
guest-data leakage, and a test asserting that **no automatic classification path
can produce an exportable block.**

### Why not `swift test`?

`XCTest` and `swift-testing` both ship inside `Xcode.app`, so neither is
available with the Command Line Tools alone. The assertions therefore live in a
plain library (`Sources/VRCTestSuite`) driven by a small runner, so they run on
any machine with Swift. `Tests/VRCCoreTests` bridges the same registry into
XCTest for anyone who does have Xcode — one copy of every assertion either way.

---

## How it is built

```
Sources/
  VRCCore/              Everything testable. No UI, no dependencies.
    Model/              Properties, listings, events, classifications, conflicts
    Database/           SQLite wrapper, migrations
    Repository/         One per table
    ICal/               RFC 5545 reader and writer
    Logic/              Classifier, export policy, conflict detector, importer
    Platform/           Keychain credential store, code-signature inspection
  VacationRentalCalendar/   SwiftUI app (macOS)
  VRCTestSuite/         The test suite
  vrc/                  Headless CLI
  vrc-test/             Test runner
```

SQLite, Keychain, notifications and SwiftUI come from the system. Linux builds
use Apple’s `swift-crypto` package for the shared cryptographic APIs.

### Data model

Reconciliation keys on `(listing, UID, RECURRENCE-ID)`, hashed into a stable
`event_key`. Classifications hang off that key and are deliberately **not** a
foreign key onto `events`, so a decision you made outlives the row it was made
about — a feed removing and re-adding an event cannot erase it.

Events that vanish from a feed are tombstoned, not deleted.

Dates are half-open, `[check-in, check-out)`, and all-day values are normalised
to UTC midnight so day arithmetic cannot drift with your time zone or with
daylight saving.

Migrations are forward-only and each runs in a transaction with its own
bookkeeping row, so a half-applied migration is impossible.

---

## Security

- **Feed URLs are credentials.** A platform iCal URL carries a long random
  token and no password — whoever holds it can read that listing's entire
  booking calendar. They live in the macOS Keychain. There is deliberately **no
  plaintext fallback**: silently downgrading their protection would be worse
  than failing visibly.
- They are never written to the SQLite file (a test asserts this), never
  committed, and never shown in full in the UI — only the host.
- **Exports carry no guest data.** Outbound events say `Reserved` or
  `Not available` and nothing else. Outbound UIDs are derived from, not equal
  to, the source UID, so a platform cannot correlate them back. Tests assert
  that guest names, phone digits, email addresses and source UIDs never appear
  in a generated file.
- Feeds must be `https`. Plain `http` is refused rather than silently accepted.
- Keychain reads run with a deadline and never block the interface, and they
  happen only when a feed is actually being read — not while drawing a calendar.

---

## What this cannot do

Worth being straight about:

- **It cannot serve a live feed while your Mac is asleep.** Airbnb, Vrbo and
  Booking.com pull iCal over the public internet on their own schedule. A
  laptop is not reachable. Options and costs are written up in
  [docs/HOSTING-OPTIONS.md](docs/HOSTING-OPTIONS.md).
- **It cannot change availability on a platform.** None of the three offers a
  public write API for individual hosts; see
  [docs/PLATFORM-SYNC-RESEARCH.md](docs/PLATFORM-SYNC-RESEARCH.md).
- **It is not real-time double-booking protection.** Platforms refresh imported
  calendars on their own cadence, often hours apart. A same-day double booking
  can still happen, on any iCal-based system including paid ones.
- **Repeating events (`RRULE`) are not expanded.** They are flagged for review
  rather than silently misread. The rental platforms do not use them.

---

## Licence and provenance

A personal tool, built for one owner's properties. No warranty. Not affiliated
with Airbnb, Vrbo or Booking.com.

The design document is at
[docs/superpowers/specs/2026-11-08-vacation-rental-calendar-design.md](docs/superpowers/specs/2026-11-08-vacation-rental-calendar-design.md).
