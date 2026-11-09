# Staging deployment — prepared, awaiting authorisation

**`terraform apply` has not been run. No AWS resource exists** — verified
against the live account. Outbound publishing is off, both schedules are
created disabled, and nothing touches PriyankaHomes or any DNS zone.

Prepared 2026-11-09.

---

## 0. Two findings before anything else

### 0.1 The repository is PUBLIC

You required it stay private. `gh api repos/hiteshtara/VacationRentalCalendar`
reports `"private": false, "visibility": "public"`. It was created 2026-11-09
and has been public since — roughly thirteen hours.

**No credentials are exposed.** Every blob in all 35 commits across 22 branches
was scanned (648 objects) for Airbnb/Vrbo/Booking.com iCal URLs, AWS access
keys, secret-key assignments, private-key blocks and generic high-entropy
assignments. **Nothing matched.** No AWS account id is committed either.

What *is* exposed: the property address (17 files), the Vrbo property id
(3 files), the Booking.com id (2 files), the Airbnb listing id (1 file),
`bostonfurnishedstays.com` (8 files), and the full architecture. Zero forks,
zero stars, zero watchers.

I tried to make it private and the permission system refused the action, which
is correct for an outward-facing account-level change. **You need to run:**

```
gh repo edit hiteshtara/VacationRentalCalendar \
  --visibility private --accept-visibility-change-consequences
```

### 0.2 Three broken documentation links, now fixed

`docs/PHASE2-PLAN.md`, `docs/PHASE2-PREFLIGHT.md` and
`docs/CENTRAL-ARCHITECTURE.md` linked to `001_central_schema.sql` and
`002_withdrawal_protection.sql`, which moved into `superseded/`. Repointed, and
each now carries a banner saying the schema it describes was replaced. All
**56** relative links in the repository resolve.

`docs/README.md` was never broken — I misread `ls` output earlier and said it
did not exist. It does.

---

## 1. Verification before deployment

| Check | Result |
|---|---|
| macOS tests | **323 passed, 1095 assertions** |
| Amazon Linux 2023 tests | **323 passed, 1095 assertions** |
| Parity digest, both platforms | `b3398471…c604f5`, identical |
| `011_safety_test.sql` | **41 / 41** |
| `004_concurrency_test.sh` | **7 / 7** |
| Lambda packages | 5 × 36 MB, `bootstrap` + 33 libs each |
| Credential scan, all history | **clean** |
| Markdown links | 56 / 56 resolve |

---

## 2. What was actually validated, and what could not be

### 2.1 Lambda startup — validated on the real runtime image

The `api` package was extracted into `/var/task` inside
`public.ecr.aws/lambda/provided:al2023` and the bootstrap run against a mock
Lambda Runtime API.

```
runtime image: Amazon Linux 2023.12.20261026
glibc:         2.34
unresolved shared objects: 0
RESPONSE: {"statusCode":503,"body":"{…\"error\":\"database unavailable\",
           \"remoteSynchronised\":false}"}
```

It started, polled `/invocation/next`, handled an API Gateway v2 event, posted a
well-formed proxy response, and printed nothing to stderr. The 503 is correct:
no database was configured, and the handler failed closed.

**That run exposed an ordering bug, now fixed.** The handler reached for the
database *before* checking authentication — so an unauthenticated request would
have **woken Aurora**, which matters for security and for the scale-to-zero cost
model. Authentication is now checked first and returns 401 without touching the
database.

### 2.2 IAM authentication — validated against live AWS

`VRCCore`'s own `SigV4Signer` was used to sign a real read-only
`sts:GetCallerIdentity` call:

```
HTTP 200
algorithm:  AWS4-HMAC-SHA256
SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date
AWS ACCEPTED the signature.
```

This is the same signer that authenticates the Mac to API Gateway (`AWS_IAM`)
and the Lambdas to the Data API, so AWS accepting it is the answer that matters.

### 2.3 Aurora Data API — endpoint and request shape validated; transactions not

The real `rds-data` endpoint was probed with a cluster ARN that does not exist:

```
Data API HTTP 400   (not 403)
ACCEPTED: the request was understood; it failed only because the cluster
          does not exist
```

A wrong signature, endpoint or body would have produced 403 or a protocol
error. 400 proves the signing, endpoint, headers and JSON shape are all
acceptable to the service.

**Transactions themselves are the one thing that genuinely requires the
cluster.** They are fully validated against real PostgreSQL 17 through the
repository layer — begin/commit/rollback, serialisation restarts, uncertain
commits — but against *Aurora over the Data API* they are untested until
staging exists. This is the main thing staging is for.

### 2.4 Mac API connectivity — validated over a real socket

`CloudSyncClient` through `URLSessionCloudTransport` against a local server
that verifies each request is genuinely SigV4-signed:

```
ok  GET /status over a real socket — events=7 approved=2
ok  remoteSynchronised is false
ok  outboundEnabled is false
ok  failing and stale sources surfaced — failing=1 stale=1
ok  GET /availability decodes
ok  an uncertain write stays UNKNOWN
ok  and never claims it was not applied

server observed: SIGNED: 6  UNSIGNED: 0  DISTINCT_IDEMPOTENCY_KEYS: 1
```

One distinct idempotency key across two submission attempts — the key is
derived from the decision's content, so a retry cannot become a second
decision.

### 2.5 Database recovery — rollback validated; PITR requires the cluster

Transaction rollback, commit durability and serialisation restarts are verified
against real PostgreSQL. Point-in-time restore needs an Aurora cluster and is a
staging test (§5, T9).

---

## 3. The staging plan

`terraform plan -var-file=staging.tfvars` → **60 to add, 0 to change, 0 to
destroy.** Every action is `create`.

| Type | n | Type | n |
|---|---|---|---|
| `aws_cloudwatch_log_group` | 6 | `aws_scheduler_schedule` (both **DISABLED**) | 2 |
| `aws_iam_role` | 5 | `aws_apigatewayv2_*` | 4 |
| `aws_iam_role_policy` | 5 | `aws_rds_cluster` | 1 |
| `aws_lambda_function` | 5 | `aws_rds_cluster_instance` | 1 |
| `aws_secretsmanager_secret` | 4 | `aws_rds_cluster_parameter_group` | 1 |
| `aws_s3_bucket` (+12 settings) | 3 | `aws_vpc` / `subnet`×3 / `sg` / `subnet_group` | 6 |
| `aws_subnet` | 3 | `aws_iam_user` + policy | 2 |
| | | `aws_lambda_permission`, `random_id`, `random_password` | 3 |

### 3.1 Staging is smaller than production, not a copy

| | Staging | Production |
|---|---|---|
| Route 53 records | **0 resources exist** | 1 |
| ACM certificates | **0** | 1 |
| CloudFront distributions | **0** | 1 |
| PriyankaHomes DynamoDB grant | **absent from the policy** | read-only, 2 ARNs |
| `deletion_protection` | false (destroyable) | true |
| `skip_final_snapshot` | true | false |
| Backup retention | 1 day | 7 days |
| Total resources | 60 | 65 |

Staging cannot touch DNS because **the resources do not exist** — not because a
flag is set. The same is true of its access to production bookings: the IAM
statement is absent, so there is nothing to misconfigure.

### 3.2 Verified from the plan JSON

```
schedules:              vrc-staging-import       state=DISABLED  rate(15 minutes)
                        vrc-staging-hold-sweeper state=DISABLED  rate(5 minutes)
engine_version:         16.15        min/max ACU: 0 / 2    auto-pause: 300s
Data API enabled:       true         publicly_accessible: false
storage_encrypted:      true         deletion_protection: false (staging)
dynamodb actions granted anywhere:   NONE
priyankahomes references:            0
route53 / acm / cloudfront types:    NONE
actions in plan:                     ['create']
secret values in the plan:           none (withheld as sensitive)
```

### 3.3 Four constraints are now plan-time assertions

`Infrastructure/terraform/checks.tf`. Each was confirmed to **fail the plan**
when violated:

| Assertion | Violated → |
|---|---|
| staging never publishes | `outbound_enabled=true` → plan fails |
| staging touches no DNS | `create_dns=true` → plan fails |
| staging cannot read production bookings | `allow_priyankahomes_read=true` → plan fails |
| imports start disabled | enabled schedule → plan fails |

The Lambda environment is assembled with `merge()`, whose result is unknown
until apply — so `terraform show` on a plan *cannot* prove what
`VRC_OUTBOUND_ENABLED` will be. A `check` block can, which is why these exist
rather than a note asking a reviewer to read the config.

---

## 4. Expected monthly cost — staging

| Item | Basis | Monthly |
|---|---|---|
| Aurora Serverless v2 compute | ~4 h of actual testing × 0.5 ACU × $0.12 | $0.24 |
| Aurora storage | 1 GB | $0.10 |
| Aurora I/O | ~250k requests | $0.05 |
| Aurora backups | 1-day retention, within the free allowance | $0.00 |
| Lambda, 5 functions | a few hundred invocations — perpetual free tier | $0.00 |
| API Gateway HTTP API | a few hundred requests | $0.00 |
| EventBridge Scheduler | **both schedules disabled: zero invocations** | $0.00 |
| S3, 3 buckets | < 1 GB | $0.03 |
| Secrets Manager | 4 secrets × $0.40 | $1.60 |
| CloudWatch Logs | 14-day retention, minimal volume | $0.10 |
| CloudWatch alarms | none created in staging | $0.00 |
| Route 53 / ACM / CloudFront | none created in staging | $0.00 |
| NAT gateway | none — the Data API keeps the Lambdas out of the VPC | $0.00 |
| **Total** | | **$2.12** |
| **Idle** (schedules off, nothing running) | | **$1.88** |

Dominated by Secrets Manager; everything else rounds to cents. Production, for
comparison, is $5.76/month in new money.

---

## 5. Staging test procedure

Run in order. Each step is reversible, and nothing enables publication.

| # | Test | How | Pass condition |
|---|---|---|---|
| T1 | Apply | `terraform apply -var-file=staging.tfvars` | 60 created; `terraform output environment` = `staging` |
| T2 | Schema | apply `010_repository_schema.sql` then `011_safety.sql` | 18 tables, 6 generated columns, 5 triggers |
| T3 | Runtime role | set the `vrc_runtime` password into `vrc-staging/database/runtime` out of band | the secret holds it; Terraform state does not |
| T4 | Safety guards | `psql -f tests/011_safety_test.sql` against the cluster | **41 / 41** |
| T5 | Concurrency | `tests/004_concurrency_test.sh` against the cluster | **7 / 7**, zero double bookings |
| T6 | **Data API transactions** | `VRC_PG_PORT` unset; point `DataAPIStore` at the cluster and run the repository workflow | identical business outcomes to SQLite — the one validation staging exists for |
| T7 | Lambda startup | invoke `vrc-staging-api` with an unsigned event | 401, and **Aurora stays paused** |
| T8 | IAM auth | call the API URL unsigned, then SigV4-signed | 403 from the gateway, then 200 |
| T9 | Recovery | restore the cluster to a point in time into a second identifier | all 18 tables and the guards present |
| T10 | Idempotency | `POST /decisions` twice with the same key | one decision, second answers `alreadyApplied` |
| T11 | Uncertain write | kill the function mid-write, then `GET /decisions/{uid}` | the client reports UNKNOWN, never "not applied" |
| T12 | Sweeper | enable only the sweeper; observe 24 h | expired holds released; no confirmed reservation touched |
| T13 | Imports | enable the import schedule; observe 48 h | change detection hit rate measured — settles the $5.76 vs $19.95 question |
| T14 | Teardown | `./Scripts/staging-teardown.sh --destroy` | nothing left; production intact |

Publication is **not** in this list. It stays off throughout.

---

## 6. Rollback and cleanup

`Scripts/staging-teardown.sh`, with three modes. `--check` was run against the
live account and reports:

```
==> What exists with the vrc-staging prefix
  ok   nothing exists — staging is clean
==> Confirming nothing outside staging was affected
  ok   PriyankaHomes tables still present: …bookings  …calendar
  ok   hosted zone bostonfurnishedstays.com still present
  ok   hosted zone 39gstboston.com still present
  ok   local SQLite intact: 2 approved decision(s)
```

The script refuses to run unless `terraform output environment` is `staging`,
requires typing `destroy staging` to confirm, re-inventories afterwards, and
asserts the PriyankaHomes tables, both hosted zones and the local SQLite
database are untouched.

Staging is destroyable because `deletion_protection = false` and
`skip_final_snapshot = true` for `environment = "staging"`. Production is the
reverse, so a destroy against it fails until someone deliberately turns
protection off — two explicit steps rather than one command.

One honest note: the Terraform-level `prevent_destroy` that used to sit on the
cluster is gone. It cannot be made conditional, so it would have blocked every
legitimate staging teardown. AWS-level `deletion_protection` carries production
instead.

Versioned buckets can refuse to delete while they hold object versions; the
script says so and prints the command to list them. `terraform destroy` is
idempotent, so re-running after emptying them completes.

---

## 7. Deployment authorisation requested

Everything above is prepared and nothing is applied. To proceed I need:

1. **Make the repository private** (§0.1) — you must run this.
2. **Explicit authorisation to run `terraform apply -var-file=staging.tfvars`**,
   creating the 60 resources listed in §3 at roughly **$2.12/month**.
3. Confirmation that T1–T14 in §5 is the procedure you want, in that order.

What stays untouched either way: the live PriyankaHomes website and its DNS, the
two DynamoDB tables, Google Calendar, both hosted zones, the two approved Vrbo
decisions — `2026-12-10→17` and `2026-12-19→20`, both still `approved`, both
`published = 0` — the seven events, the seven classifications, and
`OutboundSyncGate.isEnabled = false`.
