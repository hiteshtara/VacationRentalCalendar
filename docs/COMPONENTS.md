# Component and data reference

This reference maps the current repository. See [the project guide](PROJECT-GUIDE.md) for behavior, diagrams and deployment gaps.

## Source map

| Path | Responsibility |
|---|---|
| `Sources/VacationRentalCalendar` | SwiftUI application, local state, calendar, review, reservations and availability views |
| `Sources/VRCCore/Model` | Properties, listings, events, classifications and availability models |
| `Sources/VRCCore/ICal` | RFC 5545 parsing, dates, escaping and calendar writing |
| `Sources/VRCCore/Logic` | Import, classification, conflicts, export rules and availability decisions |
| `Sources/VRCCore/Repository` | Persistence operations through `DataStore` |
| `Sources/VRCCore/Database` | SQLite, migrations, PostgreSQL Data API transport and SQL adaptation |
| `Sources/VRCCore/Sync` | Feed generation, publication safety, hosting, verification, hashing and cloud client |
| `Sources/VRCCore/Platform` | Platform adapters and local credential handling |
| `Sources/VRCLambda` | Fetch, process, publish, API and sweeper handlers |
| `Sources/vrc-lambda-*` | Lambda runtime entry points |
| `Sources/vrc` | Headless command-line interface |
| `Sources/VRCTestSuite`, `Sources/vrc-test` | Canonical assertions and executable test runner |
| `Sources/vrc-parity` | Deterministic macOS/Linux output comparison |
| `Infrastructure/terraform` | Proposed AWS resources; not applied per handoff |

## Stored concepts

| Concept | Purpose |
|---|---|
| Property | Physical rental whose inventory is managed |
| Platform listing | Property’s identity and connection on a booking platform |
| Event | Imported source observation and date range |
| Classification | Meaning, confidence, review state and owner overrides associated with an event key |
| Availability decision | Owner’s requested action for selected dates and destination |
| Availability audit | Record of decision transitions |
| Sync run | Import outcome and diagnostics |
| Feed publication and entries | Publication history, stable destination UIDs and last-known-good output |
| Feed snapshot | Destination observations used in verification |

Classifications are keyed independently of an event row’s lifetime so removing and reintroducing an event cannot erase an owner’s decision. Publication UIDs must survive migration unchanged. Date ranges exclude checkout day.

## Storage and credentials

Local records live in SQLite. Feed credentials live in macOS Keychain. A consistent database copy requires SQLite’s `.backup` or `VACUUM INTO`; copying the main file alone can miss pending WAL data.

Cloud records are intended to live in Aurora PostgreSQL, with secrets in Secrets Manager. `010_repository_schema.sql` is generated from the SQLite migrator; change the migrator and regenerate rather than editing generated table bodies. `011_safety.sql` adds PostgreSQL-specific protections. The `superseded/` directory is historical, not the current migration starting point.

Feed URLs are bearer credentials. Do not paste them into shell arguments, source, logs or documentation. Outbound calendars omit guest details and derive destination UIDs rather than exposing source UIDs.

## Developer commands

Run from the repository root:

```bash
swift run vrc status
swift run vrc doctor
swift run vrc review
swift run vrc conflicts
swift run vrc-test
swift run vrc-test --list
swift run vrc-parity --digest
```

`swift run vrc import` performs real configured feed reads and updates local observations; use it intentionally. `swift run vrc set-url --listing <id>` prompts securely in a terminal. Never append the credential to the command.

The project’s Command Line Tools environment uses `vrc-test`, not `swift test`. Full parity checking uses `Scripts/check-parity.sh` and requires its Linux/Docker prerequisites. Historical test counts in older documents are snapshots, not a current test result.

Build prerequisites and scripts are in [the first-run guide](GETTING-STARTED.md). Database integration and deployment preparation are covered in [HANDOFF.md](../HANDOFF.md).
