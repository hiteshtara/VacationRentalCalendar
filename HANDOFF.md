# Handoff

State of play for whoever picks this up next — a new Claude Code session, or a
person. Written to be followed **without** prior conversation history.

Updated 2026-11-09. Read [CLAUDE.md](CLAUDE.md) first for the rules and the
traps; this file is "where things stand and exactly what to do".

---

## ⚠️ STOP — the integration suite TRUNCATES the database it is pointed at

**`swift run vrc-test "PostgreSQL integration"` deletes rows. It must only
ever be pointed at a disposable, isolated database.**

Its setup — `auroraStore()` and `freshStore()` in
[Sources/VRCTestSuite/PostgresIntegrationTests.swift](Sources/VRCTestSuite/PostgresIntegrationTests.swift)
— empties `properties`, `reservations`, `holds`, `events`, `classifications`,
`availability_decisions`, `platform_listings`, `sync_runs`,
`feed_publications`, `published_feed_entries` and more before each case, so it
can compare a known workflow against a known starting point. That is correct
for a scratch database and destructive anywhere else.

**This already happened.** On 2026-11-09 the suite was pointed at the shared
staging cluster to validate B6. It destroyed staging's synthetic demo rows, its
**2 synthetic approved decisions**, and its Airbnb `platform_listings` row.
Only the demo property, reservation and hold were recoverable, because
`Scripts/seed-staging-demo.sql` restores only those three.

**No real data was lost.** The 7 events, 7 classifications and 2 approved Vrbo
decisions live in local SQLite and were never touched (re-verified below). The
loss was synthetic, and avoidable.

**Before any future run against a cluster:** create a throwaway one — the
Phase C PITR procedure in docs/STAGING-DEPLOYMENT.md §6 produces exactly such
a cluster — run against that, then delete it. Never against `vrc-staging-main`
again. `RehearsalIsolation` exists for this same reason.

---

## 0. One-line status

The Mac app is installed and working, and it shows **live data from the deployed
AWS staging backend**. Staging is up and validated through smoke tests **B5 and
B6**. Scheduled imports and outbound publishing are **off**. No real feeds import
yet. The project is **paused**.

Two things need the next person's attention, neither urgent and neither a
correctness risk: staging still carries **two leftover test-litter holds** that
need one DELETE to remove (§4), and the suite's truncating setup needs isolating
before it is ever run against a cluster again (warning above).

---

## 1. Current status and completed milestones

| Area | State |
|---|---|
| macOS app | built, signed, installed at `/Applications/VacationRentalCalendar.app` |
| Cloud integration | **working** — the app reads live status/availability from AWS staging via the bundled `vrc` helper |
| AWS staging | **deployed** in account …1110, us-east-1; cluster + 5 Lambdas + API Gateway + 3 buckets + 4 secrets |
| Tests | **352 tests / 1185 assertions**, passing on macOS; 350/1164 last verified on Linux (the 2 new tests have not been run there — see §5) |
| Cross-platform parity | byte-identical digest `b3398471b1ee56f477d9a1244b16449e8827df1616aa5fca365ef3db96c604f5` |
| Staging smoke tests | **A1–A5, B1–B6 done and passing.** B7, B8 and Phase C (PITR) remain; B9 is 3 of 4 layers verified |
| Outbound publishing | **off** — code gate, function env and database setting all verified `false` 2026-11-09; Terraform precondition not re-checked (§4) |
| Scheduled imports | **disabled** (both EventBridge schedules DISABLED) |

Completed milestones, newest first:
1. **Smoke test B6 — concurrency over the Data API** (commit `7e9a99a`). Two
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
2. **Daterange Data API fix** (found by B5 against real Aurora) — `SELECT *` on
   tables with generated `daterange` columns 400s over the RDS Data API;
   replaced with explicit column lists. Lambdas redeployed.
3. **GUI keychain fix via helper delegation** — the SwiftUI app could not read
   the AWS credential (macOS pins each keychain item to the creating binary's
   code hash; the GUI and `vrc` are different code objects). The GUI now calls
   the bundled `vrc cloud check --json` helper, which returns only sanitized
   JSON. See [docs/KEYCHAIN.md](docs/KEYCHAIN.md).
4. **Cloud integration in the Mac app** — Cloud pane, AWS status-bar indicator,
   Refresh from AWS, build-provenance tab.
5. **Staging deployed and validated** (A1–A5, B1–B5).
6. **Minimal AWS backend** — DataStore over the RDS Data API, 5 Lambda handlers,
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
| HEAD | `7e9a99a` (Add staging smoke test B6: concurrent overlapping holds) |
| PR | **#10 OPEN** (not draft): "Backend implementation: DataStore, five handlers, restricted role" — **do not merge without review** |
| Installed Mac app | commit `217f668`, build 1, clean tree, built 2026-11-09 17:05Z |

**Why the installed app is three commits behind HEAD**, and why that is fine:

| Commit | Touches | Affects the Mac app? |
|---|---|---|
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

### Staging database contents, as left on 2026-11-09

The B6 run truncated staging (see the warning at the top). What is there now:

| Table | Rows | Note |
|---|---|---|
| `properties` | 2 | the demo property (id 112) **and one litter row** (id 111) |
| `reservations` | 1 | demo, 2027-07-01→07-08, restored |
| `holds` | 3 | demo 2027-09-01→09-04 restored, **plus 2 litter holds** |
| `availability_audit` | 41 | append-only; the runtime role cannot delete from it, by design |
| `events`, `classifications`, `availability_decisions`, `platform_listings`, `sync_runs`, `feed_publications`, `published_feed_entries`, `idempotency_keys` | 0 | emptied by the run; the seed script does not restore these |

**One manual step is outstanding.** Two leftover holds from the B6 control test
(`channel = 'race'`, property `No race — 39 G Street`, 2027-06-01→05 and
2027-06-05→09) are still present, so `vrc cloud check` currently reports **four**
intervals rather than the documented two. They are synthetic and harmless — they
block nothing real and expire on their own — but they are misleading. Removing
them needs the master secret and the §9 helper:

```sql
DELETE FROM holds WHERE channel = 'race';
DELETE FROM properties WHERE name IN ('Race — 39 G Street', 'No race — 39 G Street');
```

This was attempted and refused by the session's permission policy, which
authorized only `Scripts/seed-staging-demo.sql`. It is a one-liner for whoever
has the access.

Staging's 2 synthetic approved decisions and its Airbnb `platform_listings` row
were also destroyed and are **not** restored by the seed script. Nothing depends
on them; re-create them only if a future test needs them.

### Connection verification (read-only)

```bash
# The exact call the GUI makes; sanitized JSON, no secrets.
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc cloud check --json
# Expected: ok:true, and the two demo intervals
#   (2027-07-01→07-08 reservation, 2027-09-01→09-04 hold).
# As of 2026-11-09 it ALSO returns two 2027-06 'race' holds — test litter,
# see the manual DELETE above. approvedDecisions now reads 0, not 2.
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
swift run vrc-test                      # 352 tests / 1185 assertions — all pass (macOS)
swift run vrc-parity --digest           # b3398471…c604f5
./Scripts/build-lambda.sh               # also runs the suite inside Linux; parity must match
```
- macOS: **all 352 pass** (1185 assertions), verified at commit `7e9a99a`.
- Linux: **350/350 last verified at `08c3bc1`.** The two B6 tests have **not**
  been run on Linux. They use `DispatchSemaphore` and `DispatchQueue.global()`,
  which corelibs supports, so they are expected to pass — but expected is not
  verified. `./Scripts/build-lambda.sh` runs the suite in the container and will
  settle it. Do that before trusting the Linux number.
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
| B7 `POST /decisions` twice, one idempotency key | ⬜ **not started** |
| B8 kill mid-write → client reports UNKNOWN | ⬜ **not started** |
| B9 publication still impossible | 🟨 **3 of 4 layers verified** — code, function env and database all `false`; the Terraform `precondition` (layer 3) not re-checked. See the §4 table |
| Phase C PITR into a temporary cluster, then delete | ⬜ remaining |

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
the process env, never printed). ⚠️ **This truncates the target database — point
it at a disposable cluster, never at `vrc-staging-main`.** See the warning at the
top of this file.
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
one hold. On a disposable cluster that does not matter, which is the point.

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
- **The integration suite truncates whatever database it is pointed at**, and
  has no isolation guard. It should grow one — a refusal to run against a
  cluster not explicitly marked disposable — before it is used this way again.
  See the warning at the top. This is the single most valuable small change
  left in the test suite.
- **Two litter holds remain in staging** from the B6 control test; one DELETE
  removes them (§4).
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
VRC_PG_PORT=54407 swift run vrc-test "PostgreSQL integration"
pg_ctl -D "$PGDIR" stop            # and throw the cluster away
```

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
| Approved Vrbo decisions | **2** |
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

Ordered. **Each of these is a new task; the project is paused here.**

0. **First, two small clean-ups left by the B6 round:** remove the two litter
   holds from staging (one DELETE, §4), and give the integration suite an
   isolation guard so it cannot truncate a shared cluster again (§6). Neither is
   urgent; both are quick, and the second prevents a repeat of a real mistake.
1. **Finish staging validation:** ~~B6 (concurrency / no double booking)~~ **done**;
   B7 (idempotency), B8 (interrupted write → UNKNOWN), B9 (layer 3 of 4 still
   unverified), Phase C (PITR drill into a temporary cluster, then delete it).
   Run B7/B8 against a disposable cluster, not `vrc-staging-main`.
2. **Prepare real imports (read-only):** confirm the Airbnb/Vrbo feed URLs read
   from the Keychain via the `vrc` helper; run the live feed-diff to measure the
   change-detection hit rate (decides the ~$5.76 vs ~$19.95/mo import cadence);
   store source feed URLs in `vrc-staging/sources/feed-urls`.
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
