# Phase 2 preflight validation

> **Superseded.** The schema this document describes was replaced because the
> repositories could not query it. See
> [`Migrations/postgres/superseded/README.md`](../Migrations/postgres/superseded/README.md)
> and the generated replacement, `010_repository_schema.sql`.


**No AWS resources created. `terraform apply` was not run.** `terraform plan`
reports 55 to add, 0 to change, 0 to destroy. Outbound synchronisation is still
disabled. No live reservation or calendar block was modified. No PR merged.

Prepared 2026-11-09. Region `us-east-1`.

---

## 1. Feed-diff results

### 1.1 The hash logic is built and proven

`SemanticFeedHash` ([Sources/VRCCore/Sync/SemanticFeedHash.swift](../Sources/VRCCore/Sync/SemanticFeedHash.swift),
branch `backend/change-detection`) hashes the normalised parsed event set.

| Included — a change here changes what we publish | Excluded — moves without meaning |
|---|---|
| `UID`, `RECURRENCE-ID` | `DTSTAMP` |
| `DTSTART`, `DTEND` (resolved through `DURATION`) | `LAST-MODIFIED`, `CREATED` |
| `SUMMARY` | `SEQUENCE` |
| `DESCRIPTION`, `LOCATION` | `PRODID`, `CALSCALE`, `METHOD` |
| `STATUS` | event order, property order, line folding, whitespace |

`SEQUENCE` is excluded deliberately. It is meant to be a revision counter, but a
bump with identical dates, summary and status is not something we would act on,
and some producers increment it on regeneration.

**16 tests, all passing.** They cover both directions, because the two
requirements pull against each other:

| Must NOT change the hash | Must change the hash |
|---|---|
| regenerated `DTSTAMP` | changed check-in date |
| `LAST-MODIFIED` / `CREATED` / `SEQUENCE` / `PRODID` | changed check-out date |
| event reordering | changed `UID` |
| line folding and collapsed whitespace | changed `SUMMARY` ("Reserved" → "Blocked") |
| date-only vs. the same day at midnight | changed `STATUS` (confirmed → cancelled) |
| | an added event |
| | a removed event |
| | **an emptied feed** |

Two further tests: a field value cannot forge a field boundary (a `SUMMARY`
containing the separator character does not collide with a different event), and
`changedFieldNames` returns field **names** only, asserted to carry no values —
so a difference is loggable without disclosing reservation detail.

### 1.2 The live fetch is blocked, and not by anything in this work

I added `vrc feed-diff`, built and installed the certificate-signed app, and ran
it against the real feeds. Both sources refused at the Keychain:

> The Keychain item's access list names an older build of this app by its code
> hash. The app has since been signed with a certificate, so its hash changed
> and no longer matches. macOS does not prompt in this situation — it simply
> refuses.

This is the pre-existing ACL problem from the signing repair, not a new fault.
The items were created by an ad-hoc-signed build and are pinned by `cdhash`; the
certificate-signed build is a different program to macOS, and because the ACL
names a specific hash rather than a certificate, **macOS refuses without ever
offering a dialog**. There is nothing to approve.

**The offline control still ran, and the arithmetic holds:**

```
DTSTAMP changed only       → same hash (correct)
check-out date changed     → different hash (correct)
```

**One thing this did prove, on live data.** The failed fetch was a real test of
the rule you asked me to enforce, and it held:

```
Airbnb       outcome: disconnected   in feed: 0   removed: 0
Vrbo         outcome: disconnected   in feed: 0   removed: 0
Booking.com  outcome: disconnected   in feed: 0   removed: 0

Events after three failed imports: 7 active (unchanged)
```

Three feeds returned nothing and **not one event was withdrawn**. That is
exactly "do not reopen dates because a feed failed", demonstrated against the
real database rather than a fixture.

### 1.3 What I need you to run — one command per feed

The app's own repair path is to re-enter the URL. It writes a **fresh** Keychain
entry owned by the current build and leaves the old one untouched: nothing is
deleted, and no credential is regenerated. The import marked both listings
`credential_unreadable`, which is the state that arms the rotation, so the
reference moves `-v3` → `-v4` automatically.

```
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc set-url --listing 2   # Airbnb
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc set-url --listing 1   # Vrbo
```

Each prompts for the URL and reads it from standard input. It is not echoed, not
logged, and not written to the database or any file in the project.

I did not do this myself: it means putting your private feed URLs through a
command line, where they would appear in this transcript. Pasting them yourself
keeps them out of it entirely.

Then:

```
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc feed-diff --gap 300
```

**This is the one result that decides the cost question** (§3). It costs
nothing and runs before any AWS resource exists.

---

## 2. Database safety test results

[`Migrations/postgres/002_withdrawal_protection.sql`](../Migrations/postgres/superseded/002_withdrawal_protection.sql),
branch `backend/withdrawal-protection`. Three guards, each refusing by default.

**19 tests, all passing against PostgreSQL 17.** Each runs its statement,
asserts whether the guards refused it, and then asserts the rows are still
there — a refusal that lost data anyway reports `BADSTATE` rather than passing.

| Guard | Case | Expected | Actual |
|---|---|---|---|
| 1 | owner-classified event withdrawn by importer | REFUSE | REFUSE |
| 1 | locked event at only 10% of the feed | REFUSE | REFUSE |
| 1 | two *unlocked* events of 10 (20%) | ALLOW | ALLOW |
| 2a | **feed came back empty** (all 4 withdrawn) | REFUSE | REFUSE |
| 2a | single-event feed emptied | REFUSE | REFUSE |
| 2b | 4 of 6 withdrawn (67%) | REFUSE | REFUSE |
| 2b | 2 of 6 withdrawn (33%) — legitimate | ALLOW | ALLOW |
| 2b | exactly half (2 of 4) | ALLOW | ALLOW |
| AU | authorised, correct `listing:count` | ALLOW | ALLOW |
| AU | authorised, **wrong count** (says 3, actually 4) | REFUSE | REFUSE |
| AU | authorisation naming a **different listing** | REFUSE | REFUSE |
| AU | `actor='owner'` but no authorisation | REFUSE | REFUSE |
| AU | nothing declared at all | REFUSE | REFUSE |
| 3 | importer cancels a confirmed reservation | REFUSE | REFUSE |
| 3 | importer **shrinks** a confirmed stay | REFUSE | REFUSE |
| 3 | **owner** cancels a confirmed reservation | ALLOW | ALLOW |
| TR | `TRUNCATE source_events` | REFUSE | REFUSE |
| TR | `TRUNCATE availability_audit` | REFUSE | REFUSE |
| TR | `TRUNCATE reservations` | REFUSE | REFUSE |

Four design points worth your attention:

**Guard 1 is count-independent.** An event carrying your own classification
cannot be withdrawn by an importer even if it is 10% of the feed. This is what
preserves cancellation restrictions, owner blocks, maintenance blocks and
platform restrictions — those are precisely the events you classified.

**Authorisation names the listing *and* the exact count.** An authorisation
obtained for a 3-event withdrawal cannot silently cover a 300-event one.

**The default actor is the least-trusted one.** `vrc_current_actor()` defaults to
`'importer'`, so code that forgets to declare itself gets the strictest
treatment rather than the weakest. Tested by running with nothing declared.

**Shrinking a confirmed stay is blocked too**, not just cancelling it — moving
check-out from the 8th to the 3rd frees five nights just as surely.

### 2.1 Preservation, as requested

| Must be preserved | How |
|---|---|
| Confirmed reservations | guard 3: cannot leave `confirmed`, cannot shrink, on an import |
| Cancellation restrictions | guard 1 (locked classification) + excluded from `blocking_intervals` |
| Owner blocks | guard 1 |
| Maintenance blocks | guard 1 |
| Platform-specific restrictions | guard 1 + excluded from `blocking_intervals` |
| Outbound approval gates | untouched: `outbound_sync_enabled` is `false`, `approved_has_approver` still enforced |

### 2.2 A real bug this found

Applying `001` to a second database in the same cluster failed:
`role "vrc_app" already exists`. Roles are **cluster-wide**, not per-database, so
unconditional `CREATE ROLE` breaks a re-run or a second database. Fixed with an
existence guard, so the migration is idempotent — which it needs to be before it
is ever applied to Aurora. That is a defect that would have surfaced during
deployment; it surfaced in a scratch cluster instead.

---

## 3. Revised costs

**Unchanged from [PHASE2-PLAN.md](PHASE2-PLAN.md) §1**, because nothing I found
moves a price. Every unit price came from the AWS Pricing API.

| Scenario | New money | On the bill |
|---|---|---|
| Expected (change detection works) | **$6.01** | $7.01 |
| Worst case (feed volatility defeats it) | **$20.20** | $21.20 |
| Zero traffic | **$1.99** | $2.99 |

Per decision 1 these are planning estimates, not guaranteed billing.

**The deciding measurement is still outstanding** (§1.2). Until the live
feed-diff runs I cannot tell you which column is real, and I am not going to
narrow the range by assumption. Two notes on the inputs:

- The plan creates both schedules **disabled**, so applying it starts no polling
  and incurs no Aurora compute. The bill after `apply` sits at the zero-traffic
  floor until step 8 of the deployment order.
- The `$15` budget alarm is set between the two scenarios on purpose: if change
  detection fails, the alarm fires rather than the month ending in a surprise.

---

## 4. Secret inventory and justification

Three secrets, per decision 3 — "separate where independently justified". Each
has a **different reader** and a **different consequence if leaked**, which is
what makes the separation load-bearing rather than cosmetic.

| Secret | Contents | Read by | Consequence of disclosure |
|---|---|---|---|
| `vrc/database/master` | Aurora credentials | processor, publisher, api — via the Data API | full read/write of the system of record |
| `vrc/sources/feed-urls` | inbound platform export URLs | **fetcher only** | a third party can read your occupancy on Airbnb/Vrbo; the platform credential must be rotated at the platform |
| `vrc/outbound/feed-tokens` | 128-bit published-feed path secrets | **publisher only** | a third party can read the filtered feed; rotation is ours alone, by writing a new object key |

The justification is the fetcher. It is the component that parses **untrusted
third-party feed content**, and it is the one that holds no database credential
and no outbound token. Consolidating into a single secret would hand that
component the keys to the database and to the outbound feeds — the exact
privilege the split removes. $1.20/month against $0.40 buys that.

Neither the source URLs nor the outbound tokens have a
`aws_secretsmanager_secret_version` resource. Their values would land in
Terraform state and in this repository; they are written once, out of band.

The schema refuses them too: `credential_ref` and `token_ref` carry a `CHECK`
rejecting any value containing `://`, verified against a real Airbnb iCal URL.

---

## 5. Branch and PR dependency plan

PRs #1–#4 preserved. Nothing merged.

```
main
 └── feature/central-booking-system ............ PR #4   architecture + schema 001
      ├── backend/change-detection ............. PR #5   SemanticFeedHash + 16 tests
      ├── backend/withdrawal-protection ........ PR #6   migration 002 + 19 tests
      └── infra/terraform-foundation ........... PR #7   Terraform, plan only
```

| PR | Branch | Depends on | Review focus |
|---|---|---|---|
| #1 | iOS / CloudKit | — | **stale**; needs rebase. The browser dashboard may make it unnecessary — it reaches iPhone and iPad without the $99 enrolment |
| #2 | selective availability | — | unmerged, as instructed |
| #3 | calendar redesign | — | draft/partial |
| **#4** | `feature/central-booking-system` | main | architecture, schema, costs. **Merge first** |
| **#5** | `backend/change-detection` | #4 | the hash field list — the inclusion/exclusion decision is the whole design |
| **#6** | `backend/withdrawal-protection` | #4 | the 50% threshold and the authorisation format |
| **#7** | `infra/terraform-foundation` | #4 | IAM boundaries, the no-NAT decision, `min_capacity = 0` |

#5, #6 and #7 are independent of each other and can be reviewed in parallel.
Merge order: #4, then any order.

---

## 6. Terraform plan summary

`terraform validate` passes. `terraform plan` → **55 to add, 0 to change, 0 to
destroy.** Not applied.

| Type | n | Type | n |
|---|---|---|---|
| `aws_iam_role` | 5 | `aws_cloudfront_distribution` | 2 |
| `aws_iam_role_policy` | 5 | `aws_route53_record` (cert validation) | 2 |
| `aws_s3_bucket` | 4 | `aws_s3_bucket_lifecycle_configuration` | 2 |
| `aws_s3_bucket_versioning` | 4 | `aws_scheduler_schedule` (both **disabled**) | 2 |
| `aws_s3_bucket_public_access_block` | 4 | `aws_rds_cluster` | 1 |
| `aws_s3_bucket_server_side_encryption_configuration` | 4 | `aws_rds_cluster_instance` (`db.serverless`) | 1 |
| `aws_secretsmanager_secret` | 3 | `aws_rds_cluster_parameter_group` | 1 |
| `aws_subnet` | 3 | `aws_vpc` / `aws_security_group` / `aws_db_subnet_group` | 3 |
| `aws_acm_certificate` | 2 | `aws_kms_key` / `aws_kms_alias` | 2 |
| | | `aws_cloudfront_cache_policy` / `origin_access_control` | 2 |
| | | `random_id` / `random_password` | 2 |

**What is deliberately absent:** no NAT gateway, no internet gateway, no VPC
endpoint, no load balancer, no Lambda function, no public S3 bucket, and no
`aws_secretsmanager_secret_version` for either private-value secret.

The absent NAT gateway is the point. Lambda in a VPC would need one for the
importer's outbound internet access, at roughly $32/month — more than every
other line item combined. `enable_http_endpoint = true` on the cluster is what
avoids it: SQL over HTTPS, so the Lambdas never join the VPC.

The VPC exists only because a DB subnet group must span two availability zones.
Its subnets are private with no route to the internet, and the security group
has **no ingress rule at all** — nothing needs to reach the cluster over the
network.

Verified in the configuration:

| Setting | Value |
|---|---|
| `min_capacity` / `max_capacity` | 0 / 4 ACU |
| `seconds_until_auto_pause` | 300, with a variable validation rejecting less |
| `engine_version` | 16.4 (0-ACU needs ≥ 16.3) |
| `enable_http_endpoint` | true |
| `deletion_protection` | true |
| `skip_final_snapshot` | false |
| `lifecycle { prevent_destroy }` | true on the cluster |
| `storage_encrypted` + `kms_key_id` | true, project CMK |
| `publicly_accessible` | false |
| both schedules | `state = "DISABLED"` |
| DynamoDB actions granted | `BatchGetItem`, `GetItem`, `DescribeTable` on two table ARNs — **no write action** |
| publisher `s3:DeleteObject` | **not granted** — clearing a feed is not expressible |

The production S3 backend block is **commented out**, so a review plan cannot
touch remote state and `apply` cannot run against real state before the bucket
exists. Uncommenting it is part of the apply sequence, not of review.

---

## 7. Remaining implementation risks

| # | Risk | Severity | Status |
|---|---|---|---|
| 1 | **Feed volatility defeats change detection** → $20/month, not $6 | High | **open** — decided by §1.3; costs nothing to settle |
| 2 | Keychain ACL blocks live feed reads | High | **open** — two commands in §1.3; app repair path, non-destructive |
| 3 | `VRCCore` has never been compiled for Linux | High | open — ~94% measured portable, but not yet proven. First Phase 2 task after §1.3; no Swift SDK is installed |
| 4 | Swift on Lambda is a less-travelled runtime | Medium | open — mitigated by the static Linux SDK needing no Docker, which matters with no Xcode |
| 5 | 203→219 tests have never run against PostgreSQL | High | open — the real gate on the port |
| 6 | Aurora 15-second resume inside a guest checkout | Medium | deferred by decision 3; CDN-cached read path is the design answer |
| 7 | Data API 1 MB result limit | Low | open — paginate; our rows are small |
| 8 | Data API free tier is first-year only | Low | documented — ~$0.35/million after |
| 9 | 50% withdrawal threshold may be wrong for a feed that legitimately empties seasonally | Medium | open — authorisation path exists; threshold is a one-line change |
| 10 | Google credential failure stops all direct bookings | High | **live today**, in the existing system; unmitigated until G4 |
| 11 | Terraform state holds the Aurora master password | Medium | mitigated — encrypted S3 backend; or switch to `manage_master_user_password` |
| 12 | A second property would need a `feed_host` and a new ACM certificate | Low | schema and variables already support it |

Risks 1, 2 and 5 are the ones blocking Phase 2. The first two are settled by the
two commands in §1.3.

---

## 8. What was explicitly not done

No AWS resources created — `terraform apply` was not run. No DNS changed. No
outbound synchronisation enabled. No live reservation or calendar block
modified. No PR merged. No credential deleted or regenerated. The two approved
Vrbo decisions, seven events and seven classifications are intact, and
`OutboundSyncGate.isEnabled` is still `false`.

The one state change I did make: running `vrc import` let the app record what it
found, moving both listings from `connected` to `credential_unreadable`. That is
an accurate observation, it is what arms the non-destructive repair path, and it
withdrew no events.
