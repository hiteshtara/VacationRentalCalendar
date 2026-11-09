# Phase 2 readiness report

> **Superseded.** The schema this document describes was replaced because the
> repositories could not query it. See
> [`Migrations/postgres/superseded/README.md`](../Migrations/postgres/superseded/README.md)
> and the generated replacement, `010_repository_schema.sql`.


**No AWS resources created. No billable infrastructure exists.** Stopping here
for your approval, per instruction. `OutboundSyncGate.isEnabled` is `false`;
the two approved Vrbo decisions, seven events and seven classifications are
intact; 203 tests / 854 assertions pass.

Prepared 2026-11-08. Region `us-east-1`. Supersedes the cost section of
[CENTRAL-ARCHITECTURE.md](CENTRAL-ARCHITECTURE.md) §4.

---

## 0. Approved decisions, recorded

| # | Decision | Where it lands |
|---|---|---|
| 1 | PostgreSQL is the authoritative cloud database | §2 |
| 2 | Preserve tested Swift logic where practical | §2.3 — measured at ~94% |
| 3 | Defer warm-up / minimum-capacity optimisation until latency is measured | §1 — min 0 ACU, lever documented |
| 4 | Secrets Manager for private calendar credentials | §1, 3 secrets, $1.20/month |
| 5 | **15-minute scheduled imports** with backoff and rate-limit respect | §1.1, §2.4 — **this changed the cost model** |
| 6 | `ros1` / `ros2` are inactive future-property identifiers | [MIGRATION-PLAN.md](MIGRATION-PLAN.md) §6a |
| 7 | Do not migrate the two historical Google events | [MIGRATION-PLAN.md](MIGRATION-PLAN.md) §2.5 |

---

## 1. Verified AWS monthly cost

Every unit price below was read from the **AWS Pricing API** on 2026-11-08 for
`US East (N. Virginia)`, not from a pricing page or from memory.

| Service | Verified unit price |
|---|---|
| Aurora Serverless v2 (Aurora PostgreSQL) | **$0.12 per ACU-hour** |
| Aurora storage | **$0.10 per GB-month** |
| Aurora I/O | **$0.20 per million requests** |
| RDS PostgreSQL `db.t4g.micro` Single-AZ | **$0.016 per hour** |
| RDS `gp3` storage | **$0.115 per GB-month** |
| Secrets Manager | **$0.40 per secret-month** + $0.05 per 10,000 requests |
| S3 Standard | **$0.023 per GB-month** (first 50 TB) |
| API Gateway HTTP API | **$1.00 per million requests** |
| Amplify Hosting | **$0.01 per build-minute**, $0.15 per GB served, $0.023 per GB artifacts |
| CloudWatch alarm (standard) | **$0.10 per alarm-month** |
| CloudWatch Logs ingest | $0.50 per GB |
| Route 53 hosted zone | $0.50 per zone-month — **both zones already exist** |
| Lambda | free tier 1 M requests + 400,000 GB-s, **perpetual** |
| CloudFront | free tier 1 TB out + 10 M requests, **perpetual** |
| EventBridge scheduled rules | no charge |
| ACM public certificate | no charge |
| Cognito | no charge under 10,000 MAU |

### 1.1 Decision #5 changed the arithmetic, and I need to say so plainly

My Phase 1 estimate of ~$6/month assumed Aurora Serverless v2 would sit paused
most of the time. **A 15-minute import cadence breaks that assumption.**

Aurora's minimum auto-pause delay is **300 seconds**. So a poll that touches the
database costs roughly 30 seconds of work plus a 5-minute inactivity countdown
before it can pause — about 5.5 minutes of billed capacity per cycle. At 96
cycles a day that is **37% of the month awake, $16.74/month in compute alone**,
and scale-to-zero stops being worth anything.

The fix is not to slow the imports down. It is to **stop waking the database
for polls that contain no news.**

The fetcher is a Swift Lambda outside the VPC with no database access. It
fetches a feed, parses it, drops the volatile fields, hashes the resulting event
set, and compares that hash to the previous one stored in S3. Only if the hash
differs does anything touch Postgres. Airbnb and Vrbo calendars for one property
change a few times a day, not 96 times — so the database wakes on real changes
and sleeps through the rest.

This also means 15-minute freshness costs almost nothing, because the expensive
resource is database awake-time and the cheap one is an S3 `GET` plus a hash.

**One caveat, stated as a risk rather than a result.** iCal feeds commonly
regenerate `DTSTAMP` on every request, so a hash over raw bytes would differ
every single poll and change-detection would never fire. The hash must therefore
cover the **normalised parsed event set** — UID, start, end, summary, status —
with `DTSTAMP`, `PRODID` and property ordering excluded. I have **not** verified
which fields Airbnb and Vrbo actually vary, because doing so means fetching live
feeds. The first task in Phase 2 is to fetch each feed twice and diff it, which
settles this in minutes and determines which of the two columns below we land in.

### 1.2 Expected monthly cost

Assumptions, stated so you can challenge them: 4 sources × 96 polls/day =
11,520 fetches/month; the database woken ~10 times a day by real changes; 30
minutes a day of dashboard use; ~1 GB database, ~2 GB S3, ~1 GB logs/month.

| Item | Basis | Monthly |
|---|---|---|
| Aurora Serverless v2 compute | 42.5 h awake × 0.5 ACU × $0.12 | $2.55 |
| Aurora storage | 1 GB × $0.10 | $0.10 |
| Aurora I/O | 2 M × $0.20/M | $0.40 |
| RDS Data API | within 1 M/month free tier (first 12 months) | $0.00 |
| Lambda | 16,520 invocations, 512 MB — within perpetual free tier | $0.00 |
| EventBridge | 2,880 scheduled invocations | $0.00 |
| API Gateway HTTP API | 20,000 requests | $0.02 |
| S3 storage | 2 GB | $0.05 |
| S3 requests | 11,520 PUT + 20,000 GET | $0.07 |
| CloudFront | within perpetual free tier | $0.00 |
| Amplify Hosting | 30 build-min + 1 GB served + 0.5 GB artifacts | $0.46 |
| Secrets Manager | 3 secrets + 11,520 requests | $1.26 |
| CloudWatch Logs | 1 GB ingest | $0.50 |
| CloudWatch alarms | 6 standard | $0.60 |
| DynamoDB reads (website source) | ~4,500 eventually-consistent RRU | $0.01 |
| ACM / Cognito | 2 certificates, 1 user | $0.00 |
| **New money** | | **$6.01** |
| Route 53 | 2 zones — *already on your bill today* | $1.00 |
| **Total appearing on the bill** | | **$7.01** |

### 1.3 Worst case, if change-detection does not work

| Item | Monthly |
|---|---|
| Aurora compute — awake 279 h (37% of the month) | $16.74 |
| Everything else, unchanged | $3.46 |
| **New money** | **$20.20** |
| **Total on the bill** | **$21.20** |

**So: I can support ~$6/month for the expected configuration, and I will not
claim it as settled.** The honest statement is $6/month expected, $20/month if
feed volatility defeats change-detection, with the Phase 2 feed-diff test
deciding which — before any resource is created.

### 1.4 Charges that persist with no traffic at all

You asked for this explicitly. With the stack deployed and nobody using it:

| Item | Monthly |
|---|---|
| Aurora storage (compute is $0 at 0 ACU) | $0.10 |
| Secrets Manager, 3 secrets | $1.20 |
| S3 storage | $0.05 |
| CloudWatch Logs retention | $0.03 |
| CloudWatch alarms, 6 | $0.60 |
| Amplify build artifacts | $0.01 |
| **New money at zero traffic** | **$1.99** |
| Route 53, 2 zones — already paid | $1.00 |
| **Total on the bill at zero traffic** | **$2.99** |

Aurora compute, Lambda, API Gateway, CloudFront and EventBridge all genuinely
go to **$0.00** with no traffic. The irreducible floor is dominated by Secrets
Manager and CloudWatch alarms, neither of which scales down.

Two reductions available if you want the floor lower, neither of which I have
applied: consolidating the three secrets into one saves $0.80/month, and SSM
Parameter Store `SecureString` is $0 but has no rotation. Decision #4 says
Secrets Manager, so Secrets Manager is what I have costed.

### 1.5 The simpler alternative, priced honestly

| | Aurora Serverless v2 + Data API | RDS `db.t4g.micro` + split Lambdas |
|---|---|---|
| DB cost, expected | **$3.05** | $13.98 |
| DB cost, worst case | $17.24 | **$13.98** |
| DB cost at zero traffic | **$0.10** | $13.98 — billed whether used or not |
| Cold start | up to 15 s after a pause | none |
| VPC / NAT | **none needed** | VPC required; NAT avoided only by splitting the fetcher from the DB writer and using IAM database authentication |
| Connection pooling | not applicable | must be managed |
| Operational surface | cluster only | cluster, subnets, security groups, endpoints |

**Recommendation: Aurora Serverless v2, minimum 0 ACU, via the RDS Data API.**

It is 4.6× cheaper in the expected case, 140× cheaper while idle — which is
most of Phase 2, when there is no traffic at all — and needs no VPC. Its worst
case is only $3.26/month worse than the alternative's fixed price, so the
downside is bounded and small. Consistent with decision #3, minimum capacity
stays at 0 and raising it to 0.5 ACU remains a one-setting change if measured
latency ever justifies $43.80/month.

---

## 2. PostgreSQL deployment architecture

### 2.1 Cluster

| Setting | Value | Why |
|---|---|---|
| Engine | Aurora PostgreSQL **16.4** | 16.3 is the floor for 0-ACU; 16.4 for current patches |
| Capacity | Serverless v2, min **0** ACU, max **4** ACU | decision #3 |
| Auto-pause delay | 300 s (the minimum) | pauses as soon as permitted |
| Instances | 1 writer, no reader | single-writer workload |
| Multi-AZ | off initially | Aurora storage is already replicated across 3 AZs; a reader is a Phase 5+ question |
| Access | **RDS Data API** | keeps Lambdas out of a VPC |
| Networking | private subnets, no public access, no internet gateway route | the Data API is the only path in |
| Backups | 7-day automated, PITR on | reservation data |
| Deletion protection | **on** | |
| Encryption | at rest (KMS, AWS-managed) and in transit | |
| Credentials | Secrets Manager, referenced by ARN | Data API takes a secret ARN; no password in code or config |
| Parameters | `log_min_duration_statement=500ms`, `idle_in_transaction_session_timeout=30s` | a forgotten open transaction would hold the exclusion constraint and prevent pausing |

`idle_in_transaction_session_timeout` matters more than it looks: an abandoned
transaction both blocks concurrent bookings and keeps the cluster awake, so it
is a correctness *and* a cost control.

### 2.2 Schema

[`Migrations/postgres/001_central_schema.sql`](../Migrations/postgres/superseded/001_central_schema.sql)
— 17 tables, applied and exercised against a real PostgreSQL 17 instance.
Forward-only, tracked in `schema_migrations`.

### 2.3 Compute, and what stays Swift

Measured, not estimated: 7,069 of 10,449 lines of `VRCCore` are pure logic that
ports to Linux unchanged (~94% once `CryptoKit` is swapped for the
API-compatible `swift-crypto`). All SQL sits behind a seven-method interface on
`Database`, so Postgres is a second `DataStore` implementation.

| Lambda | VPC | Internet | Database | Schedule |
|---|---|---|---|---|
| `vrc-fetch` | no | **yes** | **none** | every 15 min |
| `vrc-process` | no | no | write, via Data API | on change only |
| `vrc-publish` | no | yes (CloudFront invalidation) | read | on approval / after change |
| `vrc-sweeper` | no | no | write | every 5 min |
| `vrc-api` | no | no | read/write | on request |

`vrc-fetch` holding no database credential at all is deliberate: the component
exposed to third-party feed content is the one that cannot write to the system
of record.

### 2.4 Import scheduling, backoff and platform policy

Decision #5 requires respecting platform policies and rate limits.

- **Cadence:** EventBridge every 15 minutes, staggered per source so four
  requests never leave at once.
- **Conditional requests:** `If-None-Match` / `If-Modified-Since`. A `304` ends
  the cycle before parsing — cheaper than hashing and kinder to the platform.
- **Backoff:** exponential with jitter on `429`, `503` and timeouts — 1, 2, 4,
  8, 16 minutes, capped at 60. Per-source, persisted, so a restart does not
  reset it into a hammer.
- **Circuit breaker:** five consecutive failures moves the listing to `failing`
  and drops it to hourly until one success.
- **Honouring `Retry-After`** when present, over our own backoff.
- **Disconnected sources are not polled at all:**
  `FeedConnectionState.shouldAttemptImport` is already false for `revoked`,
  `disconnectedByOwner` and `credentialUnreadable`. Booking.com stays
  `revoked` and costs nothing.
- **Never more than one in-flight request per source**, enforced by a
  conditional write so a slow fetch cannot overlap the next schedule.

So the effective rate per platform is 96 requests/day, most answered `304`.

---

## 3. Concurrency and reservation-locking design

The case that must never fail: two guests committing to overlapping dates at the
same moment, while an importer promotes an Airbnb reservation for the same
nights.

### 3.1 Five layers, outermost first

**1 — One hold row per booking, not one per night.** `holds.stay` is a
`daterange`, and

```sql
EXCLUDE USING gist (property_id WITH =, stay WITH &&) WHERE (released_at IS NULL)
```

means a single `INSERT` either takes the whole stay or none of it. There is no
partial-hold window to clean up. This is a genuine improvement on the website's
current per-night approach, which needs a transaction across N rows to get the
same guarantee. **Verified:** an overlapping live hold is refused; once released,
the same range is accepted.

**2 — `SERIALIZABLE` for booking admission.** The admission transaction reads
`blocking_intervals`, decides, and inserts. Snapshot isolation alone would allow
two transactions to each see a free range; `SERIALIZABLE` makes one fail with
`40001`.

**3 — The exclusion constraint as the backstop.** Even if isolation were
misconfigured, `no_double_booking` refuses the second overlapping confirmed
reservation. **Verified**, including that checkout-day adjacency is still
allowed — a guest leaving on the 17th and another arriving on the 17th is not a
conflict, and that is where a naive `BETWEEN` loses a night.

Note the constraint is keyed on `property_id`, the **physical unit** — not on
the channel. One flat listed on Airbnb, Vrbo, Booking.com and the website is one
`properties` row, so a confirmed Airbnb stay and a confirmed direct booking on
the same nights collide exactly as they should.

**4 — Advisory lock for publication.** `pg_advisory_xact_lock` keyed on the feed
id, so two publishers cannot race on last-known-good. Combined with
`idx_one_lkg_per_feed` and `lkg_must_be_complete` — both **verified** — a
half-published feed can never become the recovery point.

**5 — Optimistic concurrency on decisions.** Every state transition is
`UPDATE ... WHERE id = $1 AND status = $2` with a one-row assertion, so two
approvers cannot both approve.

### 3.2 Import promotion, and why a conflict is not an error

Imports write `source_events`, which has **no** exclusion constraint — two
channels genuinely can both claim the same nights, and that fact must be
recordable. A separate step promotes observations into `reservations`.

A promotion that trips `no_double_booking` **is** a real double booking. The
handler catches `23P01`, writes a `conflicts` row, and leaves the observation
unpromoted. One constraint serves as preventer for bookings we admit and
detector for bookings we merely observe.

### 3.3 Error handling

| SQLSTATE | Meaning | Response |
|---|---|---|
| `40001` | serialization failure | retry, exponential backoff, max 3 |
| `40P01` | deadlock | retry, max 3 |
| `23P01` | exclusion violation | **do not retry** — a real conflict; record and surface |
| `23505` | unique violation | idempotent replay; treat as success |

Imports are idempotent via `UNIQUE (listing_id, event_key)` and
`ON CONFLICT DO UPDATE`, so a retried import is a no-op. The sweeper is
idempotent by construction:
`UPDATE holds SET released_at = now() WHERE released_at IS NULL AND expires_at <= now()`.

### 3.4 No accidental reopening after upstream failures

Your explicit requirement, and the one that needs the most care, because the
dangerous direction is asymmetric: a feed missing a *block* is harmless, while a
feed missing a *reservation* can sell an occupied night.

1. A failed or empty import **writes nothing** — no `withdrawn_at` is set, so no
   event disappears and no feed shrinks.
2. Withdrawal requires a *successful* parse. Absence of an event in a failed
   fetch is not evidence of anything.
3. A **mass-withdrawal trigger** (to be added in Phase 2) refuses a transaction
   that would withdraw more than 50% of a listing's live events, unless a flag
   records that you authorised it. This makes "the feed came back empty" a
   database-level refusal rather than an application convention.
4. `FeedPublicationSafety` already requires approval for removals *and*
   additions, and refuses reductions attributed to a disconnected feed.
5. Publication cannot proceed at all while `outbound_sync_enabled` is `false`.

---

## 4. Deployment and rollback

### 4.1 Separation from PriyankaHomes

| | PriyankaHomes | VacationRentalCalendar |
|---|---|---|
| Terraform state | untouched | **separate S3 key**, separate lock table |
| IAM deploy role | untouched | `vrc-deploy`, scoped to VRC resources |
| IAM runtime roles | untouched | one per Lambda, least privilege |
| Cognito | untouched | **separate** user pool |
| Amplify app | untouched | **separate** app |
| Tagging | — | `Project=VacationRentalCalendar` on everything, for cost attribution |
| DynamoDB access | — | **read-only**, two table ARNs, `BatchGetItem` only |

Everything carries one tag so the bill can be read per project and the
estimates in §1 can be checked against reality.

### 4.2 Order, each step reversible

1. `terraform plan` reviewed by you. **Gate.**
2. S3 buckets, KMS, Secrets Manager (empty).
3. Aurora cluster, deletion protection on. **First billable resource.**
4. Apply `001_central_schema.sql` to an empty database; verify all 17 tables and
   every constraint.
5. Lambdas at version `$LATEST`, **schedules disabled**.
6. Run the full test suite against the real cluster.
7. Enable the sweeper only. Observe 24 h.
8. Enable imports. Observe 48 h. **Measure change-detection hit rate and
   confirm which cost column of §1 is real.**
9. Amplify dashboard, Cognito-gated, read-only.
10. Migration dry run, then the real migration inside one transaction.

Outbound publishing is untouched throughout. `isEnabled` stays `false`.

### 4.3 Rollback

| Failure | Rollback | Recovery time |
|---|---|---|
| Bad Lambda deploy | shift the alias to the previous version | < 1 min |
| Bad schema migration | forward-only fix; or PITR restore to a new cluster | minutes / < 1 h |
| Migration reconciliation mismatch | transaction aborts, nothing committed | immediate |
| Data corruption | PITR to a new cluster, repoint the Data API ARN | < 1 h |
| Cost overrun | disable EventBridge schedules; cost drops to the §1.4 floor | < 5 min |
| Total loss of confidence | the Mac app and its SQLite database are untouched and still work | immediate |

The Mac application remains a complete working fallback for the whole of Phase
2. Nothing in this plan modifies it.

A **budget alarm at $15/month** and a second at $30 are part of step 2, not an
afterthought — they are how a change-detection failure announces itself as a
notification rather than as a surprise on the bill.

---

## 5. Integrating PriyankaHomes direct bookings

The website keeps working throughout, and its booking logic is not changed until
you approve a tested replacement.

### 5.1 Stage 1 — observe only

VRC reads the website's calendar table read-only (`BatchGetItem` over an
explicit date horizon, calendar table only, no personal data, no writes ever)
and derives state exactly as `publicStatusFor` does: **a row with no `status`
means available.** Those rows are tombstones left by `REMOVE`, not blocks.
Treating them as blocks would withdraw nine genuinely free nights from sale.

Website behaviour: unchanged. VRC is a mirror.

### 5.2 Stage 2 — parallel running

Both systems compute availability independently. A nightly job reports every
night where they disagree, with each system's reason. **Fourteen consecutive
clean nights** is the gate.

Website behaviour: still unchanged.

### 5.3 Stage 3 — VRC serves reads

The website's availability display reads a CloudFront-cached JSON snapshot that
VRC republishes on change. Always warm, no database in the guest's browsing
path, so Aurora's 15-second resume never appears in a page load.

`assertGoogleAvailableForBooking` stays **fail-closed**, now against VRC's
snapshot as well as its current sources. This is the first change to website
behaviour and it needs your approval.

### 5.4 Stage 4 — VRC owns holds

A booking attempt calls VRC to take a hold: one `INSERT` into `holds`, whole
range or nothing. This is the only guest-path operation that can wake the
database, it happens once per genuine booking attempt, and it sits behind a
progress indicator.

Writes to DynamoDB continue in parallel, so the website can be reverted by
configuration alone.

### 5.5 Stage 5 — DynamoDB becomes the mirror

Only after a full booking cycle has been handled correctly end to end. Reversing
this is a configuration change, not a migration.

**Current state:** 4 bookings, all `hold_expired`; **0 confirmed, 0 active
holds.** There is no confirmed direct booking to preserve today — which lowers
migration risk and changes nothing about building the path correctly now, since
the next real booking must be handled right on its first day.

---

## 6. Tests required before production cutover

The existing 203 tests / 854 assertions must pass **against PostgreSQL**, not
just SQLite. That is the gate on the port: it is the evidence that behaviour did
not change. Beyond those, in the four categories you named.

### 6.1 Reconciliation

| # | Test | Pass condition |
|---|---|---|
| R1 | Row counts before/after migration | 7 events, 7 classifications, 2 decisions |
| R2 | **Publication UIDs** | the same two exact strings, not just the count |
| R3 | Decision fields | status, dates, reason, approver byte-identical |
| R4 | Night-by-night blocking set per platform | identical sets, not identical counts |
| R5 | Dec 17 and Dec 18 | **not** blocked on Vrbo |
| R6 | Cancellation blocks in `blocking_intervals` | zero |
| R7 | Platform restrictions in `blocking_intervals` | zero |
| R8 | Audit row order | preserved |
| R9 | DynamoDB tombstones | all 9 derive to available |
| R10 | 14-night parallel run | zero unexplained disagreements |

### 6.2 Concurrency

| # | Test | Pass condition |
|---|---|---|
| C1 | 50 concurrent holds on overlapping ranges | exactly one succeeds |
| C2 | Concurrent hold + import promotion, same nights | one succeeds; the other becomes a `conflicts` row, not a crash |
| C3 | Two approvers approve one decision | one succeeds, one gets a stale-state error |
| C4 | Two publishers, same feed | serialised by advisory lock; one last-known-good |
| C5 | Checkout-day adjacency under load | always accepted; never reported as a conflict |
| C6 | Hold expiry racing a confirmation | confirmation wins; dates never released under a paid guest |
| C7 | Sweeper running during a booking | no live hold released |
| C8 | `SERIALIZABLE` retry path | `40001` retried and succeeds; `23P01` not retried |

### 6.3 Failure recovery

| # | Test | Pass condition |
|---|---|---|
| F1 | Source returns HTTP 500 | no withdrawal, no feed change, backoff recorded |
| F2 | Source returns an empty calendar | **refused**; nothing withdrawn |
| F3 | Source returns 50% fewer events | mass-withdrawal trigger refuses it |
| F4 | Source times out mid-parse | transaction aborts; no partial import |
| F5 | Aurora paused when a request arrives | request succeeds after resume; no data loss |
| F6 | Aurora unreachable | API returns an honest error; never "available" |
| F7 | Secrets Manager unreachable | listing becomes `credentialUnreadable`; **working credentials untouched** |
| F8 | CloudFront invalidation fails | publication stops at `uploaded`, not counted as published |
| F9 | S3 write fails mid-publish | previous feed still served untouched |
| F10 | Lambda killed mid-transaction | no partial write; idempotent on retry |
| F11 | Booking.com stays revoked | not polled; removals still refused |
| F12 | Clock skew on hold expiry | holds never published regardless |

### 6.4 Rollback

| # | Test | Pass condition |
|---|---|---|
| B1 | Lambda alias rollback | previous version serves within 1 min |
| B2 | PITR restore to a new cluster | all 17 tables, all constraints, all data |
| B3 | Migration abort on mismatch | nothing committed; Aurora left empty |
| B4 | Disable schedules | cost falls to the §1.4 floor; no data change |
| B5 | Mac app after cloud rollback | still functional on untouched SQLite |
| B6 | Website revert from VRC reads to its own | configuration only; no data migration |

### 6.5 The one test that must run first

**Feed volatility.** Fetch each source twice, five minutes apart, and diff the
normalised event sets. If the hashes match, change-detection works and §1.2 is
the real cost. If they differ, identify the volatile fields and extend the
normalisation, or accept §1.3. This costs nothing, runs before any AWS resource
exists, and decides a $14/month question.

---

## 7. Booking-data correctness — where each requirement is enforced

"DB" means the database refuses the operation regardless of application
behaviour. "Verified" means tested against a real PostgreSQL instance.

| Requirement | Enforcement | Verified |
|---|---|---|
| No overlapping confirmed reservations for the same physical unit | **DB** — `no_double_booking` on `property_id`, the physical unit | ✅ |
| Checkout-exclusive date intervals | **DB** — `daterange` canonicalises to `[)`; `CHECK` rejects unbounded | ✅ |
| Separation of confirmed bookings and temporary holds | **DB** — separate table, separate enum value, neither exportable | ✅ |
| Rejection of cancellation penalty blocks from outbound feeds | **DB** — excluded from `blocking_intervals` | ✅ |
| Rejection of unknown and platform-restricted events | **DB** — both excluded; allow-list means new kinds are non-exportable by default | ✅ |
| Immutable audit history for ordinary application roles | **DB** — `UPDATE`/`DELETE` revoked on `availability_audit`; `DELETE` revoked on `source_events` | ✅ |
| No raw calendar credentials in database records | **DB** — `CHECK` rejects any value containing `://`; tested with a real Airbnb URL | ✅ |
| Explicit approval before outbound publication | **DB** — `approved_has_approver`; plus `FeedPublicationSafety` for additions and removals | ✅ |
| No accidental reopening after upstream failures | **DB** (mass-withdrawal trigger, Phase 2) + app — §3.4 | partly — trigger not yet written |

Eight of nine are enforced and verified today. The ninth is specified in §3.4
and is the first thing to build in Phase 2.

---

## 8. What I need from you

1. **Approve or reject the cost position** in §1: ~$6/month expected, ~$20/month
   if feed volatility defeats change-detection, resolved by a test that costs
   nothing and runs before any resource exists.
2. **Confirm Aurora Serverless v2** over `db.t4g.micro` (§1.5). My
   recommendation is Aurora on the strength of the $0.10 idle floor during
   Phase 2, with the alternative priced if you prefer predictability.
3. **Confirm 3 secrets** rather than 1 ($1.20 vs $0.40/month) — isolation
   against cost.
4. **Confirm branch layout** for Phase 2: `infra/terraform-foundation`,
   `backend/postgres-datastore`, `frontend/dashboard`, each its own PR.

Nothing is created until you answer 1 and 2.
