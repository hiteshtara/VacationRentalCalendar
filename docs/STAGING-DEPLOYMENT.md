# Staging deployment — prepared, awaiting authorisation

**`terraform apply` has not been run. No AWS resource exists** — verified
against the live account. Outbound publication is off at every layer, both
schedules are created disabled, and nothing touches the PriyankaHomes website,
its DNS or its booking data.

Prepared 2026-11-09. Revised after review.

---

## 0. Repository visibility — corrected

The repository is **public by choice**. That is settled, it is not a deployment
blocker, and nothing below treats it as one. My earlier draft framed it as a
problem; that was wrong.

What it does change is that keeping credentials and reservation data out of the
repository is now a **standing** requirement rather than a one-off audit. So it
is a script:

```
./Scripts/check-no-secrets.sh            # working tree + all 679 objects of history
./Scripts/check-no-secrets.sh --staged   # just what is about to be committed
```

It refuses tracked `*.sqlite`, `*.tfstate`, `*.pem`, `id_rsa` and friends, and
scans for Airbnb/Vrbo/Booking.com iCal URL shapes, AWS key ids, secret-key
assignments, private-key blocks, and guest name/email fields. Current result:
**clean**, across the working tree and every blob in every commit. It is usable
as a pre-push hook:

```
ln -s ../../Scripts/check-no-secrets.sh .git/hooks/pre-push
```

**What is public and is meant to be:** the architecture, the schema, the
business rules, the property address and the three platform listing ids — all
of which identify a listing that is already advertised publicly.

**What must never be:** the feed URLs (bearer credentials — anyone holding one
reads your occupancy), AWS keys, the SQLite database, Terraform state, and any
guest name, email or payment detail. None of these are in the repository, and
the schema is built so they cannot drift in: `credential_ref` and `token_ref`
carry a `CHECK` rejecting any value containing `://`, and the reservation table
has no column for a guest name or email at all.

---

## 1. Verification before any apply

| Check | Result |
|---|---|
| macOS tests | **330 passed, 1109 assertions** |
| Amazon Linux 2023 tests | 330 passed |
| Parity digest, both platforms | `b3398471…c604f5`, identical |
| `011_safety_test.sql` | 41 / 41 |
| `004_concurrency_test.sh` | 7 / 7 |
| Lambda packages | 5 × 36 MB, `bootstrap` + 33 libs |
| Credential scan | clean, working tree and full history |
| Markdown links | 56 / 56 resolve |

Three broken documentation links were fixed: `docs/PHASE2-PLAN.md`,
`docs/PHASE2-PREFLIGHT.md` and `docs/CENTRAL-ARCHITECTURE.md` pointed at
`001`/`002` after those moved into `superseded/`. Each now also carries a
banner saying the schema it describes was replaced.

---

## 2. Refinement 1 — migrations and tests against a private cluster

The cluster is deliberately unreachable: private subnets, no internet route, no
public access, and a security group with **no ingress rule at all**. There is
nothing to tunnel to, so the question is not "how do we open a hole safely" but
"what path exists that is not a hole".

**The RDS Data API is that path.** It is not a route into the VPC — it is a
regional AWS service endpoint that executes SQL on your behalf, authorised by
IAM and SigV4. No bastion, no VPN, no SSH tunnel, no publicly accessible
database, and no database password ever handled by the client: the Data API
reads it from Secrets Manager by ARN.

That endpoint is already validated: signed with `VRCCore`'s own `SigV4Signer`,
a probe against a non-existent cluster returned **400, not 403**, proving the
signing, endpoint, headers and JSON shape are all acceptable to the service.

### 2.1 Migrations — `vrc-migrate`

```
export VRC_CLUSTER_ARN=arn:aws:rds:us-east-1:…:cluster:vrc-staging-main
export VRC_DB_SECRET_ARN=…:secret:vrc-staging/database/master
export VRC_DB_NAME=vrc

swift run vrc-migrate --status
swift run vrc-migrate --dry-run Migrations/postgres/010_repository_schema.sql
swift run vrc-migrate --apply   Migrations/postgres/010_repository_schema.sql
swift run vrc-migrate --apply   Migrations/postgres/011_safety.sql
```

Migrations run as the cluster's **master** identity, because they are DDL and
the restricted `vrc_runtime` role has no DDL rights by design. Point
`VRC_DB_SECRET_ARN` at the master secret for the migration and back at the
runtime secret afterwards — the Lambdas never see the master ARN at all.

Everything runs inside one Data API transaction. PostgreSQL DDL is
transactional, so a failure part-way applies nothing, and the tool says so
rather than leaving you guessing. An unconfirmed commit is reported as
**UNKNOWN** with instructions to check `--status` first, never as success or
failure.

**A prerequisite bug this surfaced.** The Data API accepts one statement at a
time, so a migration file has to be split — and `SQLScanner.splitStatements`
did not understand dollar-quoted function bodies. It turned one
`CREATE FUNCTION` into **five** "statements":

```
statements found: 5  (correct answer: 2)
  [0] CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$ BEGIN
  [1] RETURN 2
  [2] END
  [3] $$
  [4] CREATE TABLE t (x int)
```

`011_safety.sql` is nine function bodies, so every one would have been shredded
and the migration would have half-built the schema before failing. Fixed, with
seven tests pinning it, and `vrc-migrate` additionally **refuses to run** a file
in which any statement has unbalanced `$$`. Current split: 18 and 49 statements,
9 functions intact, zero unbalanced.

### 2.2 Tests — Swift over the Data API, not psql

The SQL suites (`011_safety_test.sql`, `004_concurrency_test.sh`) use `psql`
meta-commands and shell-driven concurrent sessions. They cannot run over the
Data API and they are **not** the Aurora verification path; they run against a
local PostgreSQL 17 and are where the guard logic is developed.

Against Aurora, the verification is the Swift suite. `PostgresIntegrationTests`
already drives the real repository layer through a `DataAPIStore`; pointing it
at the cluster instead of local Postgres runs the same business-outcome
comparison, the same generated-column check, the same rollback test and the
same allow-list check — through the same code path the Lambdas use. Concurrency
is exercised with two `DataAPIStore` instances on two threads, which is a
genuine test of the Data API's transaction isolation rather than of psql's.

So: no public database, no bastion, no psql against Aurora, and the thing being
tested is the production code path.

---

## 3. Refinement 4 — outbound publication is off at four independent layers

| # | Layer | State | Who can change it |
|---|---|---|---|
| 1 | `OutboundSyncGate.isEnabled` in Swift | `false` | a reviewed code change |
| 2 | `VRC_OUTBOUND_ENABLED` in every function's environment | `"false"` | a Terraform variable |
| 3 | `precondition` on `terraform_data.staging_invariants` | **errors and stops** plan and apply | nobody, in staging |
| 4 | `app_settings.outbound_sync_enabled` in the database | `'false'` | a deliberate SQL write |

Layer 3 exists because the Lambda environment is assembled with `merge()`,
whose result is unknown until apply — so `terraform show` on a plan **cannot**
prove what layer 2 will be.

**A correction.** Earlier revisions of this document said a Terraform `check`
block would fail the plan. That is wrong, and I verified it:

```
terraform plan -var=outbound_enabled=true
  exit code: 0       warnings: 1       errors: 0
  plan file written: YES (29287 bytes)
```

A `check` block **warns**. It exits zero and still writes an applyable plan.
Anything relying on it as a gate was relying on nothing.

The gates are now `precondition` blocks, which raise errors and stop both plan
and apply. Verified by trying to get past each one:

```
  outbound_enabled=true          exit=1  BLOCKED
  create_dns=true                exit=1  BLOCKED
  create_cdn=true                exit=1  BLOCKED
  allow_priyankahomes_read=true  exit=1  BLOCKED
  region=eu-west-1               exit=1  BLOCKED
```

The `check` blocks are kept, relabelled as reporting only.

There is also no publication path to misfire into: staging creates **no**
CloudFront distribution and **no** DNS record, so even a feed written to S3 is
not publicly reachable, and the publisher's IAM policy has no
`cloudfront:CreateInvalidation` grant because there is no distribution to
invalidate.

---

## 4. Refinement 2 — re-validate immediately before apply

```
./Scripts/staging-preflight.sh
```

Run it in the same shell session as the apply. A plan reviewed yesterday is not
the plan that applies today: providers move, and AWS retires engine versions —
**16.4 disappeared from us-east-1 while this project was being written**, which
would have failed an apply that trusted an older plan.

It re-derives the plan and re-checks every invariant, then prints one verdict.
Current run:

```
==> 0. Account and region
  ok   account ends …1110
  ok   region is us-east-1
==> 1. Business rules
  ok   All 330 tests passed (1109 assertions)
  ok   parity digest unchanged
  ok   OutboundSyncGate.isEnabled = false in code
==> 2. Migrations are safe to send over the Data API
  ok   010_repository_schema.sql: dollar quotes balanced
  ok   011_safety.sql: dollar quotes balanced
==> 3. Lambda packages
  ok   fetch.zip … sweeper.zip: bootstrap + 33 libs
==> 4. Re-deriving the staging plan
  ok   plan succeeded and was saved (preconditions held)
  ok   58 AWS resources to create, as expected (+3 local-only)
  ok   the precondition carrier is in the plan
  ok   nothing to update or destroy
  ok   no Route 53, ACM or CloudFront resources
  ok   no DynamoDB access granted
  ok   no PriyankaHomes references
  ok   both schedules created DISABLED
  ok   cluster: 16.15, Data API on, private, encrypted, 0–2 ACU
  ok   the writer instance is not publicly accessible
  ok   no secret values in the plan
==> 5. Production is where it should be
  ok   both PriyankaHomes tables present
  ok   hosted zone bostonfurnishedstays.com present
  ok   hosted zone 39gstboston.com present
  ok   2 approved decisions
  ok   0 published decisions
  ok   7 events
  ok   7 classifications
==> 6. Independent enforcement
  ok   staging.tfvars declares environment = staging
  ok   create_dns = false in tfvars
  ok   create_cdn = false in tfvars
  ok   allow_priyankahomes_read = false in tfvars
  ok   outbound_enabled unset, so it defaults to false
==> 7. Proving the refusals still refuse
  ok   outbound_enabled=true is refused (non-zero exit)
  ok   create_dns=true is refused (non-zero exit)
  ok   allow_priyankahomes_read=true is refused (non-zero exit)
==> Verdict
  GO — the plan is valid and every invariant holds independently.
  Saved plan:  Infrastructure/terraform/staging.tfplan
  sha256:      7b545fbd…d48daa
```

It exits non-zero on any failure, so it can gate the apply rather than merely
inform it.

---

## 5. The staging plan

**60 to add, 0 to change, 0 to destroy.** Every action is `create`.

| Type | n | Type | n |
|---|---|---|---|
| `aws_cloudwatch_log_group` | 6 | `aws_scheduler_schedule` (both **DISABLED**) | 2 |
| `aws_iam_role` | 5 | `aws_apigatewayv2_*` | 4 |
| `aws_iam_role_policy` | 5 | `aws_rds_cluster` | 1 |
| `aws_lambda_function` | 5 | `aws_rds_cluster_instance` | 1 |
| `aws_secretsmanager_secret` | 4 | `aws_rds_cluster_parameter_group` | 1 |
| `aws_s3_bucket` (+12 settings) | 3 | `aws_vpc`, 3 × `subnet`, `sg`, `subnet_group` | 6 |
| `aws_subnet` | 3 | `aws_iam_user` + policy | 2 |
| `aws_s3_bucket_lifecycle_configuration` | 2 | `lambda_permission`, `random_id`, `random_password` | 3 |

### 5.1 Staging is smaller than production, not a copy

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

Staging cannot touch DNS because **the resources do not exist**, not because a
flag is set. The same is true of its reach into production bookings: the IAM
statement is absent, so there is nothing to misconfigure.

### 5.2 Cost — $2.12/month, $1.88 idle

| Item | Basis | Monthly |
|---|---|---|
| Aurora Serverless v2 compute | ~4 h of testing × 0.5 ACU × $0.12 | $0.24 |
| Aurora storage | 1 GB | $0.10 |
| Aurora I/O | ~250k requests | $0.05 |
| Aurora backups | 1-day retention, within the free allowance | $0.00 |
| Lambda, 5 functions | a few hundred invocations — perpetual free tier | $0.00 |
| API Gateway HTTP API | a few hundred requests | $0.00 |
| EventBridge Scheduler | **both disabled: zero invocations** | $0.00 |
| S3, 3 buckets | < 1 GB | $0.03 |
| Secrets Manager | 4 secrets × $0.40 | $1.60 |
| CloudWatch Logs | 14-day retention | $0.10 |
| Route 53 / ACM / CloudFront / NAT | **none created** | $0.00 |
| **Total** | | **$2.12** |

Dominated by Secrets Manager. Production, for comparison, is $5.76/month.

---

## 6. Staging test procedure, reordered

Refinements 3 and 7: smoke tests come before any schedule is enabled, Mac
connectivity is reached early, and the long observations are later tests rather
than prerequisites.

### Phase A — bring it up (no schedules, no imports)

| # | Test | Pass condition |
|---|---|---|
| A1 | `./Scripts/staging-preflight.sh` | **GO** |
| A2 | `./Scripts/staging-apply.sh` — applies the **saved** plan, refusing if its hash moved | 58 AWS resources created; `terraform output environment` = `staging` |
| A3 | `vrc-migrate --apply 010` then `011` | `--status` reports `10, 11`; 18 tables, 6 generated columns, 5 triggers |
| A4 | Set the `vrc_runtime` password into `vrc-staging/database/runtime` out of band | the secret holds it; Terraform state does not |
| A5 | Deploy function code: `./Scripts/build-lambda.sh --deploy` | five functions updated; schedules still disabled |

### Phase B — smoke tests, before anything is scheduled

| # | Test | Pass condition |
|---|---|---|
| B1 | Invoke `vrc-staging-api` with an **unsigned** event | 401, and **Aurora stays paused** — authentication precedes the database |
| B2 | Call the API URL unsigned over HTTPS | 403 from the gateway, before the function runs |
| B3 | Call it **SigV4-signed** from the Mac: `vrc-verify-sigv4 --mac-api <url>` | 200; `remoteSynchronised: false`; `outboundEnabled: false` |
| B4 | Invoke `vrc-staging-sweeper` once, by hand | `holdsReleased: 0`; no confirmed reservation touched |
| B5 | **Data API transactions**: point the Swift suite at the cluster | identical business outcomes to SQLite — the one thing staging exists to prove |
| B6 | Concurrency over the Data API: two stores, two threads, overlapping holds | exactly one winner; zero double bookings |
| B7 | `POST /decisions` twice with one idempotency key | one decision; the second answers `alreadyApplied` |
| B8 | Kill a function mid-write, then `GET /decisions/{uid}` | the client reports **UNKNOWN**, never "not applied" |
| B9 | Confirm publication is still impossible | all four layers of §3 still off |

**Mac-to-AWS connectivity is B3 — reached before any schedule is enabled, and
not gated on any observation window.**

### Phase C — recovery, into an isolated temporary cluster

Refinement 5. Restore is **never** performed onto the staging cluster; it goes
to a separate identifier, is verified, and is then deleted.

| # | Test | Pass condition |
|---|---|---|
| C1 | `aws rds restore-db-cluster-to-point-in-time --source-db-cluster-identifier vrc-staging-main --db-cluster-identifier vrc-staging-pitr --use-latest-restorable-time` | a second, independent cluster appears |
| C2 | Point `vrc-migrate --status` at `vrc-staging-pitr` | reports `10, 11` |
| C3 | Run the safety assertions against the restored cluster | guards and triggers present and refusing |
| C4 | Confirm the restore is isolated | `vrc-staging-main` untouched; the two clusters share no instance |
| C5 | `aws rds delete-db-cluster --db-cluster-identifier vrc-staging-pitr --skip-final-snapshot` | the temporary cluster is gone; staging intact |

A restored Aurora cluster is a full copy with its own endpoint and its own
Data API ARN, so C2–C3 target it explicitly. The temporary cluster is the
reason staging's `deletion_protection` is off: a recovery drill that cannot be
cleaned up is not a drill.

### Phase D — schedules, and the long observations

Only after Phase B passes. These are tests, not prerequisites for anything in
A–C.

| # | Test | Pass condition |
|---|---|---|
| D1 | Enable **only** the hold sweeper | expired holds released; confirmed reservations untouched |
| D2 | Observe 24 h | no unexpected writes; Aurora pauses between runs |
| D3 | Enable the import schedule | imports run; nothing published |
| D4 | Observe 48 h | change-detection hit rate measured — settles $5.76 vs $19.95 |
| D5 | Teardown drill: `./Scripts/staging-teardown.sh --destroy` | nothing left; production intact |

Publication appears nowhere in A–D. It stays off throughout.

---

## 7. Rollback and cleanup

`./Scripts/staging-teardown.sh` with `--check`, `--dry-run`, `--destroy`. It
refuses unless `terraform output environment` is `staging`, requires typing
`destroy staging`, re-inventories afterwards, and asserts the PriyankaHomes
tables, both hosted zones and the local SQLite database are untouched.

`--check` against the live account now:

```
==> What exists with the vrc-staging prefix
  ok   nothing exists — staging is clean
==> Confirming nothing outside staging was affected
  ok   PriyankaHomes tables still present: …bookings  …calendar
  ok   hosted zone bostonfurnishedstays.com still present
  ok   hosted zone 39gstboston.com still present
  ok   local SQLite intact: 2 approved decision(s)
```

Staging is destroyable because `deletion_protection = false` and
`skip_final_snapshot = true` for `environment = "staging"`. Production is the
reverse, so a destroy against it fails until someone deliberately turns
protection off — two explicit steps rather than one command.

The Terraform-level `prevent_destroy` that used to sit on the cluster is gone:
it cannot be made conditional, so it would have blocked every legitimate
staging teardown and every recovery drill. AWS-level `deletion_protection`
carries production instead.

Versioned buckets can refuse to delete while they still hold object versions;
the script says so and prints the command to list them. `terraform destroy` is
idempotent, so re-running after emptying them completes.

---

## 8. What is preserved, and what is never touched

Refinements 6 and 8.

| Preserved | State |
|---|---|
| The macOS application | unchanged; still the system of record locally |
| Vrbo decision #1 | `2026-12-10 → 2026-12-17`, **approved**, `published = 0` |
| Vrbo decision #2 | `2026-12-19 → 2026-12-20`, **approved**, `published = 0` |
| December 17 and 18 | covered by **no** decision — deliberately sellable |
| Publication UIDs | `vrc-812d1978…`, `vrc-a5a1dbf5…`, unchanged |
| Seven events, seven classifications | unchanged |
| `OutboundSyncGate.isEnabled` | `false` |

| Never touched | Why it cannot be |
|---|---|
| PriyankaHomes website | no resource in the plan references it |
| Its DNS | staging creates **zero** Route 53 resources |
| Its booking data | staging has **no** DynamoDB grant at all |
| Google Calendar | no credential, no code path, no grant |
| Both hosted zones | asserted present by preflight and teardown |
| The local SQLite database | nothing in AWS can reach it |

---

## 8a. The five final safeguards

### 8a.1 Account and region, checked first and fatally

`staging-preflight.sh` now begins there, before it looks at anything else: a
plan that looks perfect applied to the wrong account is the worst available
outcome. It prints only the last four digits, so a shared log carries no
account id.

```
==> 0. Account and region
  ok   account ends …1110
  ok   region is us-east-1
```

Either mismatch exits immediately without running the remaining checks.
`region == "us-east-1"` is also a hard `precondition`, so a tfvars override is
refused.

### 8a.2 The validated plan is the plan that applies

Preflight writes `Infrastructure/terraform/staging.tfplan` and a receipt
recording its SHA-256, the account, the region and the resource count.
`Scripts/staging-apply.sh` applies **that file** — `terraform apply
staging.tfplan`, with no `-var-file`, because a saved plan already carries its
variables — and refuses unless the hash still matches.

All four refusal paths were tested:

| Tampered with | Result |
|---|---|
| one byte appended to the plan | refused, both hashes printed |
| receipt removed | refused: "run preflight first" |
| receipt edited to `verdict=NO-GO` | refused |
| wrong confirmation phrase | cancelled, nothing applied |

After a successful apply both the plan and the receipt are deleted, because a
saved plan is single-use and a stale one must not invite a second go.

### 8a.3 Enforcement independent of Terraform

Three layers, since safeguard 3 asks not to rely on Terraform alone:

1. **`precondition` blocks** — error and stop. Terraform checking itself.
2. **tfvars inspection** — preflight greps `staging.tfvars` directly for
   `environment = "staging"`, `create_dns = false`, `create_cdn = false`,
   `allow_priyankahomes_read = false`, and that `outbound_enabled` is either
   absent or false.
3. **Saved-plan inspection** — preflight reads the plan JSON and asserts: 58
   AWS resources, nothing to update or destroy, **zero** Route 53/ACM/
   CloudFront resources, **zero** DynamoDB actions, zero PriyankaHomes
   references, both schedules `DISABLED`, engine 16.15, Data API on, private,
   encrypted, and no secret values present.

Layer 3 is what catches a plan file edited or swapped after review — which is
the case neither Terraform layer can see.

Preflight additionally **proves the refusals still refuse**, by attempting
`outbound_enabled=true`, `create_dns=true` and `allow_priyankahomes_read=true`
and requiring each to exit non-zero. A guard that has silently stopped working
is worse than no guard, and this is the only way to know.

### 8a.4 GitHub stays public

Settled. Nothing in the deployment path reads or changes repository visibility.
`Scripts/check-no-secrets.sh` is the standing guard, and it reports clean.

### 8a.5 Stop on anything other than GO

Preflight exits non-zero on any failure **and removes the receipt**, so
`staging-apply.sh` independently refuses afterwards. Stopping is not a matter
of remembering to read the output.

That was demonstrated accidentally and usefully: adding the precondition
carrier changed the resource count from 60 to 61, the count check failed, the
verdict went NO-GO and the receipt was removed. The gate caught its own
author's change. The count is now split into AWS resources (58) and local-only
helpers (3), so it tracks what matters instead of drifting.

## 9. Authorisation requested

Everything above is prepared. Nothing is applied.

All five safeguards are in place and tested. Nothing is applied.

**To proceed I need explicit authorisation to run `./Scripts/staging-apply.sh`**
— applying the already-validated plan: **58 AWS resources**, roughly
**$2.12/month**, in the `us-east-1` account ending **…1110**.

Phase A1 (preflight) has been run and reports **GO**. A2 is the apply and has
not been run. I will re-run preflight immediately beforehand and stop unless it
reports GO again.

I will then work through A3–A5 and the Phase B smoke tests, and **report the
first successful Mac-to-AWS connection (B3) before touching any schedule.**
Phase D — schedules and the 24 h/48 h observations — waits for that report.

Repository visibility stays public.
