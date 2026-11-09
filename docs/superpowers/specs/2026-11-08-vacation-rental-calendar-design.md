# Vacation Rental Calendar for macOS — Design

Date: 2026-11-08
Status: approved to build (requirements supplied as a complete brief; questions waived)

## Intent and the why

The owner manages several vacation rental units listed simultaneously on
Airbnb, Vrbo and Booking.com. Channel managers such as Lodgify solve the
calendar-unification problem but charge a recurring fee for it. The owner wants
the same visibility — one calendar, conflict warnings, a filtered outbound feed —
from a single native Mac application with no subscription and no cloud service.

The reason this is not simply "sync all three calendars together" is a specific
and expensive asymmetry in how Airbnb behaves:

**When a host cancels a reservation, Airbnb blocks those dates on the Airbnb
calendar as a penalty. Those dates are not booked. They are rentable on Vrbo and
Booking.com.** A naive channel sync reads them as "unavailable", propagates the
block, and silently destroys sellable inventory. Protecting that inventory is the
single most important requirement of this project; every other feature is
subordinate to it.

## Goals

- One Mac application, launchable from Finder, that imports iCal feeds from
  Airbnb, Vrbo and Booking.com for multiple properties.
- Monthly, weekly and list views of all reservations across platforms.
- Durable local storage (SQLite) of properties, listings, events, user
  classifications, sync history and conflicts.
- Classification of every unavailable date into: confirmed reservation, owner
  block, maintenance block, cancellation-related block, or unknown.
- Anything not confidently classified lands in a **Needs Review** queue.
- Conflict detection for overlapping confirmed reservations on one physical unit.
- Filtered iCal export containing only approved reservations and approved blocks.
- Automated tests, including the nine named scenarios.

## Non-goals

- No web dashboard, no AWS, no paid third-party service, no Lodgify.
- No automatic writing to platform availability. Nothing leaves this Mac without
  an explicit human action.
- No guest PII in exported feeds.
- No pricing, messaging, accounting or payout features.

## Anti-goals — things that would make this a failure even if it ran

1. An Airbnb cancellation block, or any block the app is not sure about, ends up
   marked unavailable on Vrbo or Booking.com. This is the failure mode the
   project exists to prevent.
2. The app infers "confirmed booking" from the mere existence of an iCal event.
3. A classification the owner made by hand is overwritten by a later import.
4. The owner is given a false sense of double-booking protection that the app
   cannot actually deliver (an offline Mac cannot serve a live feed).

## Constraints discovered in the environment

| Finding | Consequence |
|---|---|
| macOS 26.2, arm64, Swift 6.3.3 | Modern SwiftUI is available. |
| **Only Command Line Tools installed — no Xcode.app** | `xcodebuild` cannot run. No `.xcodeproj` can be generated or built. Build via SwiftPM; assemble the `.app` bundle with a script. |
| `XCTest` and `Testing` both ship inside Xcode.app and are **absent** | `swift test` cannot run here. Tests must be runnable without Xcode. |
| SwiftUI, SQLite3, UserNotifications all present in the CLT SDK | No external dependencies needed. |
| Existing starter: one 130-line `Sources/main.swift`, in-memory only, naive ICS parser | Reviewed and archived to `Attic/`. Its safety *warnings* and its classification vocabulary carry forward; its parser and storage are replaced. |

## Decisions I made (my call, not the owner's)

- **SwiftPM package, not an `.xcodeproj`.** Xcode opens a `Package.swift` directly
  as a project, so this remains a first-class Xcode project the day Xcode is
  installed, and unlike a generated `.xcodeproj` it also builds *today*.
- **Raw SQLite3 C API, no wrapper library.** Avoids any dependency fetch and
  keeps migrations explicit.
- **Tests live in a plain library target (`VRCTestSuite`) exercised by an
  executable runner (`vrc-test`).** They run today with `swift run vrc-test`.
  A thin XCTest bridge in `Tests/` drives the same registry for Xcode users, so
  there is one copy of every assertion.
- **Half-open date intervals `[checkIn, checkOut)`.** A guest checking out on the
  same day the next checks in is a normal turnover, not a conflict.
- **Classification decisions key on `(listing, UID, RECURRENCE-ID)`**, not on the
  database row id, so they survive re-import, event edits and row recreation.
- **Export excludes events that originated on the destination platform**, since
  that platform already knows its own bookings.

## How classification works, and why it is deliberately pessimistic

The brief says not to trust the feed's classification, and the feeds earn that
distrust. In an Airbnb export, a penalty block from a host cancellation and a
block the host made by hand are byte-for-byte indistinguishable: same
`SUMMARY` ("Airbnb (Not available)" / "Blocked"), no distinguishing property.
There is no marker to read. Therefore the app does not guess.

The classifier produces a *proposal*: a kind, a confidence, and a written
rationale. Evidence that raises confidence is positive evidence of a booking —
for Airbnb, a `Reservation URL` in the `DESCRIPTION`; for Vrbo, a reserved
summary with guest contact data; for Booking.com, a reservation-shaped summary.
Absence of such evidence never implies a block is safe to share. An Airbnb
unavailable date with no booking evidence becomes `unknownUnavailable` and
`needsReview`, permanently, until a human says otherwise.

The export gate is a separate layer that re-checks the rule rather than trusting
the stored classification:

- Exportable: confirmed reservations with high confidence or manual
  confirmation; owner and maintenance blocks **only** once manually approved.
- Never exportable, with no override: `cancellationBlock`, `unknownUnavailable`,
  anything still flagged `needsReview`, and any auto-classified block.

## Shape of the application

`VRCCore` (library) holds everything testable: models, the SQLite layer and
migrations, repositories, the iCal reader and writer, the classifier, the export
policy, the conflict detector, the import reconciler.
`VacationRentalCalendar` (executable) is SwiftUI only: sidebar of properties,
month / week / list calendar, review queue, conflicts panel, feed settings,
export panel.

Imports reconcile by `(listing, UID, RECURRENCE-ID)`: unseen keys are inserted,
changed keys update in place, keys absent from the feed are tombstoned rather
than deleted, `STATUS:CANCELLED` is honoured, and every run is recorded in
`sync_runs`. Re-importing an unchanged feed therefore changes nothing.

## What is left to the builder

Visual design of the calendar views, the exact SQL of each repository, the
wording of alerts, and the icon artwork.

## Phase 4 is research, not activation

Before any outbound integration, the supported import/export capability of each
platform gets written up, along with the hosting options that would be needed to
serve a feed while the Mac is asleep, and their costs. Nothing outbound is
switched on in this project.
