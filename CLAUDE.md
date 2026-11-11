# VacationRentalCalendar

A native macOS SwiftUI app that unifies the Airbnb, Vrbo and Booking.com
calendars for 39 G Street, South Boston, plus a minimal AWS service so it keeps
importing and publishing while the Mac is asleep.

## The point of the project

**Airbnb blocks dates after a host cancellation. Those blocks must never make
the same dates unavailable on Vrbo or Booking.com.** Blindly propagating every
"unavailable" event destroys sellable inventory, which is exactly what the paid
channel managers do. Everything below exists to keep that from happening.

When in doubt, the safe direction is **leaving a night on sale**. A night left
on sale by mistake is recoverable; a night silently withdrawn is lost revenue
nobody notices.

## Hard rules — do not relax these

- `OutboundSyncGate.isEnabled` is `false`. Flipping it is a reviewed code
  change, never a UI toggle, and never something to do unasked.
- Never export `cancellationBlock`, `platformRestriction`, `provisionalHold` or
  `unknownUnavailable`. The allow-list `describesGenuineUnavailability` is the
  single source of truth, and it allow-lists so a new kind is non-exportable by
  default.
- Never treat an unknown unavailable event as a confirmed reservation.
- Never reopen a confirmed reservation, and never shrink one, on an import.
- A failed, empty or truncated feed withdraws **nothing**.
- Publishing a feed is not evidence a platform read it. `isRemoteSynchronised`
  is only true with evidence from the destination's own export.
- Additions **and** removals need explicit owner approval.
- Credentials live in the macOS Keychain (local) or Secrets Manager (cloud) —
  never in SQLite, never in Git, never in logs, never in Terraform state.
- Do not touch the live PriyankaHomes website, its Google Calendar, or its two
  DynamoDB tables. Those are read-only, always.

## Environment, and what it rules out

- Swift 6.3.3, **Command Line Tools only — no Xcode.** So no `xcodebuild`, no
  XCTest, no swift-testing, no iOS SDK.
- Tests therefore live in a hand-rolled harness: `Sources/VRCTestSuite` plus the
  `vrc-test` runner. `swift run vrc-test` runs everything;
  `swift run vrc-test "<filter>"` runs one group.
- `swift test` does **not** work and never will here. Don't reach for it.

## Layout

| Path | What |
|---|---|
| `Sources/VRCCore` | all business logic; no UI |
| `Sources/VacationRentalCalendar` | the SwiftUI app |
| `Sources/vrc` | CLI: `status`, `import`, `doctor`, `set-url`, `feed-diff`, … |
| `Sources/VRCLambda` + `Sources/vrc-lambda-*` | the five AWS handlers |
| `Sources/vrc-parity` | cross-platform output digest |
| `Migrations/postgres` | cloud schema; `010` is **generated** |
| `Infrastructure/terraform` | plan-only; nothing applied |

## Things that will bite you

**The Keychain items are cdhash-pinned.** They were created by an ad-hoc-signed
build. The app is now certificate-signed, so its hash differs and macOS
**refuses without ever showing a prompt**. There is no dialog to approve. The
only fix is re-entering the URL (`vrc set-url`), which writes a fresh entry and
leaves the old one untouched. Advice to "click Always Allow" is wrong — I made
that mistake.

**Never put a feed URL on a command line.** It is a bearer credential: it would
land in shell history, in `ps`, and in the transcript. `vrc set-url` reads it
with echo cleared and verifies it before saving. Let the owner paste it.

**An abandoned Keychain read poisons the process.** Every later keychain call in
that process blocks. Hence `DeadlineFeedCredentialStore`.

**Always read SQLite through `sqlite3 .backup` or `VACUUM INTO`.** Copying the
`.sqlite` file alone misses the WAL and reads stale data. That produced one
wrong conclusion already.

**Rehearsals must not touch the real database.** `RehearsalIsolation` exists
because an early rehearsal wrote publication rows into production.

**`BlockKind.rawValue` is snake_case** (`confirmed_reservation`), not the Swift
case name. A camelCase allow-list in SQL silently matched nothing.

## Cross-platform parity is a gate, not a nicety

The AWS handlers run the same `VRCCore` as the Mac. `swift run vrc-parity
--digest` must print the **same digest on macOS and Linux**; `Scripts/check-parity.sh`
compares them and `Scripts/build-lambda.sh` refuses to deploy if they differ.

Current digest: `b3398471b1ee56f477d9a1244b16449e8827df1616aa5fca365ef3db96c604f5`

Portability lives behind `canImport`: `swift-crypto` for `CryptoKit`, Keychain
confined to `canImport(Security)`, `FoundationNetworking` for `URLSession`,
`CSQLite` for SQLite. Linux-only bugs found this way: `FileManager.replaceItemAt`
is unusable on corelibs (use `rename(2)`), and one optional-cast chain defeated
the type checker outright.

## The two schemas

`Migrations/postgres/010_repository_schema.sql` is **generated** from the SQLite
migrator by `Scripts/generate-postgres-schema.sh`. Do not hand-edit its table
bodies — change `Sources/VRCCore/Database/Migrations.swift` and regenerate, so
the dialects cannot drift.

`011_safety.sql` is hand-written and adds what Postgres can enforce and SQLite
cannot, as **generated columns** over the repositories' own columns: the
repositories keep writing epoch doubles and `check_in`/`check_out`, while
exclusion constraints and guards operate on real `daterange` and `timestamptz`
derived from them.

Two dialect mappings you must not remove:
- `ORDER BY lower(name)`, not `COLLATE NOCASE` — SQLite-only collation.
- `run()` appends `RETURNING id` for identity tables, because the RDS Data API
  does **not** populate `generatedFields` for PostgreSQL. Without it every row
  gets id 0.

## Data that must survive

Two approved Vrbo decisions — **2026-12-10→17** and **2026-12-19→20** — seven
events, seven manual classifications, and both publication UIDs
(`vrc-812d1978…`, `vrc-a5a1dbf5…`). **December 17–18 are deliberately
excluded**: Airbnb blocked them after a cancellation and they stay sellable.
A test asserts they never appear in a generated feed.

Publication UIDs are migrated verbatim, never regenerated: a changed UID makes
a platform see a delete plus a create instead of an update.

## Working style the owner expects

- Verify rather than assert. Query the AWS Pricing API, `describe-db-engine-versions`,
  a real PostgreSQL instance — don't quote documentation from memory.
- State what you did **not** do, and what is still broken, plainly.
- Stop where asked. "Stop before creating resources" means stop.
- Don't merge PRs. Don't deploy. Don't change DNS.
