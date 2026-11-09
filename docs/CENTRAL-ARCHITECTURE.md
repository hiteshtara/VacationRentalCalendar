# Phase 1 — central booking system architecture

**Design for review. No AWS resources were created, no DNS changed, nothing
deployed, no production data touched.** `OutboundSyncGate.isEnabled` is still
`false`; the two approved Vrbo decisions and all seven classifications are
intact; zero writes were issued against any PriyankaHomes table or against
Google Calendar.

Prepared 2026-11-08. Region `us-east-1`. Branch `feature/central-booking-system`.

Companion documents: [MIGRATION-PLAN.md](MIGRATION-PLAN.md) and the schema
itself, [`Migrations/postgres/001_central_schema.sql`](../Migrations/postgres/001_central_schema.sql).

---

## What changed in the recommendation, and why

In the previous phase I recommended keeping SQLite on the Mac as the system of
record and adding S3 snapshots. You have decided on a central transactional
database and an always-running service. This document designs that. I am not
re-arguing the point — but one line of context matters for reading what
follows.

My argument for SQLite rested on there being exactly one writer. Your decision
to make this the authoritative system for **direct website bookings** is what
retires that argument: a guest booking at 2am is a second writer, and it cannot
wait for a Mac to wake. Once direct bookings are in scope, a central
transactional database is not a preference, it is a requirement. The
architecture below is built on that.

---

## 1. Why PostgreSQL, and what it buys that application code cannot

The schema is written, applied and **tested against a real PostgreSQL 17
instance**. Three money-losing failure modes are now prevented by the database
itself rather than by careful programming.

### 1.1 Double booking is structurally impossible

```sql
CONSTRAINT no_double_booking
    EXCLUDE USING gist (property_id WITH =, stay WITH &&)
    WHERE (status = 'confirmed')
```

Verified live:

| Insert | Result |
|---|---|
| Dec 10–17 confirmed | accepted |
| Dec 15–20 confirmed (overlaps) | **refused** — `no_double_booking` |
| Dec 17–20 confirmed (checkout-day adjacency) | **accepted** |
| Dec 11–14 cancelled (overlaps) | accepted — the constraint is partial |

The third row is the one that protects revenue in the other direction. A guest
checking out on the 17th and another arriving on the 17th is not a conflict, and
a naive `BETWEEN` comparison would have destroyed that night.

### 1.2 The half-open convention is guaranteed by the type, not by discipline

`daterange` over `date` is a discrete range type, so PostgreSQL canonicalises
every literal to `[)`. Verified:

```
SELECT '[2026-12-10,2026-12-17]'::daterange  →  [2026-12-10,2026-12-18)
lower_inc = true, upper_inc = false
```

There is no representable value that violates the convention. This is stronger
than the `CHECK` I originally wrote for it — the `CHECK` earns its place by
rejecting *unbounded* ranges, which are representable and would be catastrophic:

```
INSERT ... stay = '[2026-12-10,)'  →  violates check constraint "reservations_half_open"
```

The convention already matches `reservedNights()` on the website and
`DateInterval` in `VRCCore`, so no translation layer exists to get wrong.

### 1.3 The export rules live in the database

A single view defines what an unavailable night is, and a single immutable
function defines what may ever be exported. Verified behaviour of every
`BlockKind`:

| Kind | Reaches `blocking_intervals`? |
|---|---|
| `confirmed_reservation` | blocks |
| `owner_block` | blocks |
| `maintenance_block` | blocks |
| `cancellation_block` | **does not block** |
| `platform_restriction` | **does not block** |
| `provisional_hold` | **does not block** |
| `unknown_unavailable` | **does not block** |

`describes_genuine_unavailability` is an allow-list, so a `BlockKind` added in
future is **not exportable by default**. The failure mode of forgetting to
update it is a night left on sale, which is recoverable.

Also verified: expired-but-unswept holds do not block; the audit table rejects
`UPDATE` and `DELETE` for the application role; `source_events` rejects
`DELETE`; only one last-known-good feed may exist per destination and a
half-published feed cannot become one; an owner classification cannot be stored
unlocked.

### 1.4 The exclusion constraint doubles as the conflict detector

Imports never write to `reservations` directly. They write `source_events` —
which deliberately has **no** exclusion constraint, because two channels
genuinely can both claim the same nights and that fact must be recordable. A
separate promotion step moves observations into `reservations`.

A promotion that trips `no_double_booking` **is** a real double booking. The
handler records a `conflicts` row and leaves the observation unpromoted rather
than discarding it. One constraint, two jobs: preventer for bookings we admit,
detector for bookings we merely observe.

---

## 2. How much of the Swift survives

Measured, not estimated.

| | Files | Lines | Disposition |
|---|---|---|---|
| **VRCCore total** | 64 | 10,449 | |
| Pure logic — `Model`, `Logic`, `Availability`, `Sync` | 38 | 7,069 | **ports unchanged** |
| `CryptoKit` — `EventKey`, `AWSHosting`, `R2Hosting` | 3 | 582 | `swift-crypto` is API-compatible; a conditional import |
| `Security` / Keychain — `FeedCredentialStore` | 1 | 349 | stays macOS-only; Secrets Manager server-side |
| `AppKit` / `UserNotifications` — `ConflictNotifier` | 1 | 154 | stays in the macOS app |
| SQLite — `Database/Database.swift` | 1 | 221 | second implementation for Postgres |

So **roughly 94% of the core compiles for Linux with no logic change.** The
classification rules, the R1–R10 availability rules, the conflict analysis, the
iCal parser and writer, the publication pipeline and the export gate all port
as-is. That is the asset this design is built to keep.

The persistence layer is unusually easy to swap because all SQL sits behind a
seven-method interface on `Database`: `execute`, `run`, `query`, `queryOne`,
`scalarInt`, `lastInsertRowID`, `transaction`. The plan is to extract a
`DataStore` protocol with that shape and add a Data API implementation beside
the SQLite one. Roughly 73 SQL statements across ten repositories need dialect
work (`REAL` epochs → `timestamptz`, `AUTOINCREMENT` → `GENERATED AS IDENTITY`,
`?` → `$1`, date pairs → `daterange`).

Two practical notes:

- `Package.swift` declares `platforms: [.macOS(.v14)]` package-wide. It must be
  split so `VRCCore` builds for Linux while the UI target stays macOS-only.
- Swift 6.3.3 is installed and `swift sdk list` works, but **no SDK is
  installed**. Cross-compiling needs `swift sdk install` for the Static Linux
  SDK, which produces a static `aarch64` binary **without Docker** — this
  matters because you have Command Line Tools and no Xcode.

---

## 3. AWS architecture

```
                         ┌──────────────────────────────────────────┐
  Browsers               │  CloudFront + ACM                        │
  Mac / iPhone / iPad ──▶│  calendar.bostonfurnishedstays.com       │
                         │   /        → S3 (dashboard SPA)          │
                         │   /api/*   → API Gateway HTTP API        │
                         └───────────────┬──────────────────────────┘
                                         │ Cognito JWT authorizer
                                         │ (separate user pool)
                                         ▼
                              ┌─────────────────────┐
                              │  vrc-api  (Swift)   │
                              │  Lambda, arm64      │
                              └──────────┬──────────┘
                                         │ RDS Data API (HTTPS, no VPC)
  EventBridge schedules                  ▼
  ┌──────────────────┐        ┌──────────────────────────────────┐
  │ vrc-import  /3h  │───────▶│  Aurora Serverless v2            │
  │ vrc-sweeper /5m  │───────▶│  PostgreSQL 16.3+                │
  │ vrc-publish      │───────▶│  min 0 ACU — scales to zero      │
  └────────┬─────────┘        │  SYSTEM OF RECORD                │
           │                  └──────────────────────────────────┘
           │ read-only
           ▼
  ┌─────────────────────────────────────────────────────────┐
  │ Airbnb iCal │ Vrbo iCal │ Booking.com │ PriyankaHomes    │
  │             │           │ (revoked)   │ DynamoDB (RO)    │
  │             │           │             │ Google Cal (RO)  │
  └─────────────────────────────────────────────────────────┘
           │
           ▼ raw payloads for forensics
  ┌──────────────┐     ┌────────────────────────────────────┐
  │ S3 raw/      │     │ S3 feeds/ + CloudFront + ACM       │
  │ S3 snapshots/│     │ feeds.39gstboston.com              │
  │ (versioned)  │     │ one object per destination         │
  └──────────────┘     └────────────────────────────────────┘
                                     │ bearer URL
                                     ▼  Vrbo / Booking.com poll

  UNTOUCHED: PriyankaHomes Amplify app · its Cognito pool · its Terraform
             state · both DynamoDB tables (read-only) · the Google calendar
             (read-only) · bostonfurnishedstays.com records serving the site
  SEPARATE:  VRC IAM roles · VRC Terraform state key · VRC Cognito pool
```

### 3.1 The decision that shapes the bill: no VPC

Putting Lambda in a VPC to reach a database forces a NAT gateway for the
importer's outbound internet access — about **$32/month**, which would be the
largest line item in the whole system.

The **RDS Data API** is an HTTPS endpoint, so the Lambdas stay outside the VPC
entirely. No NAT gateway, no VPC endpoints, no subnets, no connection-pool
exhaustion from Lambda concurrency. The Data API is GA for Aurora PostgreSQL
and its free tier covers one million requests a month for the first year.

This is the single most consequential architectural choice here, and it is
driven by cost and operational simplicity rather than elegance.

### 3.2 Scale to zero, and the 15-second problem

Aurora Serverless v2 supports a minimum capacity of **0 ACU**, pausing after
inactivity. AWS documents resume as taking **up to 15 seconds**. That is fine
for a dashboard you open a few times a day. It is **not** fine inside a guest's
checkout on bostonfurnishedstays.com, which is Phase 4.

Rather than pay for constant warmth from the start, the design splits reads
from writes:

- **Guest-facing availability reads** come from a JSON snapshot on CloudFront,
  republished whenever availability changes. Always warm, ~20 ms, no database
  involved. A browsing guest never wakes the cluster.
- **The hold itself** is a transactional write to Postgres. It happens once,
  when someone actually commits to booking, and a one-time resume is survivable
  behind a progress indicator.

If that proves insufficient in practice, raising minimum capacity to 0.5 ACU is
a one-line change that buys constant warmth for about $44/month. I would not
pay it before Phase 4 proves it necessary.

### 3.3 Components

| Component | Choice | Note |
|---|---|---|
| Database | Aurora Serverless v2 PostgreSQL 16.3+, min 0 / max 4 ACU | 16.3 is the floor for 0-ACU |
| DB access | RDS Data API | keeps Lambdas out of a VPC |
| Compute | Swift on Lambda, `arm64`, static Linux SDK | preserves `VRCCore` |
| API | API Gateway HTTP API | $1.00/million |
| Auth | **separate** Cognito user pool | PriyankaHomes' pool untouched |
| Dashboard | static SPA on S3, served by CloudFront | same origin as `/api/*`, so no CORS |
| Feeds | S3 + CloudFront, `feeds.39gstboston.com` | 128-bit random object key |
| Secrets | Secrets Manager; DB credentials, feed tokens, source URLs | DB stores only a *reference* |
| Scheduling | EventBridge | import /3h, hold sweeper /5m |
| Raw payloads | S3, versioned, lifecycle-expired | forensics for any import dispute |
| IaC | Terraform, **separate state key** | PriyankaHomes state untouched |

Two continuity notes. The schema refuses to store a credential: both
`credential_ref` and `token_ref` carry a `CHECK` rejecting anything containing
`://`, verified to reject a real Airbnb iCal URL. And the dashboard being a
browser application means **no $99 Apple Developer enrolment** is needed to get
this onto your iPhone and iPad — which also removes the blocker that has been
sitting in front of the iOS/CloudKit branch.

---

## 4. Cost estimate

us-east-1, on-demand, verified against AWS pricing documentation on 2026-11-08.
Both Route 53 hosted zones (`bostonfurnishedstays.com`
`Z08918321EIN82TRAJSFY`, `39gstboston.com` `Z07332113NBDJM9Q3LU88`) **already
exist and are already being paid for**, so they are shown but are not new money.

### Phases 2–3 — building, database scales to zero

Assumes the cluster is awake about two hours a day: 24 imports, the hold
sweeper, and your own dashboard use.

| Item | Basis | Monthly |
|---|---|---|
| Aurora compute | 0.5 ACU × 60 h × $0.12 | $3.60 |
| Aurora storage | 1 GB × $0.10 | $0.10 |
| Aurora I/O | ~0.5 M × $0.20/M | $0.10 |
| RDS Data API | within 1 M/month free tier | $0 |
| Lambda | ~20 k invocations, 512 MB | $0 (free tier) |
| API Gateway HTTP API | ~30 k requests | $0.03 |
| S3 | < 1 GB, versioned | $0.05 |
| CloudFront | 2 distributions, < 5 GB | $0 (1 TB free tier) |
| ACM | 2 public certificates | $0 |
| Cognito | 1 user | $0 (10 k MAU free) |
| Secrets Manager | 4 secrets × $0.40 | $1.60 |
| CloudWatch | logs + 5 alarms | $0.60 |
| DynamoDB reads | ~4.5 k RRU | $0.01 |
| Route 53 | 2 zones — *already paid* | $1.00 |
| **Total** | | **≈ $7.09/month (≈ $85/year)** |
| **New money** | excluding the existing zones | **≈ $6.09/month (≈ $73/year)** |

### Phase 4 onward — three priced options

| Option | Shape | Monthly | Trade-off |
|---|---|---|---|
| **A (recommended)** | min 0 ACU + CDN-cached availability snapshot | **≈ $11** | up to 15 s resume on a real booking write |
| B | min 0.5 ACU, always warm | ≈ $47 | no cold start; ~$430/year more than A |
| C | RDS `db.t4g.micro` + Lambda in VPC + NAT instance | ≈ $24 | always warm and cheaper than B, but a VPC, a NAT instance to patch, and connection-pool management |

Option A is the recommendation, with B as a one-setting escape hatch if guest
latency turns out to matter more than the estimate suggests. Option C is
cheaper than B but reintroduces the operational surface that §3.1 was built to
avoid; I would take it only if constant warmth became mandatory *and* $47/month
were unacceptable.

For comparison: Lodgify, which this replaces, is in the tens of dollars a
month, and does not give you a database you own.

### Cost risks worth naming

- **Data API free tier is first-year only.** After that, ~$0.35/million
  requests. At our volume that is cents, but it is not permanently free.
- **The dominant variable is Aurora awake-time, not request volume.** Shortening
  the import interval from 3 h to 1 h roughly triples the compute line. The
  interval is a setting, so this is tunable after measurement.
- **Secrets Manager at $1.60/month** is more than Aurora storage and I/O
  combined. SSM Parameter Store `SecureString` is $0 and sufficient for static
  tokens; I have costed Secrets Manager because you approved it, and flag the
  alternative without acting on it.

---

## 5. Implementation sequence

Each phase ends at a gate. Nothing past a gate happens without your word.

### Phase 1 — architecture and migration plan · **this document** ✅
Schema designed and verified against PostgreSQL 17. Portability measured.
Google Calendar inventoried. Costs priced.
**Gate: your review. No AWS resources exist.**

### Phase 2 — backend and source adapters
1. Split `Package.swift`; install the Static Linux SDK; get `VRCCore` compiling
   for `aarch64` Linux. Replace `CryptoKit` with `swift-crypto` behind
   `#if canImport`.
2. Extract the `DataStore` protocol; add the Data API implementation; port the
   ten repositories' SQL.
3. **Run the existing 203 tests against PostgreSQL.** This is the real gate on
   the port: the suite is the evidence that behaviour did not change.
4. Four source adapters — Airbnb iCal, Vrbo iCal, Booking.com iCal (disconnected),
   website DynamoDB (read-only, calendar table only, per the previous phase's
   design).
5. Terraform for the whole stack, separate state key, `terraform plan` only.
**Gate: review the plan output. Nothing applied.**

### Phase 3 — dashboard
Unified month and week calendar across properties; continuous bars; the
"Show platform restrictions" toggle off by default; booking inspector; Block
Dates; Needs Review; conflict alerts in the three categories; sync status;
audit history. Responsive to ~400 px.
**Gate: review on your phone and iPad before anything is wired to production.**

### Phase 4 — direct website bookings
Website reads availability from the CDN snapshot; holds and confirmations go to
Postgres. The website's own booking logic is **not changed** until the
replacement is tested and you approve it. Both systems run in parallel with a
reconciliation report comparing them nightly.
**Gate: a clean parallel-run report before the website depends on VRC.**

### Phase 5 — reconcile and retire Google Calendar
Covered in [MIGRATION-PLAN.md](MIGRATION-PLAN.md). Read path first, write path
second, and only after the parallel run is clean.
**Gate: your approval to propose removal. Nothing removed in this phase.**

### Phase 6 — controlled outbound synchronisation
The two approved Vrbo decisions, Vrbo only, `isEnabled` flipped as a reviewed
code change rather than a UI toggle.
**Gate: explicit authorisation, as before.**

---

## 6. Safety rules, mapped to enforcement

Your eight rules, and where each is now enforced. "DB" means the database
refuses the operation regardless of application behaviour.

| Rule | Enforcement |
|---|---|
| Never export Airbnb cancellation penalty blocks | **DB** — `describes_genuine_unavailability` excludes `cancellation_block`; verified |
| Never treat unknown unavailable events as reservations | **DB** — `unknown_unavailable` does not block; verified |
| Never reopen confirmed bookings | **DB** — `no_double_booking`; reopen decisions are diffed against `blocking_intervals` |
| Never propagate booking-window restrictions | **DB** — `platform_restriction` does not block; verified |
| Never confuse temporary holds with confirmed reservations | **DB** — separate `holds` table, separate enum value, neither blocks export; verified |
| Never assume a published feed was imported | App — only `verified` implies remote synchronisation, from the destination's own export |
| Require explicit approval for outbound changes | **DB** — `approved_has_approver` CHECK; plus `FeedPublicationSafety` for additions *and* removals |
| Prevent feed clearing and circular imports | **DB** — one last-known-good per feed, and only a complete publication qualifies; app drops entries bearing our own marker |

Four of these moved from "the code is careful" to "the database refuses",
which is the main engineering gain of this phase.

---

## 7. Open questions for your review

1. **Phase 4 database warmth** — option A, B or C in §4. My recommendation is
   A, deferring the decision until Phase 4 measures real latency.
2. **Secrets Manager vs Parameter Store** — $1.60/month for rotation you do not
   use. Your call; I have not changed it.
3. **Import interval** — 3 hours is the cost/freshness default. Vrbo polls on
   its own schedule anyway, so faster imports have diminishing returns.
4. **The Roslindale calendars** — `ros1` and `ros2` exist in your Google account
   and are not referenced by the website. Are those future properties for this
   system? The schema is multi-property already; I have not assumed an answer.
