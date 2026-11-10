# Handoff

State of play for whoever picks this up next — a new Claude Code session, or a
person. Written to be followed **without** prior conversation history.

Updated 2026-11-09. Read [CLAUDE.md](CLAUDE.md) first for the rules and the
traps; this file is "where things stand and exactly what to do".

---

## The integration suite truncates — and is now prevented from truncating anything shared

**This is enforced in code as of `096d0ba`. It is no longer a rule to remember.**

`swift run vrc-test "PostgreSQL integration"` deletes rows: its setup empties
`properties`, `reservations`, `holds`, `events`, `classifications`,
`availability_decisions`, `platform_listings`, `sync_runs` and more before each
case, so it can compare a known workflow against a known starting point. That is
correct for a scratch database and destructive anywhere else.

**What went wrong.** On 2026-11-09 the suite was pointed at the shared staging
cluster to validate B6 and emptied it, destroying the synthetic demo rows, 2
synthetic approved decisions and the Airbnb `platform_listings` row.
`Scripts/seed-staging-demo.sql` restores only the property, one reservation and
one hold, so the rest was gone. No real data was lost — the 7 events, 7
classifications and 2 Vrbo decisions live in local SQLite, were never a
target, and are re-verified in §9.

**What now prevents it.**
[`DestructiveTestIsolation`](Sources/VRCCore/Database/DestructiveTestIsolation.swift)
fails closed: a target is refused unless it proves itself disposable, and all
four of these must hold.

| | Requirement | Refused if |
|---|---|---|
| 1 | `VRC_DESTRUCTIVE_TESTS=i-understand-this-truncates` | unset, or any other value — `1`, `true`, `yes` are all refused |
| 2 | Not on the deny-list: `vrc-staging-main`, `prod`, `production`, `priyanka`, `vrc-live` | matched case-insensitively as a substring, checked **first** and overriding everything else, so `vrc-staging-main-scratch` is still refused |
| 3 | A cluster identifier containing `scratch`, `throwaway`, `disposable`, `pitr`, `ephemeral` or `sandbox` | any other name, including one nobody has considered — allow-list, not deny-list |
| 4 | `app_settings.disposable_database = 'true'` **in the target database** | absent, not `true`, or **unreadable** — an unknown answer is a refusal |

Requirement 4 is the strongest, because it travels with the database rather than
with the invocation: a shared cluster does not have the marker and cannot acquire
one by accident. `app_settings` is deliberately excluded from the truncation list
so the marker survives the operation it authorizes.

The guard sits **inside** `truncateForTest`, the only function in the suite that
deletes rows, rather than being a precondition each caller must remember. The
local `psql` path goes through the same door — a port is no safe harbour, since a
tunnel can put a shared cluster behind `127.0.0.1`.

**Verified against the real cluster, not only in unit tests.** Pointed at
`vrc-staging-main` with full consent *and* a marker, every case refuses, and
staging's row counts are identical before and after (`properties=2`,
`reservations=1`, `holds=3`, `availability_audit=41`). On a marked local sandbox
the group still runs 10/10 — which is the half no refusal test can prove.

Compare `RehearsalIsolation`, which solves the same shape of problem for
publication rehearsals against the local SQLite database.

---

## 0. One-line status

The Mac app is installed and working, it shows **live data from the deployed AWS
staging backend**, and as of 2026-11-10 it holds **real imported observations**:
**Airbnb 4 events and Vrbo 3 events**, fetched from the live feeds. Booking.com
is the only feed still disconnected (§13). Staging validation is complete
(A1–A5, B1–B9, Phase C). Scheduled imports and outbound publishing remain
**off** at every layer.

Two things need the owner's attention, both in §13 and §14: Booking.com needs a
fresh export URL, and the two December Vrbo decisions now read `cancelled`
rather than approved.

---

## 1. Current status and completed milestones

| Area | State |
|---|---|
| macOS app | built, signed, installed at `/Applications/VacationRentalCalendar.app` |
| Cloud integration | **working** — the app reads live status/availability from AWS staging via the bundled `vrc` helper |
| Real feeds | **Airbnb and Vrbo connected and importing** (4 and 3 events). Booking.com disconnected — needs a new export URL (§13) |
| AWS staging | **deployed** in account …1110, us-east-1; cluster + 5 Lambdas + API Gateway + 3 buckets + 4 secrets |
| Tests | **370 tests**, passing on macOS (1229 assertions; 1248 with the PostgreSQL group live). 369/369 verified on Linux at `02f6df6` — the one newer test is pure Swift with no platform surface |
| Cross-platform parity | byte-identical digest `b3398471b1ee56f477d9a1244b16449e8827df1616aa5fca365ef3db96c604f5` |
| Staging smoke tests | **ALL COMPLETE: A1–A5, B1–B9, and Phase C C1–C5.** See §5 and §12 |
| Outbound publishing | **off** — code gate, function env and database setting all verified `false` 2026-11-09; Terraform precondition not re-checked (§4) |
| Scheduled imports | **disabled** (both EventBridge schedules DISABLED) |

Completed milestones, newest first:
1. **Phase C complete, and B7/B8 complete — the staging validation programme is
   finished.** Phase C re-run against a second temporary cluster
   (`vrc-staging-pitr2`) with the corrected `aws rds enable-http-endpoint` call:
   **27 checks, 0 failures**, covering recovery consistency against the source,
   migrations 10/11, the generated columns, triggers, both exclusion
   constraints, the allow-list function on all six `BlockKind`s, a guard that
   actually refuses, and the source cluster untouched. B7 and B8 then ran
   against that disposable cluster through the deployed artifact under the
   Lambda Runtime Interface Emulator: **14 checks, 0 failures**. Temporary
   resources deleted and cleanup verified by inventory. §12 has the detail,
   including a credential asymmetry worth following up.
2. **Linux verification, and three faults it exposed in `build-lambda.sh`**
   (commit `02f6df6`). All **369 tests now pass on Linux**, parity digest
   identical to macOS. Getting there required fixing the script: it never
   copied `Migrations/` into the container, so a test that reads those files
   failed for want of a file — the "1 of 350 failed, not reproducible, likely a
   timing flake" note in earlier handoffs was this, and it was fully
   deterministic. It also printed `ok` for a failing suite, and its gates ran
   inside a piped subshell with no `set -e`, so **a DIVERGED parity digest
   would have printed a failure and shipped anyway** — contradicting CLAUDE.md's
   claim that this script refuses to deploy on divergence. All three fixed; the
   shell semantics were reproduced directly rather than assumed.
3. **B9 complete — outbound publication is off at all four layers, each
   verified.** Layer 3, the Terraform `precondition`, was the one still
   outstanding; all six unsafe configurations are now shown to be rejected
   plan-only with a non-zero exit (§5).
4. **Destructive-test isolation, enforced in code** (commit `096d0ba`). The fix
   for the 2026-11-09 truncation: `DestructiveTestIsolation` refuses any target
   that does not prove itself disposable, on four independent grounds, failing
   closed on each. It lives inside the only function that deletes rows, so there
   is no path to the DELETEs that skips it. 17 tests, 57 assertions, including
   the one that matters — pointed at the real `vrc-staging-main` with full
   consent, the suite refuses and staging's row counts do not move. Full detail
   at the top of this file.
5. **Staging test litter removed** (no commit — a database operation). The two
   leftover `channel='race'` holds and their property were deleted by explicit
   primary key after confirming every dependent row count was zero. Staging now
   reports exactly the two documented demo intervals. See §4.
6. **Smoke test B6 — concurrency over the Data API** (commit `7e9a99a`). Two
   `RentalStore`s on independent transports race to claim the same nights on one
   property; the `no_overlapping_live_holds` exclusion constraint is the only
   arbiter. Exactly one is accepted, the loser's refusal must name that
   constraint, and exactly one live row survives. A paired non-overlapping case
   (checkout-day adjacency, 06-01→05 then 06-05→09) is the control — without it
   a constraint that refused *every* hold would also report "one winner".
   Verified by falsification: dropping the constraint on a local cluster fails
   all four assertions, including `expected 1, got 2` live holds — a real double
   booking. Passed against local PostgreSQL 17.10 **and** live Aurora over the
   RDS Data API (10/10, 29 assertions in the group). Parity digest unchanged.
7. **Daterange Data API fix** (found by B5 against real Aurora) — `SELECT *` on
   tables with generated `daterange` columns 400s over the RDS Data API;
   replaced with explicit column lists. Lambdas redeployed.
8. **GUI keychain fix via helper delegation** — the SwiftUI app could not read
   the AWS credential (macOS pins each keychain item to the creating binary's
   code hash; the GUI and `vrc` are different code objects). The GUI now calls
   the bundled `vrc cloud check --json` helper, which returns only sanitized
   JSON. See [docs/KEYCHAIN.md](docs/KEYCHAIN.md).
9. **Cloud integration in the Mac app** — Cloud pane, AWS status-bar indicator,
   Refresh from AWS, build-provenance tab.
10. **Staging deployed and validated** (A1–A5, B1–B5).
11. **Minimal AWS backend** — DataStore over the RDS Data API, 5 Lambda handlers,
   restricted DB role, Postgres schema generated from the SQLite migrator.

---

## 2. Architecture (one paragraph per piece)

- **SwiftUI Mac app** (`Sources/VacationRentalCalendar`) — the only UI. Reads a
  local SQLite database for the unified calendar, review queue, availability
  decisions, and feeds. For cloud status it shells out to the bundled `vrc`
  helper; it never talks to AWS directly.
- **VRCCore** (`Sources/VRCCore`) — all business logic, no UI. Shared verbatim
  by the app, the CLI, and the Lambdas. The cancellation-block protection, the
  export allow-list, the classifier, and both database backends live here.
- **`vrc` CLI / helper** (`Sources/vrc`) — headless control surface and the
  app's authorized cloud helper. Reads credentials from the Keychain, signs
  SigV4 requests, returns sanitized JSON.
- **AWS Lambda** (`Sources/VRCLambda` + `Sources/vrc-lambda-*`) — five handlers
  (fetch, process, publish, api, sweeper), `provided.al2023`, arm64, Swift
  runtime bundled. They run the same VRCCore.
- **API Gateway** — HTTP API with `AWS_IAM` authorization; requests are
  SigV4-signed. No Cognito.
- **Aurora PostgreSQL** — Serverless v2, 16.15, min 0 ACU, 300s auto-pause,
  reached over the **RDS Data API** (SQL over HTTPS) so the Lambdas stay out of
  a VPC and need no NAT gateway.
- **Secrets Manager** — DB master and runtime credentials, source feed URLs,
  outbound feed tokens. Nothing secret is in SQLite, Git, logs, or Terraform
  state.

---

## 3. Git, PR, and installed version

| | Value |
|---|---|
| Branch | `backend/aws-backend` |
| HEAD | `096d0ba` (Make it impossible to truncate a database that is not disposable) |
| PR | **#10 OPEN** (not draft): "Backend implementation: DataStore, five handlers, restricted role" — **do not merge without review** |
| Installed Mac app | commit `217f668`, build 1, clean tree, built 2026-11-09 17:05Z |

**Why the installed app is five commits behind HEAD**, and why that is fine:

| Commit | Touches | Affects the Mac app? |
|---|---|---|
| `096d0ba` destructive-test isolation | a new `VRCCore` type used only by the test suite, plus tests | no — nothing in the app or the Lambdas calls it |
| `76425c9` handoff rewrite | `HANDOFF.md` only | no |
| `7e9a99a` B6 concurrency tests | `Sources/VRCTestSuite` only | no |
| `f672cf9` handoff rewrite | `HANDOFF.md` only | no |
| `08c3bc1` daterange Data API fix | the Lambda/Data-API path and tests | no — the app uses local SQLite, where `SELECT *` is fine |

The **deployed Lambdas** already carry the `08c3bc1` fix (redeployed). No shipped
app behaviour has changed since `217f668`. Rebuilding would change the helper's
code hash and orphan its Keychain credential (see §8), so the installed build was
deliberately left where it is. To bring it to HEAD later, rebuild and then run the
migration in §8.

The installed build's provenance is readable in the app: **Settings → This
build**, or from the bundle:
```bash
/usr/libexec/PlistBuddy -c "Print :VRCGitCommit" /Applications/VacationRentalCalendar.app/Contents/Info.plist
```

---

## 4. AWS staging resources (account …1110, us-east-1)

| Resource | Identifier |
|---|---|
| Aurora cluster | `vrc-staging-main` (Aurora PostgreSQL 16.15, Serverless v2, min 0 ACU, 300s auto-pause) |
| API endpoint | `https://a7fubx2osf.execute-api.us-east-1.amazonaws.com` |
| Lambdas | `vrc-staging-{fetch,process,publish,api,sweeper}` |
| Buckets | `vrc-staging-{feeds,raw,snapshots}-f79de5f0` |
| Secrets | `vrc-staging/{database/master, database/runtime, sources/feed-urls, outbound/feed-tokens}` |
| IAM client user | `vrc-staging-mac-client` (one active access key; id not recorded here) |
| EventBridge schedules | `vrc-staging-hold-sweeper` **DISABLED**, `vrc-staging-import` **DISABLED** |

**Safety invariants — all re-verified against the live account 2026-11-09:**

| Invariant | Verified how | State |
|---|---|---|
| Both EventBridge schedules disabled | `aws scheduler get-schedule` | `DISABLED`, `DISABLED` |
| Outbound off, layer 1 (code) | `OutboundSyncGate.isEnabled` in `Sources/VRCCore/Logic/ExportPolicy.swift:133` | `false` |
| Outbound off, layer 2 (function env) | `aws lambda get-function-configuration` on api and publish | `false`, `false` |
| Outbound off, layer 3 (Terraform precondition) | **not re-verified this round** | assumed unchanged |
| Outbound off, layer 4 (database) | `SELECT value FROM app_settings WHERE key='outbound_sync_enabled'` | `false` |
| Nothing published | `feed_publications` = 0, `published_feed_entries` = 0 | nothing published anywhere |
| Production untouched | no call made to them | PriyankaHomes tables, both hosted zones, production DynamoDB untouched |

`app_settings.feed_publication_scope` is `approved_manual_blocks_only`.

### Staging database contents, verified 2026-11-09 after clean-up

| Table | Rows | Note |
|---|---|---|
| `properties` | 1 | `Staging Demo — 39 G Street`, id 112 |
| `reservations` | 1 | id 67, `direct`, `demo-res-1`, confirmed, 2027-07-01→07-08 |
| `holds` | 1 | id 71, `direct`, `demo-hold-1`, 2027-09-01→09-04, expires 2099 |
| `availability_audit` | 41 | append-only and untouched; the runtime role cannot delete from it, by design |
| `events`, `classifications`, `availability_decisions`, `platform_listings`, `sync_runs`, `feed_publications`, `published_feed_entries`, `idempotency_keys` | 0 | emptied by the B6 run; the seed script restores none of these |

`vrc cloud check` reports exactly these two intervals, `health: healthy`.

**The test litter is gone.** The two `channel='race'` holds (ids 69 and 70) and
their property (`No race — 39 G Street`, id 111) were deleted by **explicit
primary key**, not by predicate, after confirming each row individually: both
holds had `reservation_id IS NULL`, and property 111 had 0 reservations, 0
decisions, 0 conflicts and 0 listings, so nothing depended on either. The demo
rows and all 41 audit rows were verified present afterwards.

Staging's 2 synthetic approved decisions and its Airbnb `platform_listings` row
were destroyed by the B6 run and are **not** restored by the seed script. Nothing
depends on them; re-create them only if a future test needs them. This is why
`approvedDecisions` reads 0 where earlier notes said 2.

### Connection verification (read-only)

```bash
# The exact call the GUI makes; sanitized JSON, no secrets.
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc cloud check --json
# Expected: ok:true, and the two demo intervals
#   (2027-07-01→07-08 reservation, 2027-09-01→09-04 hold).
# Verified 2026-11-09 after clean-up: exactly these two, health healthy.
# approvedDecisions reads 0, not 2 — see the note below.
```

The cluster auto-pauses after 5 minutes idle; the first call after a pause can
take 15–30s while Aurora resumes, and may briefly report "Could not reach." Retry.

The demo intervals are **synthetic staging data** (one confirmed reservation,
one active hold) created by `Scripts/seed-staging-demo.sql`. They were destroyed
by the B6 run on 2026-11-09 and **restored** the same day by re-applying that
script via the master secret — 5 statements, 3 inserts, both of its DELETEs
matching 0 rows on the cleared cluster:
```bash
# apply Scripts/seed-staging-demo.sql via the master secret (see §9 helper)
```
The script is idempotent on the property name and scoped to `channel = 'direct'`,
so it is safe to re-run and cannot touch anything else.

---

## 5. Test results and parity

```bash
swift run vrc-test                      # 369 tests / 1223 assertions — all pass (macOS)
swift run vrc-parity --digest           # b3398471…c604f5
./Scripts/build-lambda.sh               # also runs the suite inside Linux; parity must match
```
- macOS: **all 369 pass**. Two assertion counts are both correct: **1223** for a
  plain `swift run vrc-test`, where the PostgreSQL group skips, and **1242** with
  that group live (see the gate below).
- Linux: **all 369 pass**, 1223 assertions, in `swift:6.3.3-amazonlinux2023` —
  verified at commit `02f6df6`. The container has no PostgreSQL, so the group
  skips and the count matches the macOS no-Postgres figure exactly.
- Parity digest **identical on macOS and Linux**, confirmed in the same run.
- Parity digest **unchanged**: `b3398471b1ee56f477d9a1244b16449e8827df1616aa5fca365ef3db96c604f5`.
  B6 is test-only, so parity could not move; it was re-checked anyway.

### Staging smoke tests (docs/STAGING-DEPLOYMENT.md §6)

| Test | Status |
|---|---|
| A1–A5 (bring-up, migrate, deploy) | ✅ done |
| B1 unsigned event → 401, Aurora stays paused | ✅ |
| B2 unsigned HTTPS → 403 at the gateway | ✅ |
| B3 SigV4-signed from the Mac → 200 | ✅ |
| B4 sweeper by hand → holdsReleased:0, no reservation touched | ✅ (prior run) |
| **B5 Data API transactions: Swift suite vs cluster** | ✅ **8/8 against live Aurora** |
| **B6 concurrency: overlapping holds, one winner** | ✅ **passed on local PostgreSQL 17.10 and live Aurora** (group now 10/10, 29 assertions) |
| **B7 `POST /decisions` twice, one idempotency key** | ✅ **passed** against the deployed artifact on a disposable cluster |
| **B8 kill mid-write → client reports UNKNOWN** | ✅ **passed**, including reconciliation without duplication |
| **B9 publication still impossible** | ✅ **all four layers verified** — see the §4 table |
| Phase C PITR into a temporary cluster, then delete | 🟨 **C1 and C4 pass, C2/C3 blocked, C5 done** — see §12 |

### B9 layer 3, verified plan-only 2026-11-09

`terraform plan` with each unsafe value, against the saved staging configuration.
Nothing was applied.

| Variable forced | Exit | Rejected by |
|---|---|---|
| `outbound_enabled=true` | **1** | `precondition` — "REFUSED: outbound_enabled must be false in staging" |
| `create_dns=true` | **1** | `precondition` |
| `create_cdn=true` | **1** | `precondition` |
| `allow_priyankahomes_read=true` | **1** | `precondition` |
| `region=eu-west-1` | **1** | `precondition` |
| `seconds_until_auto_pause=60` | **1** | **variable validation**, not the precondition — a different layer, equally non-zero |
| *control:* the real `staging.tfvars` | **0** | nothing — "No changes" |

A plan file **is** written on the error path, which looks alarming and is not:
`terraform show -json` reports `errored: true, applyable: false, complete: false`
on it, versus `errored: false, complete: true` for the control. Terraform writes
an errored plan for inspection and `apply` refuses it.

### How B7 and B8 were finally run

Both needed the **deployed API** against a **disposable** database. Three routes
existed; two are permanently closed and the third is what was used.

1. **Point the existing staging API at the disposable cluster** — forbidden, and
   it would not work anyway: `vrc-staging-lambda-api`'s policy scopes
   `rds-data:*` to `vrc-staging-main` alone, as does every other `vrc-*` role.
2. **Deploy a temporary API Lambda** — a Lambda needs an execution role, and
   creating an IAM role was refused by the session's permission policy.
3. **Run the deployed artifact locally** ✅ — the arm64 `bootstrap` from
   `.build/lambda/api.zip`, the same package built and parity-checked this
   round, under the AWS Lambda Runtime Interface Emulator that the official
   `provided:al2023` image ships at `/usr/local/bin/aws-lambda-rie`. Same
   binary, same `ApiHandler`, same `DecisionRoutes`, same idempotency
   transaction, same Data API transport — hosted locally instead of in AWS.

**What route 3 does not cover, stated plainly:** API Gateway's `AWS_IAM`
authorization layer (B2 and B3 cover that against the real gateway) and AWS's
own Lambda hosting. The IAM principal is supplied in the synthetic event, as the
gateway would supply it. So B7/B8 prove the handler's behaviour, not the
gateway's.

Two practical notes for re-running:
- `idempotency_keys` cannot be deleted by the runtime role, so each run needs a
  fresh `publicationUID` **and fresh nights**. `DecisionRoutes` correctly refuses
  a block overlapping an existing approved decision for the same destination, so
  reusing fixed dates makes the second run `409` against its own predecessor —
  that is the route working, not failing. The harness derives its night windows
  from the clock for this reason.
- A successful first submission answers **201 Created**, not 200.

**B7 and B8 were not begun.** Both need writes to the deployed staging API —
B7 posts a decision twice, B8 interrupts a real write mid-flight — and the
session that completed B6 was not permitted to make them. Note for whoever picks
B7 up: `idempotency_keys` is deliberately not DELETE-able by the runtime role, so
every run leaves its key behind permanently. Use a **fresh `publicationUID` per
run** (the key is derived from the decision) or the second run will collide with
the first run's key and prove nothing.

Much of what B7 and B8 assert is already covered at unit level against fakes —
see `DecisionRouteTests` ("the same key twice records one decision") and
`CloudSyncClientTests` ("a dropped connection on a write is uncertain", "a
persistently uncertain write reports NOT applied"). What B7/B8 add is the same
properties **against the deployed system**. `vrc-verify-sigv4 --mac-api <url>`
already exercises part of B8's shape end to end.

**To run B5/B6 against a cluster** (credentials read from the AWS CLI config into
the process env, never printed). This truncates the target, so the guard will
refuse unless the cluster is disposable, named disposable, consented to, and
marked — `vrc-staging-main` is refused outright and cannot be argued with. The
ARN below is therefore a placeholder for a throwaway cluster, not staging:
```bash
VRC_CLUSTER_ARN="arn:aws:rds:us-east-1:589744711110:cluster:vrc-staging-main" \
VRC_DB_SECRET_ARN="$(aws secretsmanager describe-secret --secret-id vrc-staging/database/runtime --query ARN --output text)" \
VRC_DB_NAME=vrc VRC_ACTOR=owner AWS_REGION=us-east-1 \
AWS_ACCESS_KEY_ID="$(aws configure get aws_access_key_id)" \
AWS_SECRET_ACCESS_KEY="$(aws configure get aws_secret_access_key)" \
swift run vrc-test "PostgreSQL integration"
```
The suite clears far more than it restores: `reservations`, `holds`,
`properties`, `events`, `classifications`, `availability_decisions`,
`platform_listings` and `sync_runs` all go, while
`Scripts/seed-staging-demo.sql` puts back only the property, one reservation and
one hold. On a disposable cluster that does not matter, which is the point — and
the guard now makes a disposable cluster the only thing it can be.

---

## 6. Known bugs fixed, and outstanding limitations

**Fixed this round (all committed):**
- **GUI could not read the AWS credential.** Root cause: macOS login-keychain
  items are readable only by the exact code object that created them; the GUI
  and `vrc` are different binaries. Fixed by helper delegation. docs/KEYCHAIN.md.
- **`SELECT *` 400s over the RDS Data API** when a table has a generated
  `daterange` column ("unsupported data type DATERANGE"). The local psql
  stand-in hid it. Fixed with explicit column lists in `EventRepository` and
  `AvailabilityRepository`. This was a live bug — the API Lambda's `status()`
  broke once `events` had rows.
- **Boolean decoding over the Data API** comes back as 1/0, not `t`/`f` — the
  integration test now accepts both.
- **`availability_audit` accumulates** on a shared cluster (append-only to the
  runtime role); the audit comparison is now scoped to the current run.

**Outstanding limitations / not done:**
- **B7, B8 and Phase C not started; B9 is 3 of 4 layers.** B6 is done (§5).
- ~~The integration suite truncates whatever database it is pointed at, and has
  no isolation guard.~~ **Fixed in `096d0ba`** — see the top of this file.
- ~~Two litter holds remain in staging.~~ **Removed**, verified row by row (§4).
- The guard's deny-list is a substring list in Swift
  (`DestructiveTestIsolation.protectedFragments`). If a future cluster is named
  something protected-but-unlisted, add it there. The allow-list requirement
  means an unlisted name is refused by default, so the failure mode of
  forgetting is a refusal, not a deletion.
- No real feeds import yet (the feed-diff experiment and the schedule decision
  are pending — see §10).
- The `vrc_runtime` role cannot `DELETE` from `events`/`availability_audit` (by
  design). The integration suite's own cleanup therefore can't clear those;
  clean with the **master** secret when a true blank slate is needed.
- A rebuilt `vrc` helper loses Keychain access and needs the §8 migration once.
- The "1 of 350 failed" line seen during one `build-lambda` run was **not
  reproducible** — a clean container run passes all 350. Likely a timing flake;
  worth a second look if it recurs.

---

## 7. Build, test, install, verify — exact commands

```bash
# Tests
swift run vrc-test                         # all
swift run vrc-test "Cloud"                 # one group
swift run vrc-parity --digest              # parity digest

# Build + sign + install the Mac app (preserves local DB and Keychain)
./Scripts/build-app.sh --install
# After an install that rebuilt the vrc helper, re-own its credential (see §8).

# Verify the installed build
/usr/libexec/PlistBuddy -c "Print :VRCGitCommit" /Applications/VacationRentalCalendar.app/Contents/Info.plist
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc status        # local data
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc cloud check   # live AWS
/Applications/VacationRentalCalendar.app/Contents/MacOS/VacationRentalCalendar --self-check-cloud  # GUI path, headless

# Rebuild + redeploy the Lambdas (Docker required; parity gated)
./Scripts/build-lambda.sh --deploy

# Local PostgreSQL integration tests — the SAFE way to run the suite.
# Disposable cluster, no AWS, nothing shared. Prefer this always.
#
# Two details the old recipe got wrong, both found on 2026-11-09:
#   * the role MUST be vrctest — PsqlTransport hardcodes `-U vrctest`
#   * a long data-dir path overflows the 103-byte UNIX socket limit, so
#     disable the socket and let the tests connect over TCP
PGDIR=/tmp/pg                      # any short path
export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"
initdb -D "$PGDIR" -U vrctest
pg_ctl -D "$PGDIR" -o "-p 54407 -c unix_socket_directories=" -l "$PGDIR/pg.log" start
createdb -h 127.0.0.1 -p 54407 -U vrctest vrc
psql -h 127.0.0.1 -p 54407 -U vrctest -d vrc -f Migrations/postgres/010_repository_schema.sql
psql -h 127.0.0.1 -p 54407 -U vrctest -d vrc -f Migrations/postgres/011_safety.sql

# Mark it disposable, or the guard refuses — this is the sandbox saying
# "my rows may be deleted", and it is required on every target.
psql -h 127.0.0.1 -p 54407 -U vrctest -d vrc \
  -c "INSERT INTO app_settings (key, value) VALUES ('disposable_database','true') \
      ON CONFLICT (key) DO UPDATE SET value='true';"

VRC_DESTRUCTIVE_TESTS=i-understand-this-truncates \
VRC_PG_PORT=54407 swift run vrc-test "PostgreSQL integration"
pg_ctl -D "$PGDIR" stop            # and throw the cluster away
```

Forget either the variable or the marker and the group **fails loudly** rather
than skipping — the refusal names exactly what is missing and what to do. That
is deliberate: a silent skip would let someone believe these tests had run.

---

## 8. Keychain credential recovery and migration

**The rule:** a macOS login-keychain item is readable only by the binary code
hash that created it. Rebuilding the `vrc` helper changes that hash, so the
helper loses access to the AWS credential it stored, and the Cloud pane shows
"cannot read its AWS credential." This is macOS behaviour, not a bug.

**Recovery — preserves the IAM key, no rotation:**
```bash
./Scripts/migrate-cloud-credential.sh
```
It reads the existing secret with your approval (a macOS "Always Allow" prompt —
there may be two), hands it to the new helper in memory (never to disk or a
log), and calls no AWS API. `build-app.sh --install` runs it automatically after
an install that needs it (skip with `VRC_SKIP_KEYCHAIN_MIGRATION=1`).

**Important for a non-interactive/automation session:** `security find-generic-password -w`
blocks on a GUI prompt that an automated shell can't click — run the migration
in a real Terminal, or let the owner click. Don't loop it; each call re-prompts.

**Feed URLs** (Airbnb/Vrbo/Booking.com) follow the same rule. If they read as
unreadable after a rebuild, re-enter with `vrc set-url --listing <id>` (the URL
is read with echo off and never printed). Current references (names only):
`airbnb-1759472334611502986-v3`, `vrbo-5550554-v3`, `booking-17482435`.

---

## 9. Preserved application data (re-verified 2026-11-09, after the B6 round)

**This is the local SQLite data, and it is intact.** It is a different database
from the staging cluster, was never a target of the integration suite, and the
truncation described at the top of this file did not touch it. Re-read through
`sqlite3 .backup` after all of this round's work:

| Item | Value |
|---|---|
| Events | **7** |
| Classifications | **7** |
| Vrbo decisions | **2 rows, both `cancelled` as of 2026-11-10** — see §14. Previously approved-and-unpublished |
| — Decision 1 | Vrbo block **2026-12-10 → 2026-12-17**, UID `vrc-812d19781e654081a164c12d307b07b4` |
| — Decision 2 | Vrbo block **2026-12-19 → 2026-12-20**, UID `vrc-a5a1dbf505da412e87a71d6a78481547` |
| December 17–18 | **no Vrbo block decision** — those nights stay sellable (verified: 0 blocks cover them) |
| Published decisions | **0** — nothing published anywhere |
| Credential references | preserved in Keychain (names in §8) |
| AWS IAM credentials | preserved; **not rotated** |

All four counts, both publication UIDs and the December 17–18 exclusion were
confirmed again at commit `7e9a99a` — `0` decisions cover either night.

- **Local SQLite:** `~/Library/Application Support/VacationRentalCalendar/VacationRentalCalendar.sqlite`
- **Backup taken this session:** a `.backup` copy is in the session scratchpad
  (`handoff-db-backup-*.sqlite`). For a durable backup, re-run:
  ```bash
  sqlite3 "$HOME/Library/Application Support/VacationRentalCalendar/VacationRentalCalendar.sqlite" ".backup '<dest>.sqlite'"
  ```
  Always use `.backup`/`VACUUM INTO`, never a plain file copy (misses the WAL).

Helper to run SQL on the staging cluster (master role; never against production):
```bash
ARN="arn:aws:rds:us-east-1:589744711110:cluster:vrc-staging-main"
MASTER="$(aws secretsmanager describe-secret --secret-id vrc-staging/database/master --query ARN --output text)"
aws rds-data execute-statement --resource-arn "$ARN" --secret-arn "$MASTER" --database vrc --sql "SELECT 1"
```

---

## 10. AWS operating costs

Staging, idle-dominant (from the validated plan in docs/STAGING-DEPLOYMENT.md §5.2):
- **≈ $2.12 / month** running, **≈ $1.88 / month** idle.
- Aurora Serverless v2 at min 0 ACU with 300s auto-pause is the main driver; it
  bills near zero while paused. The Data API avoids a NAT gateway (~$32/mo
  saved). Buckets, Lambda, and API Gateway are within or near free tier at this
  volume.
- The hosted outbound feed, when/if enabled, is a separate ~$10/year (a domain)
  — see docs/HOSTING-PROPOSAL.md. Not deployed.

Teardown (reversible, staging only): `./Scripts/staging-teardown.sh --destroy`.

---

## 11. Remaining work before production readiness

Ordered. **Each of these is a new task.** Staging validation is complete; the
next milestone is real read-only Airbnb and Vrbo imports (item 2).

1. **Finish staging validation.** Done: ~~B6~~, ~~isolation guard~~, ~~staging
   litter~~, ~~B9 (all four layers)~~, ~~Linux suite~~, ~~Phase C C1/C4/C5~~.

   **Nothing is left. A1–A5, B1–B9 and Phase C C1–C5 all pass** (§5, §12). The
   validation programme that this project has been working through since the
   backend was built is finished.

   The only follow-up it produced is a question rather than a task: the
   Linux + static-credentials asymmetry in §12, which has a workaround, does not
   affect production, and has no explanation yet.
2. **Prepare real imports (read-only) — BLOCKED ON THE OWNER, see §13.** The
   feed URLs were checked on 2026-11-10 and **none of the three feeds can be
   fetched**: Airbnb and Vrbo need their URLs re-entered (the cdhash trap, which
   macOS will not prompt about), and Booking.com needs a brand-new export URL
   because the platform invalidated the old token. Two `vrc set-url` commands in
   a real Terminal unblock Airbnb and Vrbo. Only then: run the live feed-diff to
   measure the change-detection hit rate (decides the ~$5.76 vs ~$19.95/mo
   import cadence) and store the source URLs in `vrc-staging/sources/feed-urls`,
   which currently holds no value at all.
3. **Reconcile** imported observations with the 7 local events and 7
   classifications, preserving the distinction between confirmed booking,
   cancellation penalty, owner block, and unknown — **never** auto-classifying
   an ambiguous event as a confirmed booking.
4. **Enable schedules (Phase D), owner-approved:** hold sweeper first, observe;
   then the import schedule, observe 48h. Nothing published.
5. **Only later, and only as a reviewed code change:** outbound publication
   (`OutboundSyncGate.isEnabled`) — never a UI toggle.
6. Bring the installed Mac app to HEAD (rebuild + §8 migration) when convenient.

**Do not** enable any schedule, enable outbound, publish any decision, change
GitHub visibility (it is intentionally public — secrets stay private), or touch
PriyankaHomes / production DynamoDB / Google Calendar / DNS, without explicit
owner approval.

---

## 12. Phase C and B7/B8 — complete, 2026-11-10

Run under explicit owner authorization for a temporary, isolated recovery
cluster. **All temporary resources were deleted and the cleanup verified by
inventory; nothing from the drill remains.**

### Phase C: 27 checks, 0 failures

| # | Test | Result |
|---|---|---|
| C1 | restore → a second, independent cluster | ✅ `vrc-staging-pitr2`, own endpoint, own writer, no shared instance |
| C2 | migrations `10, 11` on the restored cluster | ✅ `schema_migrations` reports both |
| C3 | the safety machinery present **and refusing** | ✅ 19 base tables, 6 generated columns, 2 triggers, `no_double_booking` + `no_overlapping_live_holds`, the allow-list function correct on all six `BlockKind`s, and an overlapping hold genuinely refused leaving no row behind |
| C4 | the source cluster untouched | ✅ identical counts and settings before and after |
| C5 | delete the temporary cluster | ✅ writer and cluster both deleted, verified by inventory |

**Recovery consistency** was checked table by table against the live source —
`properties`, `reservations`, `holds`, `availability_audit`, `events`,
`classifications`, `availability_decisions` all matched — and both synthetic
intervals survived byte-for-byte: `demo-res-1` confirmed `[2027-07-01,2027-07-08)`
and `demo-hold-1` `[2027-09-01,2027-09-04)`.

**The fix that made C2/C3 possible** was the one-line correction from the
previous round: `aws rds enable-http-endpoint --resource-arn <cluster ARN>`,
which returned `HttpEndpointEnabled: true` immediately and made the restored
cluster queryable. `modify-db-cluster --enable-http-endpoint` is Serverless **v1**
only and silently does nothing on a v2 or provisioned cluster. Confirmed in
practice this round, not just from documentation.

### B7 and B8: 14 checks, 0 failures

Against the disposable cluster, through the deployed artifact under the Runtime
Interface Emulator (see §5 for what that does and does not cover).

**B7 — the same decision twice under one idempotency key.** First submission
`201 Created`, echoing the submitted `publicationUID`, with `published=false`.
Second submission `alreadyApplied=true` with the same UID. The database holds
**exactly one** decision and **exactly one** idempotency key.

**B8 — an interrupted write.** The function was killed 0.4s into the write; the
caller got no answer at all (`curl rc=52`, empty body) — a genuinely uncertain
outcome, which is the state that must never become a duplicate. No decision
existed at that moment. Reconciliation then retried under the same key the way
`CloudSyncClient` does, and this is the part worth reading: it received `503`
four times — the service correctly reporting *uncertain* rather than claiming
"not applied", which would have invited a resubmit — and then `201`. The final
state is **exactly one** decision, with nothing else covering those nights, and
`GET /decisions/{uid}` answers `200` with an explicit `found=true`.

### An asymmetry worth following up

The deployed artifact **could not authenticate to the Data API from inside the
Linux container using static long-term credentials.** Every call returned
HTTP 403, *"The security token included in the request is invalid"* — AWS saying
it does not recognise the access key. The same keys work from macOS through the
same `URLSessionDataAPITransport` (that is how B5/B6 ran), and the values were
confirmed to arrive in the container intact (`AKIA…`, 20 and 40 characters,
correct region and ARNs), with no clock skew and no injected `AWS_SESSION_TOKEN`.
Supplying **temporary credentials with a session token** — `aws sts
get-session-token` — made it work immediately.

So the untested combination was **Linux + static keys + no session token**.
Deployed Lambda always has a session token, so production is unaffected and
nothing here is evidence of a production fault. But this is a symptom with a
workaround, **not a diagnosis**: the mechanism is unexplained, and the signer's
behaviour when `sessionToken` is nil on corelibs deserves a look. It is the same
class of macOS/Linux divergence CLAUDE.md already records twice.

### Resources created, cost, and cleanup

| Resource | Identifier | State |
|---|---|---|
| Cluster | `vrc-staging-pitr2` | **deleted** |
| Instance | `vrc-staging-pitr2-writer`, `db.serverless` | **deleted** |
| IAM / networking / DNS | none created — the existing `vrc-staging-db` subnet group and `sg-060063071c2073cdd` were reused | n/a |
| Local Docker containers | `vrc-pitr-api-local`, `probe-api` | removed |

Cost at rates read from the **AWS Pricing API**: Serverless v2 **$0.12 per
ACU-hour**, storage **$0.10 per GB-month**, I/O **$0.20 per million**. The
cluster lived roughly 35 minutes with one low-ACU writer and 1 GB of storage, so
the incremental charge is **well under the $0.50 budget — on the order of
$0.05–$0.15**. Computed from verified rates and measured lifetimes; Cost
Explorer lags about a day and had published nothing for the period.

---

## 13. Real feeds — Airbnb and Vrbo are LIVE. Only Booking.com is outstanding.

**Updated 2026-11-10 01:3x.** An earlier revision of this section said all three
feeds were blocked. That is no longer true: the owner re-entered the Airbnb and
Vrbo URLs through the app's Feeds pane, and both now import real observations.
The Booking.com half of the section still stands.

The real-import milestone cannot start until the owner acts. Nothing here is a
code problem, and nothing is fixable from an automated session.

### Where each feed stands

| Listing | State | Real observations |
|---|---|---|
| **Airbnb** — 39 G Street | ✅ `Connected` | **4 events, 4 in feed** |
| **Vrbo** — 39 G Street (5550554) | ✅ `Connected` | **3 events, 3 in feed** |
| **Booking.com** — Southie Beach House (17482435) | 🟥 `Disconnected by the platform` | 0 — needs a **brand-new export URL** |

So the 7 active local events **are real imported observations**, not fixtures:
4 from Airbnb and 3 from Vrbo, with feed counts matching exactly.

### The one thing to know about entering feed URLs

**Enter them in the app, under Feeds — not through the `vrc` CLI.** After the
re-entry, `vrc keychain` *still* reports all three feed items unreadable
(`OSStatus -25293`), while Airbnb and Vrbo import perfectly. That is not a
contradiction: the GUI created the new items, and the GUI is a **different code
object** from the `vrc` helper, so each can only read what it created. The
Keychain references bumped `airbnb-…-v3` → `-v4` and `vrbo-…-v3` → `-v4`, which
is `set-url` writing a fresh entry and leaving the old one untouched, exactly as
designed.

This is the same split documented in [docs/KEYCHAIN.md](docs/KEYCHAIN.md) for
the AWS credential, just in the other direction: there, the GUI had to delegate
to `vrc`; here, `vrc` cannot see what the GUI owns.

### The cdhash trap, for reference — this is what Airbnb and Vrbo were in

`vrc keychain` on the installed build (`217f668`) reported:

```
FAIL Airbnb — 39 G Street [airbnb-1759472334611502986-v3] — refused (OSStatus -25293)
FAIL Booking.com — … [booking-17482435]                   — refused (OSStatus -25293)
FAIL Vrbo — 39 G Street (5550554) [vrbo-5550554-v3]       — refused (OSStatus -25293)
ok   AWS access key id   — readable
ok   AWS secret access key — readable
```

The AWS pair is readable because it was re-owned by this build during the
keychain migration (§8). The three feed items never were, so their access list
still names an older, ad-hoc-signed build by its code hash. **macOS does not
prompt in this situation — it refuses silently.** There is no dialog to approve
and no migration to run; re-entry is the only fix, and the app says so itself.

**Booking.com is a different and worse problem.** It is not a Keychain issue:
the platform returned **400 Invalid Token** because the calendar connection the
export URL belonged to was deleted. Re-entering the old URL would achieve
nothing. It is marked **needing reconnection** and requires generating a fresh
export URL in the Booking.com extranet first. The staging API already carries
`VRC_DISCONNECTED_SOURCES=booking_com`, so the service agrees.

### A trap in the diagnostics themselves

`vrc doctor` prints `ok   feed URL stored for Airbnb …` for all three. That is
**presence of the Keychain reference, not readability**, and reading it as
"feeds are fine" is a mistake waiting to happen. `vrc keychain` is the command
that answers whether this build can actually read them; `vrc connection`
explains why not and what to do.

### There is no second copy of these URLs

`vrc-staging/sources/feed-urls` in Secrets Manager answers
`ResourceNotFoundException` — the secret exists but holds no value. So AWS is not
an alternative source, and a cloud-side import is blocked for the same reason.

### How Airbnb and Vrbo were unblocked — and how Booking.com will be

Through the app's **Feeds** pane (the route that worked). The CLI equivalent,
for reference, must run in a **real Terminal** — `set-url` refuses to save when
stdin is not a TTY, demands `https`/`webcal`, redacts the URL, and fetches and
parses it before saving, leaving any existing entry untouched on failure
(`--dry-run` verifies without saving):

```bash
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc set-url --listing 3   # Booking.com
```

But prefer the Feeds pane, for the code-object reason above.

`set-url` reads the URL from stdin with echo cleared, verifies it before saving,
and never puts it in argv, shell history, `ps`, or a log. It writes a fresh
Keychain entry owned by the current build and leaves the old one untouched —
nothing is deleted and no credential is regenerated. Then
`vrc keychain` should report all three readable, and `vrc import` becomes possible.

**Never pass a feed URL as a command-line argument.** It is a bearer credential.

### Local data, as it stands with Airbnb and Vrbo imported

| | |
|---|---|
| Events | **7 active** — Airbnb 4, Vrbo 3, Booking.com 0 |
| Classifications | Maintenance block 2 events (834 nights), Cancellation block 5 events (43 nights) |
| Confirmed reservations | **none** — worth knowing before reconciliation, since none of the 7 is a booking |
| Needs review | 0 |
| Double bookings | 0 · other overlaps 4 |
| Vrbo decisions | 2 rows, both now **`cancelled`**, never published — see §14 |
| December 17–18 2026 | **free of any Vrbo block decision** |

### The Mac display is already built

Audited against the six distinctions wanted for real observations; all are
already present, so no UI work is pending on this milestone:

| Wanted | Where |
|---|---|
| Airbnb vs Vrbo observations | `Theme.swift` — per-platform colour and SF Symbol per `RentalPlatform` |
| Confirmed reservation vs unknown block | `Theme.swift` colours every `BlockKind` separately; `EventDetailPanel` treats `confirmedReservation` specially |
| Local vs AWS records | local calendar panes vs the Cloud pane, which labels each interval `source · basis` |
| Conflicts requiring review | `ConflictsView`, `ReviewView`, and a review queue in `vrc status` |
| Last successful refresh | Cloud pane renders `status.lastSuccessfulImport` (currently `never`) |
| Duplicate-free refresh | covered by `RequiredScenarioTests` — "re-importing a feed creates no duplicates" |

---

## 14. Why the two Vrbo decisions read `cancelled` — investigated 2026-11-10

Both decisions were **approved and unpublished** for a day, then both became
`cancelled` within the same second. Nothing was deleted: both rows survive, both
publication UIDs are intact, and the full audit trail explains it.

### When

| Decision | Created (draft) | Approved | Cancelled |
|---|---|---|---|
| 1 — Vrbo block Dec 10→17 2026 (7 nights) | 2026-11-09 03:33:38 | 2026-11-09 03:37:09 | **2026-11-10 01:09:14** |
| 2 — Vrbo block Dec 19→20 2026 (1 night) | 2026-11-09 03:33:38 | 2026-11-09 03:37:09 | **2026-11-10 01:09:14** |

The two audit histories are **identical in shape and to the second** — created
together, advanced `draft → validated → awaiting_approval → approved` together,
cancelled together, both with the detail `Pending changes cleared.` and actor
`owner`. That is one action affecting both, not two separate decisions.

### How

A single click on the button labelled **"Cancel all"**, in the availability
editor's *"Waiting for you"* section
([AvailabilityEditor.swift:177](Sources/VacationRentalCalendar/Availability/AvailabilityEditor.swift#L177)).
It calls `AppState.cancelAllPending()` →
`AvailabilityManager.cancelPending(propertyID:)`, which cancels **every** decision
whose status `isPending`.

### Why it swept up approved work

`AvailabilityStatus.isPending` returns true for `.draft`, `.validated`,
`.awaitingApproval` **and `.approved`**
([AvailabilityDecision.swift:112](Sources/VRCCore/Availability/AvailabilityDecision.swift#L112)).
Its own doc comment gives the intent: *"Still open, so it counts as a pending
operation during **conflict checks**."*

That predicate was written to answer **"must this block an overlapping
decision?"** — and an approved-but-unpublished decision certainly must.
`cancelPending` reuses it to answer a different question: **"may this be thrown
away?"** Those are not the same question, and conflating them means a button
called "Cancel all", sitting under a heading that reads "Waiting for you",
silently discards approved work. An approved decision is arguably no longer
*waiting for you* at all — it is waiting for publication.

**This is a design observation, not a fault anyone introduced carelessly, and it
has not been changed.** Altering the semantics of an availability control is a
reviewed decision, not a cleanup, and the owner has asked not to reactivate or
publish these decisions without approval.

What *was* added is a characterisation test,
`"cancel pending also discards APPROVED decisions, not just drafts"`, which pins
the current behaviour so it cannot stay invisible. The pre-existing test
`"cancel pending clears everything open"` only ever submitted drafts, so it never
covered this path. The new test was verified to be sensitive: excluding
`.approved` from `cancelPending`'s filter makes it fail on exactly the two
assertions that matter, and the source was reverted afterwards.

### What survived, and what the owner still has to decide

Nothing was lost but the approval itself:

- both decision rows exist, with `publication_uid` `vrc-812d1978…` and
  `vrc-a5a1dbf5…` **verbatim** — which matters, because a changed UID would make
  a platform see a delete plus a create instead of an update;
- `feed_publications` is **0** — neither was ever published anywhere;
- the audit trail is complete at 10 entries and names the cause;
- December 17–18 2026 remain free of any Vrbo block decision.

**Open question for the owner:** whether that "Cancel all" click was deliberate.
If the two December blocks are still wanted, they must be re-approved
deliberately — the statuses are terminal (`cancelled` is in `isTerminal`), so
this means new decisions or an explicit reinstatement, and **neither has been
done**. CLAUDE.md lists these two under "Data that must survive"; the rows and
UIDs survive, their *approved* status does not, and that note should be reworded
once the owner says which state is intended.
