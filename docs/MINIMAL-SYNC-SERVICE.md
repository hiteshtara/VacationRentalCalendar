# The minimal sync service

**Nothing deployed. No AWS resource created. `terraform plan` reports 64 to add,
0 to change, 0 to destroy.** Outbound publication is disabled in the Mac
application *and* in the deployed service. The two approved Vrbo decisions,
seven events and seven classifications are intact.

Prepared 2026-11-09. Supersedes the dashboard and cost sections of
[CENTRAL-ARCHITECTURE.md](CENTRAL-ARCHITECTURE.md) and
[PHASE2-PLAN.md](PHASE2-PLAN.md).

---

## 0. The correction, and one factual note

The scope is now: **existing SwiftUI Mac application + minimal AWS
synchronisation service.** No web dashboard, no replacement of the Mac app.

One point of fact, because it affects what has to be undone: **no React or
Next.js code was ever written.** There is no frontend directory, no
`package.json`, no JavaScript in this repository. The dashboard existed as a
design paragraph and two Terraform line items (an Amplify app and a second
CloudFront distribution), both now removed. It came from item 6 of the Phase 1
brief — "a responsive application for Mac, iPhone, and iPad browsers" — and it
is gone.

---

## 1. What already works, and is not being rebuilt

| Already working | Evidence |
|---|---|
| SwiftUI Mac calendar interface | runs; signed, installed, double-clickable |
| VRCCore business logic | 10,449 lines, 203 tests / 854 assertions |
| SQLite local data and classifications | 7 events, 7 classifications preserved throughout |
| Reservation safeguards | cancellation blocks, platform restrictions, unknown blocks all non-exportable; verified |
| Two approved Vrbo decisions | `vrc-812d1978…`, `vrc-a5a1dbf5…`, both `approved`, Dec 17–18 excluded |
| iCal parsing and filtered generation | RFC 5545 parser and writer, folding, DURATION, VALUE=DATE |
| GitHub repository | PRs #1–#8, none merged |

---

## 2. What is actually missing

Your seven items, mapped to the smallest thing that satisfies each.

| # | Missing | Smallest implementation |
|---|---|---|
| 1 | Always-running import of the three platform calendars | `vrc-fetch` Lambda every 15 min + `vrc-process` Lambda, both running **the same VRCCore** |
| 2 | Secure centralised reservation and availability state | Aurora Serverless v2 PostgreSQL, min 0 ACU, reached over the Data API |
| 3 | Small authenticated API for the Mac app | one API Gateway HTTP API, `AWS_IAM` authorisation — **no Cognito** |
| 4 | Continuously accessible destination feeds | S3 + CloudFront at `feeds.39gstboston.com` |
| 5 | Scheduled imports and controlled publication | two EventBridge schedules, created **disabled**; publication behind the existing gate |
| 6 | Last-known-good feed recovery | `feed_publications.is_last_known_good`, already written and tested |
| 7 | Monitoring and synchronisation status | 4 CloudWatch alarms, a budget alarm, and the status the API already returns |

### 2.1 The authentication decision worth highlighting

The Mac application signs each request with **SigV4 against an IAM user that
can do exactly one thing**: `execute-api:Invoke` on this one API.

That means no Cognito user pool, no hosted login page, no OAuth redirect, no
refresh token, and no session to expire. It also means **no new code**:
`SigV4Signer` already exists in `Sources/VRCCore/Sync/AWSHosting.swift`, is
already tested, and already works on both platforms.

That is the smallest authenticated path AWS offers, and it reuses something
that is already written.

---

## 3. Reusing the Swift engine — proved, not assumed

The importer and publisher run **the same VRCCore** as the Mac application.
That is only credible if it is demonstrated, so it is:

- `VRCCore` compiles for `aarch64-unknown-linux-gnu` under Swift 6.3.3.
- **All 203 tests / 854 assertions pass on Linux** — identical counts to macOS.
- `vrc-parity` runs fixed inputs through classification, availability decisions,
  conflict analysis and filtered iCal generation with a pinned clock, and
  produces **byte-identical output on both platforms**: 6,859 bytes, SHA-256
  `b3398471b1ee56f477d9a1244b16449e8827df1616aa5fca365ef3db96c604f5`.
- `Scripts/check-parity.sh` re-runs that comparison on demand, and
  `Scripts/build-lambda.sh` refuses to deploy if it fails.

Portability came from abstraction, not rewriting. No business rule was touched:
`CryptoKit` → `swift-crypto` behind `canImport`; Keychain confined behind
`canImport(Security)` so the server can use Secrets Manager instead;
`URLSession` → `FoundationNetworking`; SQLite via a `CSQLite` system target.

**Two real bugs surfaced that only Linux exposes**, both in publication rather
than in the rules:

1. `LocalDirectoryHostingClient` used `FileManager.replaceItemAt`, which on
   swift-corelibs-foundation requires an existing destination and, when one
   exists, can unlink it and then fail — leaving no file at all. That would have
   broken the **first publish of every feed** and then corrupted later ones, on
   the server only. Replaced with `rename(2)`, which atomically replaces on both
   platforms and is a stronger guarantee than the original.
2. A single-expression optional-cast chain in `R2Hosting` defeated the Linux
   type checker so thoroughly it could not produce a diagnostic.

Neither would have been found without actually building for Linux.

---

## 4. The smallest AWS resource set

`terraform plan`: **64 to add, 0 to change, 0 to destroy.** Every action in the
plan is `create`.

| Group | Resources | Why it cannot be smaller |
|---|---|---|
| Aurora Serverless v2 | cluster, 1 writer, parameter group, subnet group, VPC, 3 subnets, 1 security group (9) | a DB subnet group must span 2 AZs, so the VPC is mandatory; the Lambdas never join it |
| Lambda | 5 functions (fetch, process, publish, sweeper, api) | four scheduled jobs and one API; each needs its own role boundary |
| IAM | 4 runtime roles + policies, scheduler role + policy, 1 user + policy (12) | the fetcher must not hold the database credential |
| S3 | 3 buckets × 4 settings, 2 lifecycle rules (14) | feeds, raw payloads, snapshots |
| Delivery | CloudFront distribution, cache policy, OAC, ACM cert, 1 Route 53 record (5) | feeds must be reachable while the Mac is off |
| API | HTTP API, integration, route, stage, lambda permission (5) | the Mac's sync path |
| Secrets | 3 secrets + 1 version (4) | three distinct readers (§6) |
| Scheduling | 2 schedules, both **disabled** (2) | import and hold sweep |
| Observability | 6 log groups, 1 budget (7) | one per function plus API access logs |

### 4.1 Removed from PRs #4–#7

| Removed | Was for | Saving |
|---|---|---|
| Amplify Hosting app | the web dashboard | $0.46/month |
| Second CloudFront distribution | `calendar.bostonfurnishedstays.com` | $0 |
| Second ACM certificate | same | $0 |
| **Route 53 record in `bostonfurnishedstays.com`** | same | **see §6** |
| `dashboard` S3 bucket + 3 settings | static assets | $0.03 |
| Cognito user pool | dashboard login | $0 (replaced by IAM auth) |
| Customer-managed KMS key + alias | encryption | **$1.00/month, growing** |

The KMS removal is worth a sentence. A customer-managed key is **$1.00/month
per key version**, and automatic rotation adds a version every year — so it
would have grown to a sixth of this system's entire bill. AWS-managed keys
(`aws/s3`, `aws/secretsmanager`, `aws/rds`, `aws/logs`) are free, encrypt at
rest identically, and need no key policy in a single-operator account where
IAM already scopes every reader to one secret or one bucket prefix. If you ever
want a key policy as a second layer of deny, it is one resource and every
encrypted resource already accepts a `kms_key_id`.

---

## 5. Cost

Unit prices from the **AWS Pricing API**, 2026-11-09, `us-east-1`.

| Item | Basis | Monthly |
|---|---|---|
| Aurora Serverless v2 compute | 42.5 h awake × 0.5 ACU × $0.12 | $2.55 |
| Aurora storage | 1 GB × $0.10 | $0.10 |
| Aurora I/O | 2 M × $0.20/M | $0.40 |
| RDS Data API | within 1 M/month free tier (first 12 months) | $0.00 |
| Lambda, 5 functions | ~24,000 invocations — perpetual free tier | $0.00 |
| EventBridge Scheduler | 11,520 scheduled invocations | $0.00 |
| API Gateway HTTP API | ~3,000 Mac sync requests | $0.00 |
| S3 storage + requests | 3 buckets, ~2 GB | $0.12 |
| CloudFront (feeds only) | perpetual free tier | $0.00 |
| ACM, KMS, IAM | public cert, AWS-managed keys, no Cognito | $0.00 |
| Secrets Manager | 3 secrets + ~12k requests | $1.26 |
| CloudWatch Logs | 1 GB ingest, 14-day retention | $0.52 |
| CloudWatch alarms | 4 | $0.40 |
| DynamoDB reads | ~4,500 eventually-consistent RRU | $0.01 |
| **New money** | | **$5.36** |
| Route 53 | `39gstboston.com` — *already on your bill* | $0.50 |
| **Total appearing on the bill** | | **$5.86** |

| Scenario | New money | On the bill |
|---|---|---|
| Expected | **$5.36** | $5.86 |
| Worst case — change detection defeated by feed volatility | **$19.55** | $20.05 |
| **Zero traffic** | **$1.76** | $2.26 |

These are planning estimates, not guaranteed billing. The scope correction and
the KMS removal together save **$1.65/month** against the previous design.

**The range is still unresolved for one reason**, unchanged: if Airbnb and Vrbo
regenerate `DTSTAMP` on every request in a way the normalisation does not
absorb, the database never sleeps and the figure is ~$20. The live feed-diff
settles it, costs nothing, and needs the Keychain repair first (§8).

A budget alarm at $15 sits between the two scenarios on purpose.

---

## 6. Safety: an apply cannot touch the live website

You asked for this confirmation specifically. Verified against the plan JSON,
not by reading the configuration:

| Check | Result |
|---|---|
| Actions present in the plan | **`create` only** — zero update, zero destroy |
| References to `bostonfurnishedstays.com` | **none anywhere in the configuration** |
| Route 53 zones written to | one record, in `Z07332113NBDJM9Q3LU88` = `39gstboston.com` |
| Data sources read | `39gstboston.com` zone, availability zones, caller identity, the placeholder archive |
| PriyankaHomes references | **only** two DynamoDB table ARNs, in one IAM policy |
| DynamoDB actions granted | `BatchGetItem`, `GetItem`, `DescribeTable` — **no write action** |
| S3 actions granted | `GetObject`, `PutObject`, on this service's own new buckets only |
| Amplify / Cognito / Terraform state of PriyankaHomes | not referenced |

**The scope correction improved this.** The previous plan added an ACM
validation record to `bostonfurnishedstays.com` — the live website's own DNS
zone — because the dashboard needed a certificate there. With the dashboard
gone, that zone is not referenced at all, and the live site's DNS is now
outside the blast radius of any apply.

Other safety properties carried forward:

- Aurora: `deletion_protection`, `skip_final_snapshot = false`,
  `prevent_destroy`, `publicly_accessible = false`, no ingress rule.
- Both schedules created `DISABLED`, so an apply starts nothing.
- `VRC_OUTBOUND_ENABLED = "false"` in every function's environment, in addition
  to `OutboundSyncGate.isEnabled = false` in the code. Two independent gates.
- The publisher has **no `s3:DeleteObject`** — clearing a feed is not an
  expressible operation.
- The fetcher — the component that parses untrusted third-party feed content —
  holds no database credential and no outbound token.
- Three secrets with three distinct readers: database (processor, publisher,
  api), inbound source URLs (**fetcher only**), outbound feed tokens
  (**publisher only**). Consolidating them would hand the feed-parsing
  component the database keys.
- No `aws_iam_access_key` resource: a Terraform-created key lives in Terraform
  state. The Mac's key is created once, by hand, into the Keychain.
- The database guards from PR #6 still apply: an importer cannot withdraw an
  owner's classification, cannot empty a feed, and cannot move a confirmed
  reservation out of `confirmed` or shorten it.

---

## 7. Code changes required

| Change | Status |
|---|---|
| `VRCCore` compiling for Linux | **done**, PR #8 |
| Output parity proved | **done**, byte-identical |
| Non-echoing credential entry, verify-before-save | **done**, PR #8 |
| Semantic change detection | **done**, PR #5 |
| Postgres schema and withdrawal guards | **done**, PRs #4, #6 |
| `Scripts/build-lambda.sh`, `Scripts/check-parity.sh` | **done**, this branch |
| Terraform trimmed to the minimal set | **done**, this branch |
| 5 Lambda entry points (`vrc-lambda-fetch` …) | **not written** — the handlers that call into VRCCore |
| `DataStore` protocol + Data API implementation | **not written** — the one real porting task |
| Mac-side sync client (SigV4 against the API) | **not written** |

The two substantial pieces left are the `DataStore` implementation and the
Lambda handlers. Everything they depend on is done and tested.

---

## 8. What is blocking

| # | Blocker | Who |
|---|---|---|
| 1 | **Keychain credentials unreadable** — items are pinned to a pre-signing build's code hash, and macOS refuses without a prompt | **you**: two commands, §8.1 |
| 2 | Live feed-diff, which decides the $5 vs $20 question | follows from 1 |
| 3 | `DataStore` over the Data API | me, once 1–2 are settled |
| 4 | Lambda handlers | me |

### 8.1 The two commands

`set-url` now reads the URL with terminal echo cleared, **verifies it by
fetching and parsing before saving**, prints only the host and shape, and
refuses to save at all if stdin is not a terminal. The previous Keychain entry
is left in place; nothing is deleted or regenerated.

```
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc set-url --listing 2   # Airbnb
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc set-url --listing 1   # Vrbo
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc feed-diff --gap 300
```

I did not run these myself: it would mean putting your private feed URLs
through a command line, where they would appear in the transcript and in
process arguments. Pasting them into a non-echoing prompt keeps them out of
both.
