# VacationRentalCalendar on your existing AWS environment

Discovery and design only. **No AWS resource was created or changed, no DNS was
touched, nothing was deployed.** Every command used was read-only, and no
secret value was read, printed or logged — only names.

Discovered 2026-11-09. Account `****1110`, region `us-east-1`, profile
`default` (IAM user `mukadder`). The `bu-nprd` and `bu-prd` profiles are
Boston University and were deliberately not touched.

---

## 1. Inventory

### Hosting and DNS

| Resource | Detail |
|---|---|
| Amplify app | `priyankahomes` (`d2nbyho2kwthdi`), Next.js SSR `WEB_COMPUTE`, from `github.com/hiteshtara/priyankahomes` — serves **bostonfurnishedstays.com** |
| Route 53 | `bostonfurnishedstays.com` (12 records), `39gstboston.com` (8 records) |
| CloudFront | `E31YF9KHYMR6OJ` → media.bostonfurnishedstays.com; `E23SZTUE9KFAS9` → 39gstboston.com |
| ACM | certificates for `media.bostonfurnishedstays.com`, `39gstboston.com` — **none yet for feeds. or calendar.** |

### Compute and data

| Resource | Detail |
|---|---|
| Lambda | 5 functions, all `priyankahomes-medical-*`, python3.12 |
| DynamoDB | 15 tables, pay-per-request |
| Cognito | one pool, `priyankahomes-admin` |
| API Gateway | none |
| EventBridge | 6 rules, including `priyankahomes-south-boston-hold-cleanup` at 5-minute rate |
| Secrets Manager | 15 secrets under a consistent `priyankahomes/*` convention |
| S3 | 15 buckets, including `kuali-legacy-portal-tfstate-589744711110` (Terraform state) and `priyankahomes-property-dashboard-589744711110` |
| Security | GuardDuty malware protection and CloudTrail logging both active |

### Infrastructure as code

Terraform under `projects/priyankahomes/infra/medical-assistance-documents/`,
state in S3 with `encrypt = true`, one stack covering DynamoDB, EventBridge,
KMS, S3, SNS/SQS and five Lambdas. Deployment is Amplify-driven with a quality
gate in `amplify.yml` that runs `npm test`, `tsc --noEmit` and `lint` before
Amplify cuts traffic over.

This is a well-run environment. The design below follows its conventions rather
than inventing new ones.

---

## 2. What can safely be reused — and one thing that must not

### Reuse

| Service | How | Why it is safe |
|---|---|---|
| Route 53 zone | add one subdomain record | Additive. Existing records untouched. |
| ACM | request a new certificate | New resource; DNS validation adds a CNAME. |
| Secrets Manager | new secrets under `priyankahomes/vrc/*` | Matches the existing convention; the app already has a Secrets Manager access pattern to copy. |
| Terraform backend | same bucket, **new state key** | Separate state file means a mistake here cannot corrupt the medical stack. |
| Cognito `priyankahomes-admin` | one new app client and a group | Single operator, same person. A separate pool is cleaner but is extra surface for no benefit. |
| CloudTrail / GuardDuty | nothing to do | Account-wide; new resources are covered automatically. |

### Do not reuse — and this is the important finding

**`priyankahomes-south-boston-bookings` (4 items) and
`priyankahomes-south-boston-calendar` (10 items) already exist**, alongside
`priyankahomes-south-boston-hold-cleanup` running every five minutes and a
`priyankahomes/SOUTH_BOSTON_CLEANUP_SHARED_SECRET`.

Your website already has booking and calendar functionality for this property —
almost certainly direct-booking holds taken on bostonfurnishedstays.com. That
is **a different system with a different purpose**, and VacationRentalCalendar
must not read, write, or share those tables.

Two reasons, and the second is the serious one:

1. The schemas do not match. Those are keyed on `bookingId` and `date`; this
   app keys on `(listing, UID, RECURRENCE-ID)` and treats a date range as one
   record, not a row per day.
2. **A direct booking taken on your website is real inventory that this app
   cannot currently see.** If someone books 12–14 December through
   bostonfurnishedstays.com, nothing in this project knows, and the December
   test would happily publish those nights as blocked-by-you rather than
   booked — or worse, a future version could reopen them.

That is a genuine gap in the plan as it stands, and it is worth deciding before
going live, not after. The clean fix is to treat the website's own bookings as a
**fourth source feed**: a small reader that imports from
`priyankahomes-south-boston-bookings` into this app as confirmed reservations,
exactly as Airbnb and Vrbo are imported. Until that exists, the app's picture of
this property is incomplete.

### Also noted

`priyankahomes/LODGIFY_API_KEY` is still present and in use by the website. This
project was begun to stop paying Lodgify; that saving is not realised while the
site still depends on it. Not a blocker — just worth knowing the bill does not
drop when this ships.

---

## 3. Proposed architecture

Three independent pieces, each deployable and removable on its own.

```
                 ┌──────────────────────────────────────────┐
                 │  Route 53: bostonfurnishedstays.com      │
                 │  (12 existing records — untouched)       │
                 └───────────┬──────────────────┬───────────┘
                   + feeds.  │                  │  + calendar.
                 ┌───────────▼─────────┐  ┌─────▼──────────────────┐
                 │ CloudFront (new)    │  │ Amplify app (new)      │
                 │ → S3 vrc-feeds      │  │ calendar dashboard     │
                 │ OAC, no public ACL  │  │ Cognito-authenticated  │
                 └───────────┬─────────┘  └─────┬──────────────────┘
                             │                  │
                 ┌───────────▼──────────────────▼───────────┐
                 │ Lambda (container, Swift) — VRCCore      │
                 │ import · classify · generate · publish   │
                 │ EventBridge Scheduler, hourly            │
                 └───────────┬──────────────────────────────┘
                             │
                 ┌───────────▼──────────────────────────────┐
                 │ S3: vrc-state (SQLite) + Secrets Manager │
                 └──────────────────────────────────────────┘
```

### Feeds — `feeds.bostonfurnishedstays.com`

New S3 bucket, new CloudFront distribution with Origin Access Control, new ACM
certificate, one new Route 53 record. **The existing Amplify app and its
distribution are not touched**, because a subdomain is a separate record and a
separate distribution.

A lower-risk alternative worth considering: **`feeds.39gstboston.com`**. That
zone already exists, serves only this property, and has nothing on it that
matters if something goes wrong. The blast radius of a mistake there is a
static one-property site rather than your main marketing domain.

### Dashboard — `calendar.bostonfurnishedstays.com`

A **separate Amplify app**, not a branch of `priyankahomes`. Sharing the app
would mean this project's build failures could block your marketing site's
deploys, which is not a trade worth making.

### The part that needs a decision: where the logic runs

Everything tested so far is **Swift** — 203 tests and 854 assertions covering
the classifier, the export gate, the safety rules and the publication pipeline.
Three ways to get it into AWS:

| Option | Keeps the tested core? | Cost | Notes |
|---|---|---|---|
| **Swift on Lambda, container image** | **Yes, entirely** | ~$0 | `swift-aws-lambda-runtime`; ARM64 image in ECR. Recommended. |
| Rewrite in TypeScript/Python | No — starts from zero | ~$0 | Idiomatic for the rest of your stack, and discards every safety test. |
| Keep the Mac as the importer | Yes | $0 | Simplest. Does not fix the "Mac asleep" problem. |

**Recommendation: Swift container Lambda.** A rewrite would mean reimplementing
the rules that stop an Airbnb cancellation block reaching Vrbo, and they would
be new, untested code guarding real money.

### Storage: SQLite in S3, not DynamoDB

DynamoDB is the idiomatic answer and the wrong one here. The data layer is
twelve migrations, seven repositories and a body of tests; porting it to
DynamoDB rewrites all of that.

The database is **168 KB**. A single-writer design — one scheduled Lambda,
downloading, mutating and uploading with a conditional write — is sufficient,
costs nothing, and keeps every migration and test intact.

Deliberately **not** EFS: Lambda-with-EFS requires a VPC, and a VPC Lambda that
must reach Airbnb and Vrbo needs a NAT Gateway at roughly **$32/month** —
several times the entire rest of this architecture.

### Credentials

Feed URLs move from the macOS Keychain to **Secrets Manager** as
`priyankahomes/vrc/feed-url/<listing>`. The app already abstracts this behind
`FeedCredentialStore`, so this is one new implementation, not a redesign. The
Mac build keeps using the Keychain.

---

## 4. Estimated incremental monthly cost

Two properties, three feeds, hourly imports.

| Service | Usage | Cost |
|---|---|---|
| S3 (feeds + state) | < 5 MB, ~1,500 requests | **< $0.01** |
| CloudFront | ~50 MB, ~1,000 requests | **$0** — free tier is 1 TB and 10M requests |
| Lambda | 720 invocations, ~3s, 512 MB | **$0** — free tier is 1M requests, 400k GB-s |
| EventBridge Scheduler | 720 invocations | **$0** — first 14M free |
| Secrets Manager | 4 secrets | **$1.60** — $0.40 each |
| ECR | one ~150 MB image | **$0.015** |
| ACM | 2 certificates | **$0** |
| Route 53 | records in an existing zone | **$0** — the zone is already billed |
| Amplify (dashboard) | low traffic SSR | **~$0–1** |
| **Total** | | **≈ $2–3/month** |

Secrets Manager is most of it. SSM Parameter Store standard parameters are free
and would bring it to well under a dollar; Secrets Manager is recommended only
because your codebase already has a working pattern for it.

---

## 5. Database and credential migration

**Database.** The SQLite file is 168 KB with 7 events, 7 classifications and 2
approved decisions. Migration is a file upload — `VACUUM INTO` a clean copy,
`aws s3 cp` it to the state bucket. Nothing is transformed, so nothing can be
lost in transformation. The Mac copy stays as the rollback.

**Credentials.** Three feed URLs, entered by hand into Secrets Manager — never
exported from the Keychain to a file, never passed on a command line, never
committed. They are the same secrets already working on the Mac.

**Reverse path.** Download the SQLite file and reopen it on the Mac. The schema
is identical, so a cloud deployment is reversible rather than a one-way door.

---

## 6. Risks to the existing rental website

| Risk | Severity | Mitigation |
|---|---|---|
| Deploying into the existing Amplify app breaks the marketing site | **High** | Separate Amplify app. Never share. |
| Terraform state collision corrupts the medical stack | **High** | Separate state key; `terraform plan` reviewed before any apply. |
| Writing to the south-boston DynamoDB tables corrupts live bookings | **High** | Do not read or write them from this project. A reader, if built, is strictly read-only. |
| Route 53 edit damages existing records | Medium | Only additive record creation; the 12 existing records are never edited. |
| ACM validation CNAME conflicts | Low | New unique names. |
| IAM over-permission | Medium | New role scoped to the two new buckets and four new secrets. No wildcards. |
| Cost surprise | Low | Everything inside free tiers except Secrets Manager. Budget alarm at $10. |

**Nameservers stay on Route 53.** The earlier Cloudflare R2 plan would have
required moving the whole zone to Cloudflare, because R2 custom domains need the
zone in Cloudflare and partial CNAME setup is Business-plan only. That would
have put a live site at risk to host one small file. **I was wrong to recommend
R2 before knowing you had a Route 53 zone and a live CloudFront site; AWS is
clearly the right answer here.**

---

## 7. Phased deployment plan

Each phase is independently useful and independently reversible. **None has been
started.**

**Phase 1 — feeds only.** S3 bucket, CloudFront, ACM, one Route 53 record. The
Mac stays the importer and publisher. Delivers a continuously reachable feed
while touching no existing resource. Reversible by deleting three new resources.

**Phase 2 — the website's own bookings.** A read-only importer for
`priyankahomes-south-boston-bookings`, so direct bookings become confirmed
reservations in this app. **This should come before going live**, for the
reason in section 2.

**Phase 3 — scheduled imports in the cloud.** Swift container Lambda plus
EventBridge Scheduler, SQLite in S3. Removes the Mac-must-be-awake limitation.

**Phase 4 — dashboard.** Separate Amplify app on `calendar.`, behind Cognito.

**Phase 5 — outbound activation.** The gate, and only with explicit approval.

---

## 8. Manual steps that need your account

Nothing here has been done.

1. Confirm which domain the feeds should use — `feeds.bostonfurnishedstays.com`
   as asked, or `feeds.39gstboston.com` for a smaller blast radius.
2. Decide Secrets Manager (~$1.60/month, matches your existing pattern) or SSM
   Parameter Store (free).
3. Decide whether the `priyankahomes-admin` Cognito pool gains a VRC group, or a
   separate pool is created.
4. Confirm what the `south-boston-bookings` table actually holds, so the Phase 2
   reader maps it correctly.
5. Approve `terraform apply` for the Phase 1 stack after reviewing its plan.

## What is still true

The two approved Vrbo decisions are unchanged and unpublished. December 17 and
18 remain excluded. Publication scope is set to **approved blocks only**, so a
reservation arriving mid-test cannot widen what is published.
`OutboundSyncGate.isEnabled` is `false`. 203 tests, 854 assertions, all passing.
