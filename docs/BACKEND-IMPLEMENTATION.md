# Minimal AWS backend — implementation report

**No cloud resources created. `terraform apply` was not run. No DNS changed, no
schedule enabled, no outbound synchronisation activated.** `terraform plan`
reports **65 to add, 0 to change, 0 to destroy**, and every action is `create`.

Prepared 2026-11-09. Branch `backend/aws-backend`.

| | macOS | Linux |
|---|---|---|
| Tests | **261 passed, 961 assertions** | **261 passed, 961 assertions** |
| Parity digest | `b3398471…c604f5` | **`b3398471…c604f5`** |
| All 5 handlers build | yes | **yes** |

The parity digest is unchanged from before any of this work, which is the point:
a great deal of new code went in and the business rules did not move.

---

## 1. PostgreSQL DataStore

[`Sources/VRCCore/Database/DataStore.swift`](../Sources/VRCCore/Database/DataStore.swift),
[`DataAPIStore.swift`](../Sources/VRCCore/Database/DataAPIStore.swift),
[`SQLScanner.swift`](../Sources/VRCCore/Database/SQLScanner.swift).

Seven methods — `execute`, `run`, `query`, `queryOne`, `scalarInt`,
`lastInsertRowID`, `transaction`. `Database` (SQLite) and `DataAPIStore`
(Aurora) both conform, and the ten repositories cannot tell which they hold. No
business rule was touched.

Synchronous deliberately. Making it async would ripple through every repository
and caller for no gain: a Lambda handler owns its thread. `DataAPIStore` blocks
on an injectable transport, which is also what makes all of the below testable
with no AWS account.

| Requirement | How |
|---|---|
| Parameterised SQL | `?` rewritten to named parameters; values travel typed, never interpolated |
| Explicit transactions | Begin/Commit/Rollback, re-entrant so a nested call joins rather than committing early |
| Prevent concurrent conflicts | `SERIALIZABLE` for admission, plus the exclusion constraints underneath |
| Preserve approval and audit history | audit is append-only by privilege; `locked` classifications are never overwritten |
| Restricted role, not master | `vrc_runtime` (migration 003). **No Lambda can read the master credential** |
| Retries | 40001/40P01 retried; resume waited for; transient reads retried |
| Transaction expiry | reported, never silently re-run outside the transaction |
| Aurora resume delays | retried with backoff inside a budget |
| Fail closed | an uncertain write throws `.indeterminate` |

### 1.1 The placeholder rewriter is not optional

Repository SQL uses SQLite's `?`. The Data API takes named parameters. A naive
rewrite would corrupt any SQL containing a literal question mark — and this
project has that, in reason text and summaries. `SQLScanner` skips string
literals, escaped quotes, quoted identifiers, line comments, block comments and
dollar-quoted bodies.

A placeholder/parameter count mismatch is **refused** rather than guessed,
because guessing means binding the wrong column. A multi-statement `execute` is
refused rather than running only the first.

Verified: a value of `'); DROP TABLE reservations; --` does not appear in the
SQL text at all; it travels as a typed parameter.

### 1.2 Failing closed, stated precisely

| Situation | Behaviour | Why |
|---|---|---|
| Read fails transiently | retried | nothing was changed |
| **Write fails transiently** | **`.indeterminate`, not retried** | it may already have applied; applying twice is worse than failing |
| 40001 / 40P01 | retried | the database already rolled it back, so nothing applied |
| Exclusion violation | not retried | a real double booking; the caller records a conflict |
| Transaction vanished | `.indeterminate` | retrying would run the statement *outside* the transaction |
| **Commit unconfirmed** | **`.indeterminate`** | the caller cannot tell whether the work landed |
| Aurora resuming | waited for, within a budget | normal at 0 ACU; but a cluster that never wakes is still a failure |

**A bug the tests caught:** the commit was first classified as a read, so a 500
on `COMMIT` was retried and could report success for work that had not landed.
A commit is now treated as a write.

---

## 2. The five handlers

[`Sources/VRCLambda/`](../Sources/VRCLambda/) plus five thin entry points. The
runtime loop is hand-rolled against the documented Lambda HTTP API rather than
taking a dependency — every dependency has to cross-compile to a static Linux
binary, which is how these ship, with no Docker and no Xcode.

All five use **the same VRCCore** the Mac runs. Nothing reimplements a rule.

| Handler | Database | Internet | Secrets it may read |
|---|---|---|---|
| `vrc-fetch` | **none** | yes | **source feed URLs only** |
| `vrc-process` | write | no | runtime credential |
| `vrc-publish` | read | yes | runtime credential, outbound tokens |
| `vrc-api` | read/write | no | runtime credential |
| `vrc-sweeper` | write | no | runtime credential |

### 2.1 The fetcher holds no database credential

It is the component that parses untrusted third-party calendar content, so it
is the one that cannot write to the system of record and cannot publish. That
is enforced twice:

- **IAM** grants it only the source secret, the raw bucket, read-only
  `BatchGetItem`/`GetItem`/`DescribeTable` on the two PriyankaHomes tables, and
  `lambda:InvokeFunction` on exactly `vrc-process`.
- **At runtime**, `ServiceContext.requireNoDatabase()` refuses to run if
  `VRC_DB_SECRET_ARN` is present at all. Terraform omits the database variables
  for this function specifically.

Two independent statements of the same rule, so a future policy edit that
widened the fetcher's access would still be caught. Tested.

### 2.2 How the database stays asleep

The fetcher parses, hashes the normalised event set, compares against S3, and
**only wakes the processor when something actually changed**. Verified:

- an unchanged feed → processor not invoked;
- a feed whose only difference is a regenerated `DTSTAMP` → not invoked;
- a real change → payload stored for forensics, new hash recorded, processor invoked once;
- a failed fetch → **nothing recorded, nothing invoked, the stored hash untouched**;
- HTTP 304 → cycle ends before parsing.

Booking.com is not polled at all — its token was revoked, and retrying it would
be noise rather than diligence.

### 2.3 The publisher's four gates

All four must agree before any byte is uploaded:

1. `OutboundSyncGate.isEnabled` in the code.
2. `VRC_OUTBOUND_ENABLED` in the environment.
3. Eligibility re-derived from the classification — entries descending from a
   cancellation penalty, platform restriction, provisional hold or unknown
   block are detected and the whole publication refused, independently of the
   generator already excluding them.
4. The generated bytes are **parsed back** and the entry count compared before
   upload. A feed that cannot be read is worse than no feed.

Verified refusals: the code gate shut, the environment gate shut, a decision in
`draft`/`validated`/`awaiting_approval`/`cancelled`, and a decision belonging to
a different destination.

---

## 3. Publishing safety

| Requirement | How |
|---|---|
| Last-known-good snapshots | written **before** the live object, under a digest-named key, so recovery never depends on the publish succeeding |
| S3 versioning | enabled on all three buckets |
| Verify before updating the active feed | gate 4 above: parse back and compare counts |
| Failed uploads | stage stays `failed`; the previous feed is still served, untouched |
| Invalidation errors | stage stays **`uploaded`**, never `purged` — new bytes at the origin that nobody is being served is its own state, and calling it success would be a lie |
| Stable iCal identifiers | `stableUID(forSourceKey:destination:)` unchanged; `publication_uid` migrated verbatim |
| Never publish unknown blocks or cancellation penalties | gate 3, and `describes_genuine_unavailability` in the database |

`isRemoteSynchronised` is hard-coded `false` on every outcome. Publishing is not
importing, and the Mac is never told a platform has read the feed.

---

## 4. Security

| Requirement | Status |
|---|---|
| Restricted application credentials | `vrc_runtime` — no DDL, cannot rewrite the audit trail, cannot delete source observations. **Verified by 6 privilege tests** |
| Short-lived credentials evaluated | **adopted server-side.** Every handler uses the Lambda execution role's rotating credentials from the environment, including the session token. No long-lived key exists for any Lambda |
| Mac API credentials | an IAM user with one permitted action on one API. See §7 for the short-lived alternative and why it is not yet taken |
| Secrets out of Git | no `secret_version` resource for the source URLs, the outbound tokens, or the runtime password; all written out of band |
| Secrets out of plan output | verified: `terraform show -json` contains no secret value |
| Secrets out of logs | the Secrets Manager reader never echoes a response body, because an error from it can quote the secret id |
| Secrets out of API responses | `/status` returns counts and booleans only |
| IAM validated against responsibilities | §2, table and audit below |

**Fetcher policy, extracted from the plan:** readable secrets
`[source_feed_urls]`; actions `dynamodb:BatchGetItem`, `dynamodb:DescribeTable`,
`dynamodb:GetItem`, `lambda:InvokeFunction`, `logs:*`, `s3:GetObject`,
`s3:PutObject`, `secretsmanager:GetSecretValue`. No DynamoDB write of any kind.

The publisher still has **no `s3:DeleteObject`** — clearing a feed is not an
expressible operation.

---

## 5. Aurora compatibility, and a defect this found

**`engine_version` was pinned to `16.4`, which no longer exists in us-east-1.**
Verified against `aws rds describe-db-engine-versions`: the 16 line now starts
at **16.8**. An apply would have failed outright.

Now **16.15**, which clears both floors:

| Requirement | Floor | 16.15 |
|---|---|---|
| Minimum capacity 0 ACU (scale to zero) | ≥ 16.3 | ✅ |
| RDS Data API | ≥ 13.11 / 14.8 / 15.3, any 16.x | ✅ |
| Available in us-east-1 | — | ✅ confirmed by API |

Confirmed in the plan: `engine_version = 16.15`, `min_capacity = 0`,
`max_capacity = 4`, `seconds_until_auto_pause = 300`,
`enable_http_endpoint = true`, `deletion_protection = true`, both schedules
`DISABLED`.

---

## 6. Cost

Unit prices from the AWS Pricing API. One line changed: a fourth secret, for
the restricted runtime credential — which is the entire point of having it.

| Scenario | New money | On the bill |
|---|---|---|
| **Expected** | **$5.76** | $6.26 |
| Worst case — change detection defeated | $19.95 | $20.45 |
| Zero traffic | $2.16 | $2.66 |

Still planning estimates, not guaranteed billing. The budget alarm at $15 sits
between the expected and worst cases on purpose.

---

## 7. Remaining blockers to a staging deployment

| # | Blocker | Owner | Note |
|---|---|---|---|
| 1 | **Keychain credentials unreadable** | **you** | two commands, below. Blocks 2 |
| 2 | **Live feed-diff** | follows 1 | decides $5.76 vs $19.95 |
| 3 | **Static Linux SDK not installed** | me | `swift sdk list` reports none. `Scripts/build-lambda.sh` refuses without it. Needs the checksum for this toolchain from swift.org |
| 4 | **Publisher is not wired to live decisions** | me | deliberate: `vrc-lambda-publish` returns `refused` even with both gates open. Wiring it is the step after authorisation, left unwritten rather than left disabled |
| 5 | **Mac-side sync client not written** | me | `SigV4Signer` exists and is tested; the client that calls `/status` and `/availability` is not |
| 6 | **Repositories still construct `Database` directly** | me | they conform to `DataStore` but are not yet injected with it, so the handlers exercise the store through hand-written SQL rather than through the repositories |
| 7 | **Runtime role password** | you + me | created out of band after the cluster exists; deliberately absent from Terraform and from migration 003 |
| 8 | No integration test against a real Aurora cluster | me | everything is tested against local PostgreSQL 17 and a mock transport; the Data API's own behaviour is untested until a cluster exists |

Blocker 6 is the largest remaining piece of real work and the honest limit of
what is finished: the store is complete and tested, but the repositories are not
yet constructed with it, so nothing end-to-end runs against Postgres through the
tested repository layer.

### 7.1 Short-lived credentials for the Mac

Evaluated as asked. The server side already uses them. For the Mac, the options are:

| Option | Credential on the Mac | Cost | Verdict |
|---|---|---|---|
| IAM user access key (current) | long-lived, in the Keychain | $0 | simplest; one permitted action on one API |
| IAM Roles Anywhere | short-lived, from an X.509 certificate | $0 | **recommended later** — the private key still lives in the Keychain, so the gain is bounded |
| Cognito identity pool | short-lived, from a login | $0 under 10k MAU | reintroduces the login flow the scope correction removed |

Recommendation: keep the IAM user for staging, because the key is scoped to one
`execute-api:Invoke` on one API and is revocable in one click, then move to
Roles Anywhere before the service holds real reservations. I have not changed it.

### 7.2 The two commands that unblock 1 and 2

`set-url` reads the URL with terminal echo cleared, **verifies it by fetching
and parsing before saving**, prints only the host and shape, and refuses to save
when stdin is not a terminal. The previous Keychain entry is left in place.

```
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc set-url --listing 2   # Airbnb
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc set-url --listing 1   # Vrbo
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc feed-diff --gap 300
```

I have not run these: it would put your private feed URLs into this transcript
and into process arguments.

---

## 8. Testing

| Suite | Count | Where |
|---|---|---|
| Portable Swift suite | **261 tests, 961 assertions** | macOS **and** Linux, identical |
| — DataStore | 24 | parameterisation, retries, fail-closed, transactions |
| — Lambda handlers | 18 | the refusals |
| — Semantic hash | 16 | change detection, both directions |
| Migration 002 guards | 19 | PostgreSQL 17 |
| Migration 003 roles and cancellation | 23 | PostgreSQL 17 |
| Concurrency | 7 | real concurrent psql sessions |
| Output parity | byte-identical | both platforms |

Against your list:

| Required | Covered by |
|---|---|
| PostgreSQL transactions | DataStore 24 + migration tests |
| Simultaneous booking attempts | **12 rounds of concurrent overlapping holds: one winner each time, zero double bookings**; plus concurrent confirmed reservations, and checkout-day adjacency still succeeding for both |
| Failed imports | fetch handler (3 cases) + guard 2a/2b + "empty feed withdraws nothing" |
| Failed publication | upload failure, invalidation failure, unparseable feed |
| Last-known-good recovery | written before the live object; only a complete publication may become one |
| Aurora resume delays | retried-then-succeeds, and gives-up-eventually |
| Unauthorised API calls | unsigned → 401; unknown route → 404 |
| Reservation cancellation | 11 cases incl. idempotent retry, wrong channel, mismatched ref, no reason, importer refused |

Two bugs the tests caught and fixed: the commit retry (§1.2), and the
cancellation function reading the actor from an argument while the trigger read
the session — which made the sanctioned path refuse itself *and* would have let
an importer elevate by passing `'owner'`.

---

## 9. What was explicitly not done

No cloud resources created. No DNS changed. No schedule enabled. No outbound
synchronisation activated. No PR merged. The live PriyankaHomes website,
Google Calendar and both DynamoDB tables are untouched. The two approved Vrbo
decisions, seven events, seven classifications and both publication UIDs are
intact, and `OutboundSyncGate.isEnabled` is still `false`.
