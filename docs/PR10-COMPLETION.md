# PR #10 — integration and recovery fixes

**No cloud resources created, no DNS changed, no schedule enabled, no outbound
publishing activated.** `terraform plan`: 65 to add, 0 to change, 0 to destroy.

| | macOS | Linux |
|---|---|---|
| Tests | **297 passed, 1034 assertions** | **297 passed, 1034 assertions** |
| Parity digest | `b3398471…c604f5` | **`b3398471…c604f5`** |
| 5 release binaries build and package | — | **yes, 5.5–5.6 MB each** |

Plus, against an isolated PostgreSQL 17 cluster: **19/19** withdrawal guards,
**23/23** role and cancellation tests, **7/7** concurrency assertions.

The parity digest is unchanged, again. The business rules have not moved.

---

## 1. Transaction lifecycle — four defects, all silent

Every one of these produced *wrong data* rather than an error, which is why
each now has failure injection and a recovery assertion.

### 1.1 A failed `BeginTransaction` leaked the depth

```swift
transactionDepth += 1                       // incremented first
let begun = try call(.beginTransaction, …)  // ← throw left depth at 1
```

After that throw, **every later `transaction()` call on that store believed it
was nested and ran with no transaction at all.** Writes that were supposed to be
atomic would commit individually.

Now the depth and ownership are claimed inside `runOneTransaction`, released by
a `defer` that runs on every exit path. The same fix covers a `200` response
carrying no `transactionId`.

Each test asserts the failure *and then runs a second transaction successfully*,
because a leaked depth shows up only as a later transaction that never issues
`BeginTransaction`.

### 1.2 `actorDeclared` was set before the statement succeeded

```swift
if inTransaction { actorDeclared = true }   // set first
…
_ = try call(.execute, body: body)          // ← could throw
```

A failed declaration left the store believing the actor had been declared, so
every subsequent statement ran as the database's default actor — `importer`,
the least privileged. The owner's own changes would then be refused by the
migration 002 and 003 guards, or worse, silently treated as an import.

Now marked only after the statement succeeds, and the test asserts the actor is
declared **twice** when the first attempt fails.

### 1.3 Serialisation failures retried the statement inside a dead transaction

The important one. A `40001` was retried at statement level — but PostgreSQL
aborts the **whole** transaction, so the retried statement runs inside one the
server has already discarded and fails with "current transaction is aborted".

The fix is structural:

- `call()` now knows whether it is inside a transaction. If it is, `40001` and
  `40P01` surface as `.serializationFailure` rather than being retried.
- `transaction(attempts:)` catches that, rolls back, and **re-runs the entire
  body** — the only correct recovery. Jittered backoff, so two contenders do
  not retry in lockstep.
- Outside a transaction a lone statement is its own transaction, so retrying it
  there is still correct and is kept.

Verified: the body runs twice, two `BeginTransaction` calls, one rollback, one
commit — and the actor is re-declared in the restarted transaction, because a
restart is a new transaction.

### 1.4 Rollback failure, and concurrent use

A failed rollback clears local state and reports `.indeterminate` naming that
the server may hold the transaction open until it expires. The invalid
transaction is not reusable, and the test proves the store recovers.

A serialisation failure still reaches the retry loop even when the rollback
also failed, because the database has discarded the transaction either way.

**Concurrent access** was undefined: `transactionID` is per-instance, so a
second thread issuing statements would interleave them into someone else's
transaction. Now the owning thread is recorded and a second thread gets
`.concurrentUse` instead of corrupting both transactions. Sequential use of one
store is unaffected.

Uncertain commits remain `.indeterminate` — unchanged, and still tested.

**15 failure-injection tests**, one per transition.

---

## 2. Repository integration

All ten repositories, the audit log and the outbound coordinator now take
`DataStore` rather than `Database`. They only ever used the seven methods, so
this was a type change, not a rewrite — and `RentalStore.makeCloud(store:)`
assembles the same repositories over Aurora.

`RentalStore` runs the SQLite migrator only for a SQLite store; a cloud store
must arrive already migrated by `Migrations/postgres/*.sql`, and is refused
with a clear message if it has not been.

### 2.1 Proving the abstraction is faithful, not just type-compatible

A `DataAPITransport` that executes each call against a **real SQLite
database**. Not a mock: the placeholder rewriting, parameter binding, row
decoding, generated-id capture and transaction bracketing all run for real.
What it removes is the network and the Postgres dialect, so what is under test
is the store.

The same repository workflow — properties, listings, events, a confirmed
reservation, a cancellation block, classifications, date intervals, an
availability decision and its audit entry — runs through both stores and the
reports are compared line by line.

**Result: identical.** Date intervals, classification kinds,
`describesGenuineUnavailability`, and audit records all match. Generated ids
survive the round trip, and a rolled-back repository transaction leaves nothing
behind.

A second test guards against the first passing for the wrong reason, asserting
that statements really went through the Data API encoding and that `:p0`
round-tripped back to `?` so values stayed parameterised.

### 2.2 What is still not done, precisely

The handlers' hand-written SQL is **not** yet replaced by repository calls,
because the two schemas differ: the repositories' SQL targets the SQLite shape
(`REAL` epochs, integer keys), while Postgres uses `timestamptz`, `uuid` and
`daterange`. Injecting the store was the prerequisite; **schema convergence is
the remaining work**, and it is the honest limit of "repository integration
complete".

Deduplicating against a schema the repositories cannot yet query would have
meant rewriting their SQL on the way, which is exactly the "unverified rewrite"
to avoid.

---

## 3. Mac-to-AWS client

[`Sources/VRCCore/Sync/CloudSyncClient.swift`](../Sources/VRCCore/Sync/CloudSyncClient.swift).
Every request SigV4-signed for `execute-api` with a Keychain credential. No
token to refresh, no login state.

| Capability | Behaviour |
|---|---|
| Read sync status | counts, last successful import, outbound flag |
| Read reservations and availability | `blocking_intervals`, with basis and source |
| Submit owner-approved decisions | **only** `approved`; a draft is refused locally and never reaches the network |
| Import failures and stale feeds | `failingSources` and `staleSources`; `isHealthy` is false if either is non-empty |

### 3.1 Idempotency and reconciliation

The key is **derived from the decision's own content** — property, destination,
action, dates, publication UID, status. A random key per attempt would defeat
the mechanism entirely. The same decision always yields the same key; a
different date range yields a different one.

The key is brought **inside the SigV4 signature**, so it cannot be stripped or
altered in transit. That needed a signer change: `sign(alsoSign:)` now takes
explicit extra headers. Deliberately opt-in rather than signing every header
present, because `URLSession` adds its own after signing and signing those
would cause intermittent mismatches.

`submitReconciling` is the whole point:

| Outcome | Action |
|---|---|
| applied / already applied / rejected | return; a rejection is final and not retried |
| **uncertain** | **ask the service whether it landed before trying again** |
| uncertain, and it did land | reported as already applied — no duplicate decision |
| uncertain, and it did not land | retried, safely, under the same key |
| still uncertain after N attempts | reported as **"NOT been applied — nothing was published"** |

A blind retry after a timeout risks a duplicate; never retrying risks silently
losing the owner's approval. Reconciling first avoids both. `remoteSynchronised`
defaults to false when the field is absent — never inferred.

A submission always carries `"publish": false`. Submitting a decision is not a
request to publish it. **17 tests.**

---

## 4. Cloud execution and packaging

### 4.1 A packaging finding that would have failed at startup

All five release binaries build and package on Linux — 5.5–5.6 MB zips, each
containing an executable `bootstrap`, which is what `provided.al2023` runs.

But the Docker-built binary is **not deployable**:

```
libswiftCore.so  => /usr/lib/swift/linux/libswiftCore.so
libFoundation.so => /usr/lib/swift/linux/libFoundation.so
libsqlite3.so.0  => /lib/aarch64-linux-gnu/libsqlite3.so.0
```

**13 Swift and Foundation shared objects plus libsqlite3**, none of which exist
on `provided.al2023`. The function would fail at startup with a missing-library
error. `GLIBC_2.34` is fine — AL2023 has it — so the glibc version is a red
herring; the Swift runtime is the real dependency.

The Static Linux SDK produces a fully static musl binary with **no**
shared-object dependencies, which is what the runtime needs. `build-lambda.sh`
now explains this up front and runs `assert_static` on every binary before
zipping it, so an undeployable package cannot be produced by accident.

### 4.2 Isolated PostgreSQL

Migrations 001–003 applied to a fresh cluster, then all three SQL suites:
**19/19**, **23/23**, **7/7**. The concurrency suite drives real concurrent
`psql` sessions — 12 rounds of simultaneous overlapping holds produced exactly
one winner each time and zero double bookings, with checkout-day adjacency
still succeeding for both parties.

Testing against the real RDS Data API remains outstanding and needs a cluster,
which needs your separate approval.

---

## 5. Remaining blockers to staging

| # | Blocker | Owner |
|---|---|---|
| 1 | **Keychain credentials unreadable** — two commands, §6 | **you** |
| 2 | Live feed-diff, which decides $5.76 vs $19.95 | follows 1 |
| 3 | **Static Linux SDK not installed** — needs the checksum for this toolchain from swift.org | me, once you want deployable artefacts |
| 4 | **Schema convergence** so the handlers use the repositories instead of their own SQL | me — the largest remaining piece |
| 5 | Publisher not wired to live decisions | deliberate; the step after authorisation |
| 6 | API write routes (`POST /decisions`, `GET /decisions/{uid}`) not implemented server-side | me — the client calls them; the handler returns 404 today |
| 7 | Runtime role password, created out of band after the cluster exists | you + me |
| 8 | No test against the real Data API | needs a cluster, needs your approval |

Blocker 6 is worth naming plainly: the client is complete and tested against a
fake transport, but the two routes it writes to do not exist in `ApiHandler`
yet, so submitting a decision would currently return 404. The client's contract
is defined and tested; the server side of it is not written.

---

## 6. The two commands

```
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc set-url --listing 2   # Airbnb
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc set-url --listing 1   # Vrbo
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc feed-diff --gap 300
```

Echo is cleared, the URL is verified by fetching and parsing **before** saving,
only the host and shape are printed, and saving is refused when stdin is not a
terminal. I have not run these: it would put your feed URLs into this
transcript and into process arguments.

---

## 7. Not done

No cloud resources created. No DNS changed. No schedule enabled. No outbound
synchronisation activated. No PR merged. The live PriyankaHomes website, Google
Calendar and both DynamoDB tables untouched. Two approved Vrbo decisions, seven
events, seven classifications and both publication UIDs intact.
`OutboundSyncGate.isEnabled` is still `false`.
