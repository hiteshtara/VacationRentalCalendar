# Phase C — hosting proposal for the filtered feeds

**Nothing has been deployed.** This is the design and the security review you
asked for before anything is built. It supersedes the sketch in
`HOSTING-OPTIONS.md` with a concrete recommendation and the answers to the six
questions you raised about Cloudflare R2.

Reviewed 2026-11-09.

---

## What has to be true

Airbnb, Vrbo and Booking.com pull iCal over the public internet on their own
schedule — every two to three hours, and sometimes much longer. For a published
block to work, the feed has to answer **when they ask**, not when your Mac
happens to be awake.

So the service must be:

1. Reachable over HTTPS at a stable URL, continuously.
2. Unguessable, because a calendar feed tells a reader when your property is
   empty — and therefore when you are probably not there.
3. Revocable, because a URL that leaks cannot be un-leaked.
4. Fresh, because a cached copy of yesterday's availability is worse than no
   feed at all.
5. Atomic, because a platform reading a half-written file would see a calendar
   with events missing.
6. Observable, because a feed that silently stops being served looks exactly
   like a feed with nothing in it.

Point 6 deserves emphasis. **A missing or empty feed does not unblock dates** —
platforms keep what they last read — but a feed serving a *stale* copy can keep
nights blocked after you reopened them. The dangerous failure is silence
combined with staleness, not outage alone.

---

## Your six questions about R2

### 1. Does its public endpoint design support private, unguessable URLs?

**Partly, and the obvious route is the wrong one.**

R2 offers two ways to serve a bucket publicly:

- **`r2.dev` subdomain** — `https://pub-<hash>.r2.dev/<key>`. Cloudflare
  documents this as **development only**: it has no caching, no WAF, no access
  controls and is rate-limited. Not suitable here.
- **Custom domain** — attach a domain you control on Cloudflare. This is the
  production path, and it means **you need a domain**, roughly $10/year.

With either, unguessability has to come from the **object key**, not the host.
A key such as `feeds/39-g-street/vrbo-7f3a9c1e4b2d8a6f5c0e9d7b3a1f6c48.ics`
(128 bits of randomness) is not enumerable: R2 does not list bucket contents
publicly, and Cloudflare returns 404 for a wrong key.

**Presigned URLs are not an option.** They only work on the S3 API endpoint,
not on a custom domain, and they expire — which is precisely wrong for a URL a
platform must keep fetching indefinitely. A presigned feed URL would simply
stop working mid-season.

So: security here is *unguessable path over HTTPS*, the same model the platforms
themselves use for their export URLs. That is acceptable, and it is worth being
plain that it is **bearer-token security, not authentication**. Anyone with the
URL can read the feed. It is exactly the security model Airbnb and Vrbo apply to
your inbound URLs today.

### 2. How can feed tokens be revoked?

By **rotating the key**: write the feed to a new random key, delete the old
object, and re-paste the new URL into each platform.

Two consequences to accept up front:

- Revocation is **not instant from the platform's side** — until you update the
  subscription there, that platform simply gets a 404 and keeps the availability
  it last read. It does not unblock anything, but it does go stale.
- There is no per-recipient revocation. One URL per destination platform limits
  the blast radius, and is what the design does anyway since each destination
  gets a different feed.

The application should therefore store a key version per destination and support
"rotate this feed URL" as a first-class action, with a reminder listing the
platforms that need re-pasting.

### 3. Could caching serve stale availability?

**Yes, and this is the most serious risk of the three.**

On a custom domain, R2 objects are served through Cloudflare's cache. If a
platform fetches a cached copy after you reopen dates, those nights stay blocked
on that platform until the cache expires.

Mitigations, all required:

- Set `Cache-Control: public, max-age=60, must-revalidate` on the object's
  metadata at write time. R2 honours per-object cache metadata.
- Purge the cache for that key on every publish (Cloudflare API call).
- Treat a publish as incomplete until the purge succeeds, and surface a failure
  rather than reporting success.
- Keep the UI honest regardless: the status stays *"Published — awaiting platform
  confirmation"* until the destination's own export confirms the nights, which is
  what `SyncVerifier` already enforces.

Note the asymmetry — stale cache is dangerous when **reopening** and harmless
when **blocking**. A reopen should therefore wait for cache purge confirmation
before being reported as published at all.

### 4. Is feed publication atomic?

**Yes, for a single small object.** An R2 `PUT` of one object either replaces it
entirely or does not; readers never see a partial write. Our feeds are a few
kilobytes, far below any multipart threshold.

The non-atomic part is the *sequence* — write object, then purge cache — which
can half-succeed. Treat the publish as a two-step transaction, record both
outcomes in `feed_publications`, and mark the publication `failed` if the purge
fails, so it is retried rather than assumed good.

### 5. How will availability and failures be monitored?

Three layers, because the quiet failure is the one that matters:

- **External uptime check** every 15 minutes against each feed URL, asserting
  HTTP 200, `text/calendar`, and that the body contains `BEGIN:VCALENDAR`.
  A free tier of any uptime service covers three URLs.
- **Content freshness assertion** — the generator stamps `X-WR-CALDESC` with the
  revision and generation time. The check asserts the served revision matches
  the latest in `feed_publications`. This is what catches a stale cache, which
  an uptime check alone would report as healthy.
- **In-app**: the Destination status screen already shows last generated, last
  published, and whether the destination's own export confirms the nights. That
  is the check that actually matters, because it tests the end-to-end outcome
  rather than the file server.

### 6. What would it cost at our usage?

Two properties, three feeds, a few kilobytes each, republished on change and
polled a few times an hour.

| Item | Usage | Cost |
|---|---|---|
| R2 storage | < 1 MB | $0 (10 GB free) |
| Class A operations (writes) | ~100/month | $0 (1M free) |
| Class B operations (reads) | ~3,000/month | $0 (10M free) |
| Egress | ~50 MB/month | **$0 — R2 charges no egress** |
| Cloudflare account | — | $0 |
| **Domain name** | 1 | **~$10/year** |
| Uptime monitoring | 3 checks | $0 (free tier) |
| **Total** | | **~$10/year** |

Comfortably inside R2's free tier. The only real cost is the domain, and you may
already have one.

---

## Comparison with the alternatives

| Option | Annual cost | Always on | Unguessable | Revocable | Cache control | Atomic | Verdict |
|---|---|---|---|---|---|---|---|
| **R2 + custom domain** | ~$10 | Yes | Key-based | Rotate key | Per-object + purge | Yes | **Recommended** |
| Cloudflare Pages | ~$10 | Yes | Key-based | Redeploy | Good | Yes | Close second; build step adds moving parts |
| GitHub Pages | $0 | Yes | **No — public repo on free tier** | — | Poor | Yes | **Rejected: your occupancy calendar would be world-readable** |
| S3 + CloudFront | ~$10 + ~$1/mo | Yes | Key or signed | Rotate | Good | Yes | Works; egress charges and more configuration |
| VPS (Hetzner etc.) | ~$50–70 | Yes | Any | Any | Full | Yes | Most control, most maintenance; overkill for 3 files |
| Raspberry Pi + Tunnel | $0 if owned | Mostly | Any | Any | Full | Yes | Home internet and power become dependencies |
| iCloud Drive link | $0 | No | No | Weak | None | No | **Rejected: serves an HTML page, not file bytes** |
| **Do not publish at all** | $0 | — | — | — | — | — | **Current state. Still defensible.** |

---

## Recommendation

**Cloudflare R2 behind a custom domain**, with:

- one object per destination per property, at a 128-bit random key;
- `Cache-Control: max-age=60, must-revalidate` written as object metadata;
- a cache purge after every write, with the publish marked failed if it does not
  succeed;
- key rotation exposed in the app as "rotate this feed URL";
- external uptime plus a revision-freshness check;
- status never advancing past *"Published — awaiting platform confirmation"*
  without evidence from the destination's own export.

**But consider staying on "do not publish" a while longer.** Right now all seven
of your imported events are undecided, so the feeds this design would serve
would be empty. Publishing infrastructure for an empty feed buys nothing. The
natural sequence is: work the review queue, use the editor to record what you
actually want blocked where, watch the generated feeds for a booking cycle, and
only then decide whether automatic publication is worth $10 and a cache-purge
dependency over pasting a block into two websites a few times a season.

---

## Security review of the design as built

| Area | Finding |
|---|---|
| Inbound feed URLs | In the Keychain, never in SQLite, never in git, never in a cloud record. Verified by test. |
| Outbound feed URLs | Would be bearer secrets. Must be stored the same way, and the app must never log or display them in full. **Not yet implemented — no publication exists.** |
| Guest data | Generated feeds carry `Reserved` / `Not available` and nothing else. Source UIDs are not exposed; outbound UIDs are derived per destination so two platforms cannot correlate feeds. Verified by test. |
| Circular imports | Entries bearing our own marker are dropped on sight. Without this, a block echoing back through a platform could never be withdrawn. Verified by test. |
| Cancellation blocks | Excluded at the export gate with no override, and excluded again at feed generation. Two independent layers. Verified by test. |
| Authorisation | Every state change passes through `AvailabilityManager`, which enforces the transition table and writes an audit row. Publication additionally requires `OutboundSyncGate`. |
| Audit | Append-only. Cancellation is a new row, never a deletion. |
| Residual risk | An unguessable URL is bearer security. If it leaks, an observer learns your occupancy pattern until you rotate. This is the same exposure the platforms' own export URLs already carry. |

---

## What would be built in Phase D — not now

1. A `FeedHostingClient` with one implementation (R2 via S3-compatible API).
2. Key generation, storage in the Keychain, and rotation.
3. Cache purge, with publication marked failed when it does not confirm.
4. `OutboundSyncCoordinator.publish` wired to it, still behind the gate.
5. Flipping `OutboundSyncGate.isEnabled` — a deliberate code change, reviewed,
   never a toggle in the interface.

None of that exists today, and `publish` throws.
