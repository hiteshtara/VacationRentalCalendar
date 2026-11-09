# Phase 1 — migration plan, reconciliation, and Google Calendar retirement

**Design for review. Nothing was migrated, changed, or removed.** Every Google
Calendar and AWS call in this work was read-only. No write was issued against
Google Calendar, either PriyankaHomes DynamoDB table, or the live website.

Prepared 2026-11-08. Companion to [CENTRAL-ARCHITECTURE.md](CENTRAL-ARCHITECTURE.md).

---

## 1. What must survive, and how each is carried

| # | Must be preserved | Mechanism |
|---|---|---|
| 1 | Seven imported events | `source_events.legacy_id` holds the SQLite `events.id`; counted before and after |
| 2 | Seven manual classifications | `classifications.locked = true`; a CHECK makes an owner decision unlockable-by-accident impossible |
| 3 | Two approved Vrbo decisions | `availability_decisions.legacy_id`; status, dates, reason and approver copied verbatim |
| 4 | **Existing publication UIDs** | `publication_uid` copied **verbatim**, never regenerated — see §1.1 |
| 5 | Audit history | appended in order; the table rejects `UPDATE`/`DELETE` for the app role |
| 6 | PriyankaHomes confirmed direct bookings | there are currently **none** (§3.2); the import path is built and tested regardless |
| 7 | Valid website availability restrictions | reconciled night-by-night against DynamoDB and Google (§4) |

### 1.1 Why publication UIDs are copied, not regenerated

A destination platform keys an iCal entry by its `UID`. If a UID changes, Vrbo
does not see an updated block — it sees the old entry **deleted** and a new one
created. Mid-season, against a platform that polls on its own schedule, that is
a window in which nights can appear to reopen.

So `publication_uid` is migrated byte-for-byte and carries a `UNIQUE`
constraint. Reconciliation asserts the exact string, not just the count.

---

## 2. Google Calendar inventory

Calendar: **South Boston Availability**
(`9d1192112bb055f02eb8e184560cb04b5aad862f69f1b32de336c36f41f202c6@group.calendar.google.com`),
time zone `America/New_York`. Read-only via the Calendar API. Four calendars
exist in the account; this is the only one the website references.

### 2.1 The complete contents

Queried 2024-01-01 → 2027-12-31. The calendar contains **exactly two events**,
and **both are already in the past**.

| | Event | Span | Nights | Origin |
|---|---|---|---|---|
| A | untitled, all-day (`5d2vvffi2an4toguj0s0lhq5rc`) | 2026-08-24 → 2026-10-01 (exclusive) | 38 | created by you, 2026-08-24 21:31 UTC |
| B | a 30-minute personal appointment (`7e8luq579pl1e47fp5bte1g8g8`) | 2026-10-26, 15:45–16:15 EDT | 1 | created by you, 2026-10-21 |

Three findings follow, and they make retirement far simpler than expected.

**Google Calendar currently restricts zero future nights.** Today is
2026-11-08; the later of the two events ended 2026-10-26. There is no future
availability data in Google to migrate. Nothing has to be moved.

**No event on this calendar was created by the website.** All four website
bookings carry `googleEventId = null`, because none was ever paid — all four
are `hold_expired`. Both events were created by you by hand. So there is no
machine-maintained state here, and no circular import: the calendar holds no
Airbnb, Vrbo or Booking.com subscription data.

**Event B is an accidental inventory block.** It is a personal appointment, at
an address unrelated to the property, and it is not an availability statement
at all. But the website reads this calendar with the **FreeBusy** API, which
returns opaque busy intervals and treats any overlap with a night as that night
being unavailable. A 30-minute afternoon appointment therefore removed the
night of 2026-10-26 from sale on bostonfurnishedstays.com. It is in the past, so
no action is needed now — but it demonstrates the structural problem below.

### 2.2 The structural problem with the current design

The website cannot classify what it reads from Google. `getGoogleBusyNights`
calls FreeBusy, which returns `{start, end}` intervals and **no titles,
descriptions or organisers**. Your Section 4 question — which events are
genuine reservations, owner blocks, maintenance, or imported platform events —
is unanswerable *by the website*, because the data it receives carries none of
that. Every busy interval is equally authoritative.

That has two consequences worth stating plainly:

- **Any calendar entry blocks inventory.** A dentist appointment and a confirmed
  reservation are indistinguishable. Event B is the live proof.
- **The dependency is fail-closed in the booking path.**
  `assertGoogleAvailableForBooking` throws on *any* problem — a conflict, a
  network error, a missing credential, a timeout, a malformed response — and
  the booking endpoint must refuse. That is the correct choice for preventing
  double bookings, but it means **a Google credential failure stops all direct
  bookings**. A single expired service-account key takes your direct channel
  offline.

Retiring this dependency removes a single point of failure, not just a legacy
integration.

### 2.3 Google is bidirectional, which the retirement plan must handle

Not only a source — the website also **writes**:

| Direction | Trigger | Code |
|---|---|---|
| Read | availability display and the pre-hold gate | `getGoogleBusyNights`, `assertGoogleAvailableForBooking` |
| **Write** | payment confirmed → create a busy event, store `googleEventId` | Stripe webhook → `createBusyEvent` |
| **Delete** | booking cancelled → delete that event | admin cancel route |

So retirement is two separate removals. Removing only the read path would leave
the website creating Google events that nothing consults — harmless but
misleading. Removing only the write path would leave stale blocks that nothing
maintains. The order below removes the read dependency first, because that is
the one that can refuse a guest's booking.

### 2.4 Retirement plan — proposal only, nothing removed

| Step | Action | Gate |
|---|---|---|
| G1 | **Nothing is migrated.** Decided 2026-11-08: the two events are not imported. See §2.5. | decided |
| G2 | — | — |
| G3 | Run VRC availability and the website's `getCombinedPublicCalendar` side by side nightly. Report every night where they disagree. | 14 consecutive clean days |
| G4 | **Propose** replacing the website's read path — `getCombinedPublicCalendar` and `assertGoogleAvailableForBooking` — with a call to VRC. Still fail-closed, now against VRC. | **your approval** |
| G5 | **Propose** removing the write path, so confirmations stop creating Google events. | **your approval** |
| G6 | Leave the calendar itself in place, read-only, unreferenced, as a fallback for one full season. | — |

Nothing in G4–G6 happens in this phase. Per your instruction, Google is not
removed from the website's availability calculation now; this is the plan for
when you decide it should be.

### 2.5 Why the two historical events are not migrated

**Decision, 2026-11-08: do not migrate them.** Recorded here because the
reasoning will not be obvious to anyone reading the schema later.

Four reasons:

1. **Both are in the past.** The later event ended 2026-10-26; today is
   2026-11-08. Neither affects any bookable night.
2. **Neither is an availability statement this system should hold.** Event B is
   a personal appointment at an address unrelated to the property. It only ever
   blocked a night because FreeBusy cannot carry that distinction. Importing it
   would import the bug.
3. **Event A's intent is unrecoverable.** It is untitled, and it was created the
   same day all four website holds were taken and expired. Whether it was a
   deliberate 38-night owner block or an artefact of that testing cannot be
   established from the data. Importing an interval whose meaning is unknown
   would put a `needs_review` row in the new system's history that no future
   reader could ever resolve.
4. **The new system's history should begin clean.** `source_events` is
   append-only and `DELETE` is revoked for the application role, so anything
   imported now is permanent. Importing two unexplainable past intervals buys
   nothing and cannot be undone.

The calendar itself is left untouched and read-only, so the events remain
available in Google if they are ever needed. This document is their record.

**Duplicate and circular import prevention.** Events imported at G1 are tagged
with their Google event id, so a re-import updates rather than duplicates. VRC
never writes to Google, so there is no loop. Once G5 lands, the website stops
writing too, and the calendar becomes inert.

---

## 3. Source data to migrate

### 3.1 From SQLite — verified counts

Read from a `sqlite3 .backup` copy, so WAL contents are included.

| Table | Rows | Carried as |
|---|---|---|
| `properties` | 1 | `properties` + `legacy_id` |
| `events` | 7 | `source_events` + `legacy_id` |
| `classifications` | 7 | `classifications`, all `locked = true` |
| `availability_decisions` | 2 (both `approved`) | `availability_decisions` + `publication_uid` verbatim |
| `availability_audit` | all | `availability_audit`, order preserved |
| `platform_listings` | 3 | `platform_listings`; Booking.com stays `revoked` |
| `feed_publications` | 0 | — |
| `feed_snapshots` | 0 | — |
| `published_feed_entries` | 0 | — |
| `app_settings` | `feed_publication_scope = approved_manual_blocks_only` | copied |
| `schema_migrations` | max 12 | Postgres starts its own at 1 |

The two decisions, which are the most sensitive rows in the system:

```
1: 2026-12-10 → 2026-12-17   vrbo / block / approved
2: 2026-12-19 → 2026-12-20   vrbo / block / approved
```

December 17 and 18 are deliberately excluded and remain sellable. A test
asserts they never appear in a generated feed, and that assertion moves to
Postgres with the rest.

### 3.2 From PriyankaHomes DynamoDB — read-only

Per the design in
[WEBSITE-BOOKING-INTEGRATION.md](WEBSITE-BOOKING-INTEGRATION.md): the calendar
table only, `BatchGetItem` over an explicit date horizon, no personal data, no
writes ever.

Current live state: **4 bookings, all `hold_expired`; 0 confirmed; 0 active
holds.** The calendar table holds 10 rows, of which 9 are tombstones from those
expired holds and 1 is a far-future sentinel.

So there is presently **no confirmed direct booking to preserve**. That is
fortunate for migration risk and irrelevant to correctness: the import path,
the `confirmed`/`provisional` distinction and the tombstone handling are all
built and tested now, because the next real booking must be handled correctly
on its first day.

**The tombstone rule carries forward.** A calendar row with no `status`
attribute means **available**. Derivation is keyed on `status`, never on row
existence. Treating a tombstone as a block would withdraw nine genuinely free
nights from sale — the inverse of the mistake this project exists to prevent,
and a conclusion I got backwards once already.

---

## 4. Reconciliation reports

Two reports, both stored in `migration_reconciliation` so the migration can be
audited afterwards rather than trusted.

### 4.1 Before migration

| Metric | Expected |
|---|---|
| SQLite source events | 7 |
| SQLite classifications | 7 |
| Approved decisions | 2 |
| Publication UIDs (exact strings) | 2, recorded |
| Audit rows | counted |
| Blocking nights per platform, next 18 months | computed and recorded |
| DynamoDB confirmed bookings | 0 |
| DynamoDB active holds | 0 |
| DynamoDB tombstones | 9 |
| Google future busy nights | **0** |

### 4.2 After migration — every line must match

| Assertion | Pass condition |
|---|---|
| Row counts | identical to §4.1 |
| Publication UIDs | the same two exact strings |
| Classification kinds | unchanged, all `locked` |
| Decision status / dates / reason / approver | byte-identical |
| Dec 17 and Dec 18 | **not** blocked on Vrbo |
| Blocking nights per platform | identical set, night by night |
| Cancellation blocks in `blocking_intervals` | zero |
| Platform restrictions in `blocking_intervals` | zero |
| Audit row order | preserved |
| `outbound_sync_enabled` | `false` |

A night-by-night set comparison is the assertion that matters. Counts can match
while the underlying nights differ; a set difference cannot hide an off-by-one.

### 4.3 Parallel-run report — Phase 4, nightly

Runs while both systems are live, before the website depends on VRC:

- every night where VRC and `getCombinedPublicCalendar` disagree, with the
  reason each gives;
- every DynamoDB row whose derived state differs from VRC's;
- any Google busy night with no VRC counterpart.

Fourteen consecutive clean nights is the gate for proposing G4.

---

## 5. Mechanics

The migration is a one-off Swift command, `vrc migrate --to-postgres`, run from
the Mac, using the same tested logic for both sides.

1. `VACUUM INTO` a consistent snapshot of the live SQLite database. Copying the
   `.sqlite` file alone reads stale data — the WAL sidecar is not included, a
   trap that has already produced one wrong conclusion in this project.
2. Compute and store the §4.1 before-report from the snapshot.
3. Apply `001_central_schema.sql` to an **empty** Aurora database.
4. Insert in dependency order, inside **one transaction**, preserving
   `legacy_id` and `publication_uid`: properties → listings → source events →
   classifications → decisions → audit → settings.
5. Compute the §4.2 after-report **inside the same transaction**. Any mismatch
   rolls the whole thing back. A partial migration is never committed.
6. On success, write both reports to `migration_reconciliation` and to a
   versioned S3 object.

The SQLite database is **not** modified, moved or deleted. It remains a
complete, working fallback.

### 5.1 Rollback

| Phase | Rollback |
|---|---|
| During migration | the transaction aborts; Aurora is left empty |
| After migration, before the dashboard is used | drop the database; the Mac app keeps running on SQLite |
| After the dashboard is in use | restore from the S3 reconciliation snapshot, or re-run the migration into an empty database |
| After Phase 4 | the website's own DynamoDB tables are still authoritative for its bookings until G4; reverting is a configuration change on the website |

The dangerous moment is not the migration — it is reversible until the website
starts depending on VRC at G4. That is why G4 sits behind fourteen clean nights
of parallel running rather than a successful migration.

---

## 6. Risks

| # | Risk | Severity | Safeguard |
|---|---|---|---|
| 1 | A publication UID changes, so Vrbo sees delete-then-create | **High** | copied verbatim, `UNIQUE`, asserted as exact strings |
| 2 | Tombstoned DynamoDB rows read as blocks | **High** | derivation keyed on `status`; tested against the nine real tombstones |
| 3 | Google credential failure stops all direct bookings | **High** | **exists today**, unmitigated until G4; the strongest argument for retirement |
| 4 | An owner classification silently re-inferred | High | `locked` + a CHECK that an owner decision cannot be stored unlocked |
| 5 | A timestamp conversion shifts a date across a DST boundary | High | nights are `date`/`daterange`, never `timestamptz`; no zone arithmetic |
| 6 | Partial migration committed | High | single transaction; reconciliation inside it; rollback on any mismatch |
| 7 | Stale SQLite snapshot read during migration | Medium | `VACUUM INTO`, never a file copy |
| 8 | Google-only busy nights invisible to VRC | Medium | currently zero such nights; the parallel run detects any that appear |
| 9 | Both systems writing availability in Phase 4 | Medium | the website keeps its own tables authoritative until G4; VRC reads only |
| 10 | Aurora cold-start inside a guest checkout | Medium | CDN-cached read path; see the architecture document §3.2 |
| 11 | Event A was a real owner block, not a test artefact | Low | it is in the past; G2 asks you rather than guessing |
| 12 | A fifth channel appears mid-migration | Low | `channel` is an enum; adding a value is a migration, not a redesign |

Risk 3 is the only one that is live **today**, and it exists in the current
system rather than being introduced by this plan.

---

## 6a. Roslindale calendars — inactive, recorded only

**Decision, 2026-11-08:** `ros1`
(`9cc3d274b85b58f276123086fbed76be30338022dd742321ff93dc8d2cb9fed2@group.calendar.google.com`)
and `ros2` / "roslindale 2"
(`ba8f2244e1e2e444422186c364c8cc67ea4fb4bff2ae3283577f5965da5975da@group.calendar.google.com`)
are **inactive future-property identifiers, not active listings.**

Consequences for Phase 2:

- No `properties` row, no `platform_listings` row, and no source adapter is
  created for either.
- No import job polls them, so they contribute nothing to cost or to
  availability.
- They are **not** read during reconciliation, and their contents are not
  inventoried. Only their existence is recorded, here.
- The schema is already multi-property (`properties.slug`, a per-property
  `feed_host`), so activating one later is inserting rows, not reshaping
  anything.

## 7. What was explicitly not done

No AWS resources created. No DNS changed. Nothing deployed. No data migrated.
No write to Google Calendar, to either PriyankaHomes DynamoDB table, or to the
live website. Google Calendar is still in the website's availability
calculation. `OutboundSyncGate.isEnabled` is still `false`. The two approved
Vrbo decisions, all seven events and all seven classifications are intact, and
the 203-test suite passes unchanged.
