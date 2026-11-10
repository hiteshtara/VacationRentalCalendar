# Website bookings as a fourth source — investigation and design

**Nothing was created, changed, deployed or migrated.** Every AWS call in this
work was read-only (`describe-table`, `scan` with projections, `list-hosted-zones`),
and no write was issued against either PriyankaHomes table. `OutboundSyncGate.isEnabled`
is still `false`, the two approved Vrbo decisions and all seven manual
classifications are intact.

Investigated 2026-11-08, region `us-east-1`.

---

## 0. The correction that drove the rest of this design

My earlier reading of the calendar table was **wrong**, and it was wrong in the
dangerous direction. I reported nine rows as "orphaned remnants of expired holds
with no TTL that will never expire", and inferred that importing them would
block nine free nights.

The first half is factually right. The conclusion was backwards.

`publicStatusFor` in `src/lib/southBostonCalendar.ts` is the single derivation
the website itself uses:

```ts
if (!item) return 'available';
const active =
  item.status === 'confirmed' ||
  (item.status === 'held' && (item.holdExpiresAt === undefined || item.holdExpiresAt * 1000 > now));
return active ? 'unavailable' : 'available';
```

A row with **no `status` attribute returns `'available'`**. The nine bare
`{"date": "..."}` rows are not blocks. They are **tombstones** — the residue of
`REMOVE`, left behind by the three release paths:

| Function | Update expression | Leaves behind |
|---|---|---|
| `releaseHold` | `REMOVE #status, bookingId, holdExpiresAt, #ttl` | bare key row |
| `releaseConfirmedBooking` | `REMOVE #status, bookingId, holdExpiresAt, #ttl` | bare key row |
| `unblockDates` | `REMOVE #status, ownerBlockNote, holdExpiresAt, bookingId, #ttl` | bare key row |

DynamoDB has no way to remove the last attribute of an item other than deleting
the item, so a released night keeps its key forever. That is harmless by
construction, because availability is *derived* and never stored — exactly as the
code comment claims ("never a separate stored field, so there's exactly one
source of truth").

The observed data is fully explained by the cleanup sweep in
`src/app/api/internal/south-boston-cleanup/route.ts`:

1. `listExpiredHolds` finds bookings still `held` past `holdExpiresAt`.
2. `updateBookingStatus(..., {status: 'hold_expired', expectedStatus: 'held'})` —
   conditional, so a payment landing mid-sweep is left alone.
3. `releaseHold` on `reservedNights(checkIn, checkOut)` for that booking.

Four bookings, all `hold_expired`; their nights released to tombstones. The
nights `2026-08-24`..`08-27` are absent entirely rather than tombstoned, which
is consistent with DynamoDB TTL having deleted those items while the hold was
still live (TTL is set only on an active hold) before the sweep reached them —
`releaseHold`'s `ConditionExpression` then found no item and wrote nothing. I
have not proven that race; I am labelling it a hypothesis. **It does not matter**,
and that is the point: a missing row and a tombstoned row both derive to
`available`, so the two cleanup paths cannot disagree.

**The real risk is the inverse of what I reported.** The inventory-destroying
mistake would be for this app to treat *row existence* as unavailability. Nine
free nights would be blocked on Vrbo and Booking.com — the precise failure this
project exists to prevent, arrived at from a new direction. Deliverable 2 is
built around not making it.

---

## 1. Website booking lifecycle and data model

### 1.1 Tables

| | `priyankahomes-south-boston-bookings` | `priyankahomes-south-boston-calendar` |
|---|---|---|
| Partition key | `bookingId` (S) | `date` (S), `YYYY-MM-DD` |
| Sort key | none | none |
| GSI / LSI | **none** | **none** |
| Stream | **disabled** | **disabled** |
| TTL | **disabled** | **enabled on `ttl`** |
| Billing | `PAY_PER_REQUEST` | `PAY_PER_REQUEST` |
| Items / bytes | 4 / 5,957 | 10 / 490 |

No GSI means status lookups are a full `Scan` plus a client-side filter —
`listBookingsByStatus` does exactly that, with a comment accepting it at pilot
volume. That constrains the integration design (§2.2).

### 1.2 Booking statuses

Thirteen, from the union in `src/lib/southBostonBooking.ts`. Grouped by what
they mean for *occupancy*, which is the only question this app asks:

| Group | Statuses | Holds dates? |
|---|---|---|
| **Confirmed reservation** | `confirmed`, `confirmed_balance_due`, `balance_overdue` | **Yes** |
| **Provisional hold** | `held`, `payment_pending`, `deposit_pending` | Yes, but expiring |
| **Released** | `hold_expired`, `payment_failed`, `cancelled`, `refunded` | No |
| **Indeterminate** | `manual_review`, `refund_pending`, `refund_failed` | Unresolved — needs a human |

`balance_overdue` belongs with the confirmed group, not the released group. The
source comment is explicit: *"an unpaid balance never releases a guest's dates
automatically (see cancelBooking, the only path that ever does)."* An overdue
balance is a billing problem; the guest still has the dates. Reading
`balance_overdue` as "available" would double-book a paying guest.

`CANCELLABLE_PRE_PAYMENT_STATUSES = ['held','payment_pending','deposit_pending']`
and `CANCELLABLE_POST_PAYMENT_STATUSES = ['confirmed_balance_due','balance_overdue','confirmed']`
corroborate the split.

### 1.3 Holds and expiry

- Window: `SOUTH_BOSTON_HOLD_WINDOW_SECONDS = 15 * 60` — fifteen minutes.
- `attemptHold` writes `status=held, bookingId, holdExpiresAt, ttl=holdExpiresAt`
  per night, with a condition allowing the write when the row is absent, already
  held by the same booking, or held by an **expired** hold. Any night failing the
  condition fails the whole range: no partial holds.
- `confirmBookingPaid` does `SET #status = :confirmed REMOVE holdExpiresAt, #ttl`
  conditional on `bookingId`. **A confirmed night carries no TTL**, so
  confirmation is what makes a block durable. This is the correct design and it
  means TTL can never silently delete a real reservation.
- Three expiry paths, in order of authority: the Stripe webhook, the scheduled
  cleanup sweep, and DynamoDB TTL as a backstop that correctness never depends on.

Expired holds are therefore **not permanent**, and three independent mechanisms
guarantee it.

### 1.4 Owner blocks

`blockDates` writes `SET #status = :confirmed, ownerBlockNote = :note REMOVE holdExpiresAt, bookingId, #ttl`.
So an owner block is distinguishable from a guest reservation by the presence of
`ownerBlockNote` and the **absence** of `bookingId`. `unblockDates` is guarded by
`ConditionExpression: 'attribute_not_exists(bookingId) OR bookingId = :empty'`,
so an owner cannot accidentally unblock a guest's night.

### 1.5 Date conventions

`reservedNights(checkIn, checkOut)` iterates `cursor < end` in UTC — a **half-open
interval**, check-in occupied, checkout released. This is the same convention
`DateInterval` already uses in `VRCCore`. No translation layer is needed, which
removes the single likeliest source of off-by-one inventory loss.

Verified against live data: booking `2026-09-01 → 2026-09-05` produced calendar
rows for `09-01, 09-02, 09-03, 09-04` and not `09-05`.

### 1.6 Relationship between the two tables

The bookings table is the **ledger**; the calendar table is a **derived per-night
index** maintained by conditional writes. `bookingId` on a calendar row is the
join key. The calendar table is not a cache — it is where the atomicity lives
(the all-or-nothing hold), so it is authoritative for *availability* while the
bookings table is authoritative for *lifecycle*.

One consequence matters a great deal for us: **the calendar table contains no
personal data at all.** Its attribute set is `date`, `status`, `bookingId`,
`holdExpiresAt`, `ttl`, `ownerBlockNote`. The bookings table does carry
`guestName` and `guestEmail`.

### 1.7 A fifth source, already present

`getCombinedPublicCalendar` merges DynamoDB with **Google Calendar**
(`getGoogleBusyNights`), and `assertGoogleAvailableForBooking` is a fail-closed
pre-hold gate. So the website's own notion of availability is already
`DynamoDB ∪ Google`. A night busy only in Google Calendar would be invisible to
an integration that read DynamoDB alone. Flagged as a gap in §6.

---

## 2. Read-only integration design

### 2.1 The principle

Website reservations become a **fourth source**, peers of Airbnb, Vrbo and
Booking.com — not a privileged truth. They land as source events, get a
classification, and are subject to the same availability-decision machinery and
the same export gate. The three-concept separation is unchanged:

```
source events  →  availability decisions  →  published events
 (imported)        (owner-approved)          (gate + generator)
```

### 2.2 Read strategy: BatchGetItem over an explicit horizon, never Scan

VRC reads the **calendar table only**, via `BatchGetItem` on a computed list of
date keys covering today through +18 months (≈550 keys, 6 batches of 100).

Three reasons this beats `Scan`:

1. **It reads no personal data.** The calendar table has none. The guest's name
   and email never enter this application, which is a stronger guarantee than
   redacting them after the fact.
2. **Cost and latency are independent of table size.** Tombstones accumulate
   forever; a `Scan` grows without bound while a keyed horizon does not.
3. **It is the same access pattern the website uses.** `getPublicCalendar` also
   builds an explicit date list and calls `batchGetAllDates`. Sharing the access
   pattern means sharing its tested assumptions.

The bookings table is read **only** when a calendar row needs lifecycle context
it cannot supply — and then with a `ProjectionExpression` restricted to
non-personal attributes:

```
#st, bookingId, checkIn, checkOut, nights, createdAt, updatedAt, cancelledAt, holdExpiresAt
  with ExpressionAttributeNames {"#st": "status"}
```

`status` and `ttl` are DynamoDB reserved words and must be aliased.

Even this is optional for v1. Everything needed to classify a night is on the
calendar row itself, so **v1 reads the bookings table not at all.** Least
privilege, enforced by not asking.

### 2.3 Derivation, copied rather than reinvented

The importer ports `publicStatusFor` into Swift verbatim in behaviour, including
the `holdExpiresAt === undefined` branch:

```swift
enum WebsiteNightState { case available, confirmedGuest, ownerBlock, activeHold(expires: Date) }

static func state(of row: WebsiteCalendarRow?, now: Date) -> WebsiteNightState {
    guard let row, let status = row.status else { return .available }   // absent OR tombstoned
    switch status {
    case "confirmed":
        return row.ownerBlockNote != nil && row.bookingId == nil ? .ownerBlock : .confirmedGuest
    case "held":
        guard let expires = row.holdExpiresAt else { return .activeHold(expires: .distantFuture) }
        return expires > now ? .activeHold(expires: expires) : .available
    default:
        return .available          // unknown status is never treated as a block
    }
}
```

Two deliberate choices:

- **`guard let status else return .available`** is the single line that prevents
  the §0 failure. A tombstone and an absent row take the same branch, and a test
  asserts it against the nine real tombstone dates.
- **An unrecognised `status` derives to `.available`, not to a block.** If
  PriyankaHomes adds a status this app has not seen, the failure is a night left
  on sale — recoverable — rather than a night silently withdrawn from three
  platforms. It is also raised for review, so it does not stay unnoticed.

### 2.4 Classification mapping

| Website state | `BlockKind` | `describesGenuineUnavailability` | Eligible for publication |
|---|---|---|---|
| `confirmedGuest` | `confirmedReservation` | yes | yes, with an approved decision |
| `ownerBlock` | `ownerBlock` | yes | yes, with an approved decision |
| `activeHold` | **new** `provisionalHold` | **no** | **never** |
| `available` | — no event created | — | — |

`provisionalHold` is a new `BlockKind` case, not a reuse of an existing one. A
fifteen-minute hold must be **visible** in the calendar (so the owner is not
confused by a night the website shows as taken) and must **never** propagate to
another platform: by the time Vrbo polled, the hold would in all likelihood have
expired, and the app would have blocked a night that was never sold. Returning
`false` from `describesGenuineUnavailability` puts it behind the same wall as
`cancellationBlock` and `platformRestriction`.

Holds are therefore separate from confirmed reservations at the type level, not
by a flag that a later code path could forget to check.

### 2.5 Reconciliation, not accumulation

Each import replaces the website source's event set for the horizon window
wholesale, because the website's state is *derivable in full* on every read —
unlike an iCal feed, where absence is ambiguous. A night that moves from
`confirmedGuest` to `available` (a cancellation) therefore disappears from the
source set on the next import.

That is exactly a feed **reduction**, and it routes into the existing
`FeedPublicationSafety` machinery: it requires removal approval and is refused
outright if the source looks unreliable. A cancelled website booking does not
silently reopen a night on Vrbo. The owner approves it.

### 2.6 Absolutely no writes

- IAM: a dedicated read-only role with `dynamodb:BatchGetItem` and
  `dynamodb:DescribeTable` on exactly those two table ARNs. No
  `PutItem`/`UpdateItem`/`DeleteItem`, no wildcard. Enforced by policy, not by
  code discipline.
- A second, independent guard in the client itself: the DynamoDB client used for
  these tables rejects any non-`BatchGetItem`/`Query`/`GetItem` operation before
  signing, so a future coding mistake cannot reach the network.
- Hold expiry, cancellation and cleanup stay entirely the website's
  responsibility. This app observes and never participates.

---

## 3. Cloud persistence: recommendation

The question is whether SQLite on the Mac should remain the system of record.
Four options, judged against concurrent imports, user edits, approval history,
rollback, recovery, cost and migration complexity.

| | **A. SQLite on Mac + versioned S3 snapshots** | **B. SQLite file in S3** | **C. DynamoDB as system of record** | **D. Managed SQL (Aurora Serverless v2 / RDS)** |
|---|---|---|---|---|
| Concurrent imports | Single writer, serialised in-process | **Corrupts** — no locking over object storage | Conditional writes per item | Real transactions |
| User edits | Local, immediate | Unsafe | Needs app-side consistency | Transactional |
| Approval history | Existing append-only audit table | — | Fits well (append-only items) | Fits well |
| Rollback | `VACUUM INTO` + S3 object versions | — | Manual; PITR extra | Snapshots + PITR |
| Recovery | Restore an S3 version | — | PITR | PITR |
| Cost | **~$0** | ~$0 | ~$0 at this volume | **$12–45/mo** |
| Migration effort | **none** | — | **High — discards the tested SQL layer** | Moderate — schema ports, some SQL dialect work |
| Swift logic preserved | **entirely** | — | no | mostly |

**Option B is not viable and should be struck from consideration.** SQLite
assumes byte-range locking on a POSIX file; S3 offers neither. Two writers
produce a corrupt database, and a single writer gains nothing over option A.
Litestream-style replication is really option A with a different snapshot
format.

**Recommendation: option A now; option D only if and when a cloud writer is
genuinely required.**

The reasoning is that there is currently exactly **one writer** — this Mac — and
no second writer is proposed. PriyankaHomes owns its own tables and this app
only reads them. Moving the system of record to the cloud would buy concurrency
control for a concurrency problem that does not exist, at the cost of
rewriting a persistence layer that 203 tests currently hold in place. The user's
own constraint — *do not discard the existing tested Swift business logic* — and
the engineering reality point the same way.

### 3.1 What option A actually adds

1. **Versioned S3 snapshots.** After each import or decision change, `VACUUM INTO`
   a consistent copy (the WAL-sidecar trap I hit earlier makes this mandatory —
   copying the `.sqlite` file alone reads stale data) and `PutObject` to a
   versioned, SSE-encrypted bucket with lifecycle expiry. Recovery is restoring
   an object version.
2. **A published decisions manifest.** A small signed JSON document — approved
   decisions and their intervals — written to S3 alongside the feed.

### 3.2 The honest limit this does not fix, and the one thing that would

Option A leaves the staleness window intact: a website booking taken at 2am
while the Mac is asleep does not reach Vrbo until the Mac wakes. That is the
real argument for cloud infrastructure, and it deserves a straight answer rather
than being dismissed.

It can be fixed **without** moving the system of record, because feed generation
is a pure function:

```
feed = render(approved decisions manifest, live source events)
```

A scheduled Lambda can re-render the feed from the manifest plus a fresh read of
the four sources while the Mac sleeps. It needs **read** access to the manifest
and the sources, and **write** access only to the feed object. It cannot create,
alter or approve a decision — the human gate stays on the Mac, where
`AvailabilityManager` and its transition table live.

This preserves the project's central invariant (publication requires a prior
owner approval) while removing the unbounded-staleness failure. It is the
natural Phase E, and it is deliberately **not** part of this design.

---

## 4. Revised cost

Two corrections to the figures in `HOSTING-PROPOSAL.md` and
`VRBO-LIVE-TEST-PLAN.md`, both found by checking rather than assuming:

- **Both Route 53 hosted zones already exist** — `bostonfurnishedstays.com`
  (`Z08918321EIN82TRAJSFY`) and `39gstboston.com` (`Z07332113NBDJM9Q3LU88`). The
  ~$10/year domain I costed as the dominant line item is already paid, and no
  new zone is needed for `feeds.39gstboston.com`.
- **Both DynamoDB tables are `PAY_PER_REQUEST`**, so integration reads cost
  fractions of a cent and require no capacity planning.

| Item | Usage | Monthly | Annual |
|---|---|---|---|
| Route 53 hosted zones | 2, **already existing** | $1.00 | $12.00 |
| S3 storage (feeds + snapshots) | < 50 MB versioned | ~$0.01 | $0.12 |
| S3 requests | ~2,000/month | ~$0.01 | $0.12 |
| CloudFront | ~500 MB, ~20k requests | $0 (free tier: 1 TB, 10M req) | $0 |
| ACM certificate | 1, public | $0 | $0 |
| DynamoDB on-demand reads | ~4,500 BatchGet item-reads/month | < $0.01 | ~$0.02 |
| Secrets Manager | 3 secrets @ $0.40 | $1.20 | $14.40 |
| CloudWatch logs/alarms | minimal | ~$0.10 | $1.20 |
| **Total (feeds + integration)** | | **~$2.33** | **~$28** |

Marginal cost over what the existing website already pays: **about $16/year**,
since the two hosted zones are already on the bill.

Two notes worth your judgement:

- **Secrets Manager is now the single largest new line item** at $14.40/year —
  more than everything else combined. **SSM Parameter Store (Standard) with a
  `SecureString` is $0** and is functionally sufficient for three static feed
  tokens; it lacks automatic rotation, which these tokens do not use (rotation
  here means writing a new object key and re-pasting the URL). You approved
  Secrets Manager and I have costed it as approved — but if $14/year for
  unused rotation is not worth it, Parameter Store is the cheaper equivalent.
  Your call, not a change I would make unilaterally.
- A Lambda publisher (§3.2, not in scope) would stay inside the free tier at
  ~720 invocations/month.

Still an order of magnitude below the channel manager this replaces.

---

## 5. Updated architecture

```
  INBOUND SOURCES (all read-only)
  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌───────────────────────────┐
  │ Airbnb iCal  │ │  Vrbo iCal   │ │ Booking.com  │ │  WEBSITE  (4th source)    │
  │              │ │              │ │ DISCONNECTED │ │  DynamoDB BatchGetItem    │
  │ URL: Keychain│ │ URL: Keychain│ │ no retries   │ │  calendar table only      │
  └──────┬───────┘ └──────┬───────┘ └──────┬───────┘ └─────────────┬─────────────┘
         │                │                │                       │ no PII read
         └────────────────┴────────┬───────┴───────────────────────┘ no writes ever
                                   │
                    ┌──────────────▼───────────────┐
                    │  SOURCE EVENTS  (immutable)  │   publicStatusFor ported:
                    │  SQLite — system of record   │   no status ⇒ AVAILABLE
                    └──────────────┬───────────────┘
                                   │
                    ┌──────────────▼───────────────┐
                    │  CLASSIFICATION              │  confirmedReservation
                    │  never auto-reclassified     │  ownerBlock
                    │                              │  cancellationBlock      ✗ never exported
                    │                              │  platformRestriction    ✗ never exported
                    │                              │  provisionalHold  (NEW) ✗ never exported
                    └──────────────┬───────────────┘
                                   │
                    ┌──────────────▼───────────────┐
                    │  AVAILABILITY DECISIONS      │  DRAFT → VALIDATED →
                    │  per platform, owner-approved│  AWAITING_APPROVAL → PUBLISHED
                    │  R1–R10 + append-only audit  │  → AWAITING_REFRESH → VERIFIED
                    └──────────────┬───────────────┘
                                   │
                    ┌──────────────▼───────────────┐
                    │  OutboundSyncGate            │   isEnabled = false  ← TODAY
                    │  re-derives from scratch     │   additions AND removals
                    │  FeedPublicationSafety       │   both need approval
                    └──────────────┬───────────────┘
                                   │  (nothing passes today)
         ┌─────────────────────────┼─────────────────────────┐
         ▼                         ▼                         ▼
  ┌─────────────┐          ┌─────────────┐          ┌─────────────────┐
  │ S3 versioned│          │ S3 feeds    │◀─────────│ CloudFront +    │
  │ DB snapshots│          │ + manifest  │          │ ACM             │
  │ (recovery)  │          │             │          │ feeds.39gst…    │
  └─────────────┘          └─────────────┘          └────────┬────────┘
                                                             │ bearer URL
                                                             ▼
                                                   Vrbo / Booking.com poll

  ─────────────────────────────────────────────────────────────────────
  UNTOUCHED:  PriyankaHomes Amplify app · its Cognito pool · its Terraform
              state · both DynamoDB tables (read-only) · bostonfurnishedstays.com
              DNS records serving the live site
  SEPARATE:   VRC IAM roles · VRC Terraform state key · VRC Cognito pool
              (if ever needed) · VRC Amplify app (if ever needed)
```

The website's own availability path is unchanged and does not consult this app:

```
  Guest browsing → getCombinedPublicCalendar(DynamoDB ∪ Google Calendar)
  Guest booking  → assertGoogleAvailableForBooking (fail-CLOSED) → attemptHold
```

---

## 6. Risks and safeguards

| # | Risk | Severity | Safeguard |
|---|---|---|---|
| 1 | Tombstoned rows read as blocks, withdrawing free nights from sale | **Critical** | Derivation keyed on `status`, never on row existence; test asserts the nine real tombstone dates derive to available (§2.3) |
| 2 | A 15-minute hold published to Vrbo, blocking a night never sold | High | New `provisionalHold` kind, `describesGenuineUnavailability == false`, excluded at the gate and again at generation |
| 3 | `balance_overdue` misread as released, double-booking a paying guest | High | Mapped to confirmed; source comment is explicit that only `cancelBooking` releases dates |
| 4 | A write reaching a production PriyankaHomes table | **Critical** | Read-only IAM policy scoped to two ARNs; plus an operation allow-list in the client before signing |
| 5 | Guest personal data entering this app | High | v1 reads the calendar table only, which has no personal attributes; bookings-table reads, if ever added, carry a non-PII `ProjectionExpression` |
| 6 | **Google-only busy nights invisible** (§1.7) | Medium | **Unmitigated and out of scope.** The website treats availability as DynamoDB ∪ Google; this integration sees only DynamoDB. A night blocked solely in Google Calendar would appear available here. Must be stated in the UI as a known gap, or Google added as a fifth source. |
| 7 | A website cancellation silently reopening a night on Vrbo | Medium | Reconciliation surfaces it as a reduction → removal approval required → refused if the source looks unreliable |
| 8 | An unknown future booking status misclassified | Medium | Unknown derives to available (fails toward on-sale, which is recoverable) and is raised for review |
| 9 | A `Scan` growing without bound as tombstones accumulate | Low | Keyed `BatchGetItem` over a bounded horizon; cost independent of table size |
| 10 | Stale feed while the Mac sleeps | Medium | **Not fixed by this design.** Documented honestly in §3.2; the Lambda re-render is the fix and is deliberately deferred |
| 11 | Reserved-word collisions (`status`, `ttl`) breaking expressions | Low | `ExpressionAttributeNames` aliases mandatory; caught by integration tests against the live tables |
| 12 | Clock skew flipping a hold's expiry | Low | Holds never publish regardless, so skew cannot cause an incorrect block |

Risks 6 and 10 are the two I cannot close within this scope, and both are listed
as unmitigated rather than reframed as acceptable.

---

## 7. Migration and test strategy

No production data is migrated. The SQLite database stays where it is; the
website keeps its tables. "Migration" here means adding a source and some AWS
plumbing, in an order where each step is independently reversible.

### Phase W1 — read path, offline (no AWS calls)
Schema migration 13 adds a `website` source and the `provisionalHold` kind.
Port `publicStatusFor`. Tests run against **recorded fixtures** of the real rows,
including all nine tombstones, the 2099 sentinel, and the absent `08-24`..`08-27`
range. No network, no credentials. Reversible: forward-only migration adding
nullable columns; no existing row is rewritten.

### Phase W2 — live read, import disabled
Real `BatchGetItem` against the live tables under the read-only role, writing to
a `VACUUM INTO` sandbox database — the isolation I had to add after an earlier
rehearsal wrote into the production database. Assert `RehearsalIsolation`, then
diff: the seven existing events and seven manual classifications must be
byte-identical afterwards.

### Phase W3 — import enabled, publication still gated
Website events become real source events. `OutboundSyncGate.isEnabled` stays
`false`. Assert zero decisions are created automatically and that the two
approved Vrbo decisions are untouched.

### Phase W4 — S3 snapshots
Versioned snapshot upload and a restore drill. Reversible by deleting a bucket.

### Phase W5 — not now
Lambda re-render (§3.2), and `isEnabled = true`. Both need your explicit word.

### Tests to add

| # | Test | Asserts |
|---|---|---|
| 1 | `tombstonedRowIsAvailable` | all nine real tombstone dates → `.available` |
| 2 | `absentRowIsAvailable` | `08-24`..`08-27` → `.available` |
| 3 | `sentinelRowIsAvailable` | `2099-01-15` → `.available` |
| 4 | `confirmedWithBookingIdIsReservation` | → `confirmedReservation` |
| 5 | `confirmedWithOwnerNoteIsOwnerBlock` | `ownerBlockNote` + no `bookingId` → `ownerBlock` |
| 6 | `activeHoldIsProvisional` | future `holdExpiresAt` → `provisionalHold` |
| 7 | `expiredHoldIsAvailable` | past `holdExpiresAt` → `.available` |
| 8 | `heldWithoutExpiryIsHold` | missing `holdExpiresAt` → hold (mirrors the TS branch) |
| 9 | `balanceOverdueHoldsDates` | → genuine unavailability |
| 10 | `unknownStatusIsAvailableAndFlagged` | unknown → available **and** review-flagged |
| 11 | `provisionalHoldNeverExported` | gate and generator both exclude it |
| 12 | `checkoutNightExcluded` | `09-01→09-05` yields four nights, not five |
| 13 | `websiteClientRejectsWrites` | any write operation throws before signing |
| 14 | `projectionExcludesPII` | `guestName`/`guestEmail` never requested |
| 15 | `cancellationRequiresRemovalApproval` | reduction → `requiresRemovalApproval` |
| 16 | `importPreservesExistingClassifications` | the seven stay unchanged |
| 17 | `vacuumIntoSnapshotIsConsistent` | snapshot includes WAL contents |
| 18 | `importDoesNotTouchProductionDB` | `RehearsalIsolation.assertIsolated` |

Nine of these (1, 2, 3, 7, 8, 10, 11, 12, 13) exist specifically to prevent the
§0 mistake from being re-made by a future change.

---

## Verified state at the end of this investigation

Read from a `sqlite3 .backup` copy of the live database, so the WAL contents are
included:

```
availability_decisions  = 2    approved = 2    published = 0
classifications         = 7    events   = 7
feed_publications       = 0    feed_snapshots = 0    published_feed_entries = 0
schema_migrations (max) = 12
feed_publication_scope  = approved_manual_blocks_only
ExportPolicy.swift:133  public static let isEnabled = false
```

Both approved decisions, unchanged:

```
1: 2026-12-10 -> 2026-12-17   vrbo / block / approved
2: 2026-12-19 -> 2026-12-20   vrbo / block / approved
```

December 17 and 18 remain excluded and sellable, which is the point of the test.

Test suite: **203 tests, 854 assertions, all passing** — unchanged, since this
phase added no code. PriyankaHomes tables: **0 writes issued.**

## What was explicitly not done

No AWS resources created. No DNS changed. Nothing deployed. No production data
migrated. Outbound synchronisation still disabled. No write of any kind against
either PriyankaHomes table. Both approved Vrbo decisions and all seven
classifications preserved.
