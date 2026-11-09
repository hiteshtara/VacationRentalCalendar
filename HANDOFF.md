# Handoff

State of play for whoever picks this up next — a new Claude Code session, or a
person. Written to be followed **without** prior conversation history.

Updated 2026-11-09. Read [CLAUDE.md](CLAUDE.md) first for the rules and the
traps; this file is "where things stand and exactly what to do".

---

## 0. One-line status

The Mac app is installed and working, and it shows **live data from the deployed
AWS staging backend**. Staging is up and validated through smoke test B5.
Scheduled imports and outbound publishing are **off**. No real feeds import yet.
The project is **paused** at a clean stopping point.

---

## 1. Current status and completed milestones

| Area | State |
|---|---|
| macOS app | built, signed, installed at `/Applications/VacationRentalCalendar.app` |
| Cloud integration | **working** — the app reads live status/availability from AWS staging via the bundled `vrc` helper |
| AWS staging | **deployed** in account …1110, us-east-1; cluster + 5 Lambdas + API Gateway + 3 buckets + 4 secrets |
| Tests | **350 tests / 1164 assertions**, passing on macOS **and** Linux |
| Cross-platform parity | byte-identical digest `b3398471b1ee56f477d9a1244b16449e8827df1616aa5fca365ef3db96c604f5` |
| Staging smoke tests | **A1–A5, B1–B5 done and passing.** B6–B9 and Phase C (PITR) remain |
| Outbound publishing | **off** at every layer (code gate, env var, no schedule) |
| Scheduled imports | **disabled** (both EventBridge schedules DISABLED) |

Completed milestones, newest first:
1. **Daterange Data API fix** (found by B5 against real Aurora) — `SELECT *` on
   tables with generated `daterange` columns 400s over the RDS Data API;
   replaced with explicit column lists. Lambdas redeployed.
2. **GUI keychain fix via helper delegation** — the SwiftUI app could not read
   the AWS credential (macOS pins each keychain item to the creating binary's
   code hash; the GUI and `vrc` are different code objects). The GUI now calls
   the bundled `vrc cloud check --json` helper, which returns only sanitized
   JSON. See [docs/KEYCHAIN.md](docs/KEYCHAIN.md).
3. **Cloud integration in the Mac app** — Cloud pane, AWS status-bar indicator,
   Refresh from AWS, build-provenance tab.
4. **Staging deployed and validated** (A1–A5, B1–B5).
5. **Minimal AWS backend** — DataStore over the RDS Data API, 5 Lambda handlers,
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
| HEAD | `08c3bc1` (Fix daterange SELECT * over the RDS Data API) |
| PR | **#10 OPEN** (not draft): "Backend implementation: DataStore, five handlers, restricted role" — **do not merge without review** |
| Installed Mac app | commit `217f668`, build 1, clean tree, built 2026-11-09 17:05Z |

**Why the installed app is one commit behind HEAD:** `08c3bc1` changes only the
Lambda/Data-API path and tests. The Mac app uses local SQLite, where `SELECT *`
is fine, so its behaviour is unchanged. The **deployed Lambdas** already carry
the `08c3bc1` fix (redeployed). Rebuilding the Mac app would change the helper's
code hash and orphan its Keychain credential (see §8), so it was deliberately
left at `217f668`. To bring it to HEAD later, rebuild and then run the
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

**Safety invariants, all currently true (verify before any change):**
- Both schedules DISABLED.
- `VRC_OUTBOUND_ENABLED=false` on `vrc-staging-api` and `vrc-staging-publish`;
  `OutboundSyncGate.isEnabled = false` in code.
- Nothing published to Airbnb, Vrbo, or Booking.com.
- PriyankaHomes tables, both hosted zones, and production DynamoDB untouched.

### Connection verification (read-only)

```bash
# The exact call the GUI makes; sanitized JSON, no secrets.
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc cloud check --json
# Expected: ok:true, two intervals (2027-07-01→07-08, 2027-09-01→09-04).
```

The cluster auto-pauses after 5 minutes idle; the first call after a pause can
take 15–30s while Aurora resumes, and may briefly report "Could not reach." Retry.

The two intervals are **synthetic staging demo data** (one confirmed
reservation, one active hold), restored by `Scripts/seed-staging-demo.sql`. The
integration suite clears those tables, so re-seed after running it:
```bash
# apply Scripts/seed-staging-demo.sql via the master secret (see §9 helper)
```

---

## 5. Test results and parity

```bash
swift run vrc-test                      # 350 tests / 1164 assertions — all pass (macOS)
swift run vrc-parity --digest           # b3398471…c604f5
./Scripts/build-lambda.sh               # also runs the suite inside Linux; parity must match
```
- macOS: **all 350 pass**. Linux (container with `sqlite-devel`): **all 350 pass**.
- Parity digest **unchanged** by every fix this round: `b3398471b1ee56f477d9a1244b16449e8827df1616aa5fca365ef3db96c604f5`.

### Staging smoke tests (docs/STAGING-DEPLOYMENT.md §6)

| Test | Status |
|---|---|
| A1–A5 (bring-up, migrate, deploy) | ✅ done |
| B1 unsigned event → 401, Aurora stays paused | ✅ |
| B2 unsigned HTTPS → 403 at the gateway | ✅ |
| B3 SigV4-signed from the Mac → 200 | ✅ |
| B4 sweeper by hand → holdsReleased:0, no reservation touched | ✅ (prior run) |
| **B5 Data API transactions: Swift suite vs cluster** | ✅ **8/8 against live Aurora** |
| B6 concurrency: overlapping holds, one winner | ⬜ remaining |
| B7 `POST /decisions` twice, one idempotency key | ⬜ remaining |
| B8 kill mid-write → client reports UNKNOWN | ⬜ remaining |
| B9 publication still impossible | ⬜ remaining (invariants in §4 hold) |
| Phase C PITR into a temporary cluster, then delete | ⬜ remaining |

**To run B5 against the live cluster** (credentials read from the AWS CLI config
into the process env, never printed):
```bash
VRC_CLUSTER_ARN="arn:aws:rds:us-east-1:589744711110:cluster:vrc-staging-main" \
VRC_DB_SECRET_ARN="$(aws secretsmanager describe-secret --secret-id vrc-staging/database/runtime --query ARN --output text)" \
VRC_DB_NAME=vrc VRC_ACTOR=owner AWS_REGION=us-east-1 \
AWS_ACCESS_KEY_ID="$(aws configure get aws_access_key_id)" \
AWS_SECRET_ACCESS_KEY="$(aws configure get aws_secret_access_key)" \
swift run vrc-test "PostgreSQL integration"
```
Re-seed the demo data afterward (the suite clears `reservations`/`holds`/`properties`).

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
- B6–B9 and Phase C not yet run.
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

# Local PostgreSQL integration tests (no AWS; needs a local cluster)
initdb -D /tmp/pg && pg_ctl -D /tmp/pg -o "-p 54407" start
createdb -p 54407 vrc
psql -p 54407 -d vrc -f Migrations/postgres/010_repository_schema.sql
psql -p 54407 -d vrc -f Migrations/postgres/011_safety.sql
VRC_PG_PORT=54407 swift run vrc-test "PostgreSQL integration"
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

## 9. Preserved application data (verified 2026-11-09)

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

1. **Finish staging validation:** B6 (concurrency / no double booking), B7
   (idempotency), B8 (interrupted write → UNKNOWN), B9 (publication impossible),
   Phase C (PITR drill into a temporary cluster, then delete it).
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
