# Vrbo live test — prepared, not activated

Everything below is built, rehearsed and waiting. **Nothing is deployed, no
feed is connected, and `OutboundSyncGate.isEnabled` is still `false`.**

Prepared 2026-11-09.

---

## What is being tested

Two approved availability decisions for **39 G Street, South Boston**, on
**Vrbo only**:

| Decision | Range (check-out exclusive) | Nights |
|---|---|---|
| #1 | 2026-12-10 → 2026-12-17 | 7 |
| #2 | 2026-12-19 → 2026-12-20 | 1 |

**December 17 and 18 are excluded on purpose.** Airbnb blocked them after a
cancellation; they are not booked, and they stay on sale on Vrbo. That omission
is the point of the exercise, and a test asserts those two nights never appear
in the served feed.

Airbnb and Booking.com have **no decision rows at all**.

---

## URL structure

```
https://feeds.<your-domain>/feeds/39-g-street/vrbo/<32-hex-token>.ics
                            └─ prefix ─┘└ property ┘└ dest ┘└─ secret ─┘
```

One path per destination, so no two platforms can correlate feeds. The secret
is 128 bits of randomness in the **object key**, not the hostname.

Three decisions worth stating plainly:

- **`r2.dev` is never used.** Cloudflare documents it as development-only: no
  caching, no WAF, no access controls. Production needs a custom domain.
- **Presigned URLs are not used.** They only work on the S3 API endpoint, not a
  custom domain, and they expire — which is exactly wrong for a URL a platform
  must keep fetching indefinitely. A feed that silently stops working mid-season
  is worse than no feed.
- **This is bearer security, not authentication.** Anyone holding the URL can
  read your occupancy. It is the same model Airbnb and Vrbo already use for the
  export URLs you gave this app, and the token lives in the Keychain like the
  rest.

**Revocation** is key rotation: write to a new random key, delete the old
object, re-paste the new URL into Vrbo. Until you re-paste, Vrbo gets a 404 and
keeps the availability it last read — stale, never wrong-but-plausible.

---

## Can it serve while the Mac is off?

**Yes.** R2 is object storage behind Cloudflare's edge; the file is served
whether or not your Mac is awake. The Mac is only needed to *change* the file.

The honest limit: the feed is as fresh as your last upload. A booking taken
while the Mac is off does not reach the feed until it wakes. That is a property
of every iCal setup, paid ones included.

---

## Atomic publication

A single `PUT` replaces an R2 object atomically — a reader gets the old bytes or
the new ones, never half a calendar. Our feeds are a few kilobytes, far below
any multipart threshold.

The *sequence* is not atomic: upload, then purge the cache. That is why
publication is a pipeline with distinct stages rather than one boolean, and why
a failed purge stops at `uploaded` instead of reporting success. Uploaded-but-
not-purged is a real state — new bytes at the origin that nobody is being
served — and conflating it with either success or failure would be a lie.

## Caching

`Cache-Control: public, max-age=60, must-revalidate`, written as object
metadata, plus a cache purge on every publish.

The dangerous direction is asymmetric. A stale cache when **adding** a block is
harmless — the dates were already on sale. A stale cache when **reopening** is
not: it keeps nights off sale after you released them. So a publish is not
complete until the purge confirms.

---

## Cost

Two properties, three feeds, a few kilobytes, republished on change and polled
a few times an hour.

| Item | Our usage | Free allowance | Cost |
|---|---|---|---|
| R2 storage | < 1 MB | 10 GB | **$0** |
| Class A operations (writes) | ~100/month | 1,000,000 | **$0** |
| Class B operations (reads) | ~400/month | 10,000,000 | **$0** |
| Egress | ~50 MB/month | unlimited — R2 charges none | **$0** |
| Cloudflare account | — | — | **$0** |
| Uptime monitoring | 3 checks | free tier | **$0** |
| **Domain name** | 1 | — | **~$10/year** |

**Total: about $10 a year, all of it the domain.**

Verified against Cloudflare's official documentation on 2026-11-09:
[R2 pricing](https://developers.cloudflare.com/r2/pricing/) and
[public buckets](https://developers.cloudflare.com/r2/buckets/public-buckets/).
One detail worth knowing: **Cloudflare rounds usage up to the next billing
unit**, so 1.1 GB bills as 2 GB-month. At our volume that is still zero.

The custom-domain requirement is Cloudflare's, not a preference of mine. The
docs state `r2.dev` "is intended for non-production traffic", is rate-limited,
and supports no caching, WAF, access controls or Bot Management; they also warn
that CNAMEing to it is "an unsupported access path" with no reliability
guarantee. If you already own one, it is
free. Rates used: storage $0.015/GB-month, Class A $4.50/million, Class B
$0.36/million, egress free.

For comparison, the channel manager this replaces is tens of dollars a month.

---

## Rehearsal results

The whole pipeline was run against an isolated local directory — same code
path, no network, no account. The "cache" is a second directory, so a failed
purge is a state the rehearsal actually produces rather than merely asserts.

| # | Scenario | Result |
|---|---|---|
| 1 | Publish without approving the change | `awaiting_addition_approval`, nothing uploaded, nothing served |
| 2 | Publish with approval | `platform_refresh_pending`, **2 events / 8 nights served**, `isRemoteSynchronised = false` |
| 3 | Upload fails | `failed`, previous feed still serving untouched |
| 4 | Cache purge fails | `uploaded` — origin has new bytes, nobody is served them, not counted as published |
| 5 | Roll back | last known good restored, 2 entries serving again |

Also asserted: a half-published feed is **never** recorded as last-known-good —
bytes nobody was served must not become the recovery point.

The rehearsal runs against a `VACUUM INTO` copy of the database. An earlier
version wrote its publication rows into the real one, which would have corrupted
the next genuine publish, since the safety diff compares against the last known
good feed and a rehearsal snapshot is not one. Those rows were removed.

**189 tests, 791 assertions, all passing.** Twelve are new and cover the URL
structure, cache policy, the eight-night output, the protected nights, approval
gating, both failure modes, rollback and failure reporting.

---

## What remains before activation

Nothing below has been done, and none of it will be without your word.

1. **Register a domain** and add it to Cloudflare (~$10/year).
2. **Create the R2 bucket** and attach the custom domain.
3. **Create an R2 API token** (object read/write, that bucket only) and a
   Cloudflare API token (cache purge, that zone only). Both go in the Keychain.
4. **Store the configuration** — account id, bucket, domain, zone id.
5. **Generate the feed token** and record the URL.
6. **Set `OutboundSyncGate.isEnabled = true`** — a reviewed code change, never
   a toggle in the interface.
7. **Publish**, and confirm the URL returns the expected two events.
8. **Paste the URL into Vrbo** — Calendar → Import/Export → Import calendar.
9. **Wait**, then verify against Vrbo's own export. Status stays
   *"Published — awaiting platform confirmation"* until that confirms.

Step 6 is the one that matters. Everything up to it is reversible by deleting a
file; after it, a real platform is reading your calendar.

---

## Architecture review verdict

**Suitable for controlled, manual synchronisation testing. Not suitable as
production channel management.**

That is not a defect in the implementation. It is what iCal can do, and it is
equally true of any tool built on iCal, paid ones included. What differs is
whether the limitation is visible.

### Why

A booking taken on Airbnb reaches Vrbo through four steps:

1. Airbnb publishes it to its export.
2. **This Mac imports it.**
3. **This Mac republishes the filtered feed.**
4. Vrbo re-reads that feed, on Vrbo's schedule.

Steps 2 and 3 happen only while this Mac is awake. So:

| Situation | Delay before Vrbo knows |
|---|---|
| Mac awake | up to ~13 hours — 1h import cycle, then up to 12h for Vrbo to poll |
| Mac asleep or off | **unbounded** — nothing updates until it wakes |

The hosted feed never breaks while the Mac is off; it keeps serving the last
version correctly. It simply stops being *current*, and the staleness is
asymmetric: a feed missing a block is harmless, because the dates were already
on sale. **A feed missing a reservation is not** — Vrbo may accept a booking
for a night that is already taken.

### What this is good for

- Seeing all three calendars in one place, with cancellation blocks and
  booking-window artefacts separated out rather than blindly propagated.
- Deliberately blocking dates on one platform without touching the others.
- A one-way, owner-approved publication of blocks you decided on.

### What it must not be relied on for

- Preventing double bookings.
- Any expectation that blocking dates here protects them immediately.
- Running unattended while the Mac is off for days.

### What would change the verdict

Real-time protection needs a direct API integration, which none of the three
platforms offers to individual hosts. Short of that, the honest improvements
are: run the importer somewhere that never sleeps, and shorten the import
interval. Neither removes the destination's own polling delay.

---

## Risks worth your attention

- **Vrbo's refresh is not immediate.** Documented at 30 minutes, observed at
  several hours, worst case around 12. Nothing here makes it faster.
- **Verification is indirect.** Confirmation comes from Vrbo's own export
  showing the nights blocked. Until then the status stays honest about not
  knowing.
- **The feed URL is a bearer secret.** If it leaks, rotate it.
- **A disconnected inbound feed blocks removals.** Booking.com is currently
  disconnected, so the safeguards will refuse any publication that *removes*
  previously published dates until it is reconnected or the state is settled.
  Additions — which is all this test does — are unaffected.
