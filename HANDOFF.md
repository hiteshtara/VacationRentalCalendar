# Handoff

State of play for whoever picks this up next — a new session, or a person.
Updated 2026-11-09.

Read [CLAUDE.md](CLAUDE.md) first for the rules and the traps. This file is
only "where things stand and what to do next".

---

## One-line status

The Mac app works and is in daily-usable shape. The AWS backend is **written
and tested but not deployed**, and two things block progress — both listed in
§4, one of which only the owner can do.

**Nothing is deployed. No AWS resource exists. Outbound sync is off.**

---

## 1. What works today

| | State |
|---|---|
| macOS app | built, signed, installed at `/Applications/VacationRentalCalendar.app` |
| Business logic | 304 tests / 1041 assertions, passing on macOS **and** Linux |
| Cross-platform parity | byte-identical digest `b3398471…c604f5` |
| PostgreSQL schema | applies to a real cluster; repository workflows verified against it |
| Five Lambda handlers | build for arm64 Linux, package to 5.5–5.6 MB zips |
| Terraform | `plan` = 65 to add, 0 to change, 0 to destroy; **never applied** |
| Preserved data | 2 approved Vrbo decisions, 7 events, 7 classifications, both publication UIDs |

## 2. Everyday commands

```bash
swift run vrc-test                      # all tests
swift run vrc-test "Cloud client"       # one group
swift run vrc-parity --digest           # the parity digest
./Scripts/check-parity.sh               # macOS vs Linux (needs Docker)
./Scripts/build-app.sh --install        # build + sign + install the Mac app
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc status
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc doctor
```

The Mac app talks to the AWS staging service through these:

```bash
vrc cloud status                        # endpoint, region, whether the key reads
vrc cloud set-endpoint https://…        # https only; stored in app_settings
vrc cloud set-credentials               # access key, read without echo
vrc cloud check                         # one signed request to the live service
```

**Re-store the credential after every `build-app.sh --install`.** The Keychain
item's access list is pinned to the binary that created it, so a reinstall can
leave it unreadable — the Cloud pane says so and names the remedy. Piping avoids
the secret ever reaching a terminal or a shell history:

```bash
aws iam create-access-key --user-name vrc-staging-mac-client --output json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)["AccessKey"]; print(d["AccessKeyId"]); print(d["SecretAccessKey"])' \
  | /Applications/VacationRentalCalendar.app/Contents/MacOS/vrc cloud set-credentials --stdin
```

An AWS secret cannot be read back after creation, so replacing the Keychain
entry means rotating the key: delete the old one first.

PostgreSQL integration tests need a local cluster:

```bash
initdb -D /tmp/pg && pg_ctl -D /tmp/pg -o "-p 54407" start
createdb -p 54407 vrc
psql -p 54407 -d vrc -f Migrations/postgres/010_repository_schema.sql
psql -p 54407 -d vrc -f Migrations/postgres/011_safety.sql
VRC_PG_PORT=54407 swift run vrc-test "PostgreSQL integration"
./Migrations/postgres/tests/004_concurrency_test.sh 54407 vrc
```

If you change the SQLite schema, regenerate the Postgres one:

```bash
./Scripts/generate-postgres-schema.sh
```

## 3. Branches and PRs

None merged. Review in dependency order.

```
main
 └── feature/central-booking-system .......... PR #4  architecture + docs
      ├── backend/change-detection ........... PR #5  semantic feed hashing
      ├── backend/withdrawal-protection ...... PR #6  database guards
      ├── infra/terraform-foundation ......... PR #7  superseded by #9
      ├── backend/linux-parity ............... PR #8  Linux + parity + secure set-url
      ├── infra/minimal-sync-service ......... PR #9  trimmed infrastructure
      └── backend/aws-backend ................ PR #10 ← the live branch
```

PRs #1 (iOS/CloudKit), #2 and #3 predate the current architecture. #1 is
probably unnecessary now: the owner reaches the data from a browser-free Mac app
and the cloud API, so the $99 Apple enrolment is not needed.

## 4. What blocks progress

**① Keychain credentials are unreadable — only the owner can fix this.**
The items are cdhash-pinned to a pre-signing build, and macOS refuses them
without ever showing a prompt. Three commands, run by the owner in Terminal:

```bash
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc set-url --listing 2   # Airbnb
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc set-url --listing 1   # Vrbo
/Applications/VacationRentalCalendar.app/Contents/MacOS/vrc feed-diff --gap 300
```

`set-url` clears terminal echo, verifies the URL by fetching and parsing it
**before** saving, prints only the host and shape, and refuses to save if stdin
is not a terminal. Do **not** run these on the owner's behalf: a feed URL on a
command line lands in shell history, in `ps`, and in the transcript.

**② The live feed-diff decides the cost.** It follows from ①. If Airbnb and
Vrbo regenerate `DTSTAMP` in a way the normalisation does not absorb, change
detection never fires, the database never sleeps, and the bill goes from about
$5.76/month to about $19.95. Until it runs, the estimate is a range.

**③ Static Linux SDK is not installed.** `swift sdk list` reports none. Needed
for deployable binaries: a Docker-built binary links 13 Swift/Foundation shared
objects that do not exist on `provided.al2023` and fails at startup.
`Scripts/build-lambda.sh` refuses to package one.

**④ The publisher is deliberately not wired** to live decisions. It returns
`refused` even with both gates open. That is the step after authorisation, left
unwritten rather than left disabled.

## 5. Suggested order of work

1. Owner does ①, then ② runs and the cost question closes.
2. Install the Static Linux SDK (③) and produce real packages.
3. Owner approves infrastructure; `terraform apply`; apply `010` + `011`; set
   the `vrc_runtime` password out of band.
4. Deploy the handlers with schedules still **disabled**. Enable the sweeper
   first, observe a day, then imports.
5. Migrate the SQLite data, with the before/after reconciliation reports.
6. Only then discuss publication, which needs an explicit decision to flip
   `OutboundSyncGate.isEnabled`.

## 6. Where the reasoning is written down

| Document | Covers |
|---|---|
| `docs/CENTRAL-ARCHITECTURE.md` | the central-system design |
| `docs/MINIMAL-SYNC-SERVICE.md` | the trimmed scope and its cost |
| `docs/BACKEND-IMPLEMENTATION.md` | DataStore, handlers, security |
| `docs/PR10-COMPLETION.md` | transaction lifecycle fixes, Mac client |
| `docs/MIGRATION-PLAN.md` | migration, reconciliation, Google retirement |
| `docs/WEBSITE-BOOKING-INTEGRATION.md` | the direct-booking source |
| `Migrations/postgres/superseded/README.md` | why the first schema was replaced |

## 7. Decisions already made — don't reopen without reason

- PostgreSQL, not DynamoDB, and not SQLite-in-S3.
- Aurora Serverless v2, minimum 0 ACU, reached over the RDS Data API — which is
  what keeps the Lambdas out of a VPC and avoids a ~$32/month NAT gateway.
- No web dashboard. The Mac app stays; AWS only does what the Mac cannot do
  while asleep.
- API Gateway `AWS_IAM` with SigV4, not Cognito. No login, no tokens, and it
  reuses the signer already in `VRCCore`.
- AWS-managed KMS keys, not a customer-managed key ($1/month per key version,
  growing yearly with rotation).
- 15-minute imports, made cheap by change detection rather than by polling less.
