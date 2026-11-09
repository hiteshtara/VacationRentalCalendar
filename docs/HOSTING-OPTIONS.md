# Serving a filtered feed when your Mac is asleep

Phase 4 research. **Nothing here is implemented.** This is the honest answer to
a problem the app cannot solve on its own.

---

## The problem

The app produces a filtered `.ics` file on your Mac. For Vrbo or Booking.com to
*use* it, they have to fetch it from the public internet, on their own schedule,
every few hours — including at 03:00 when your Mac is shut, asleep, on a
different network, or behind your home router's NAT.

**A local Mac application cannot provide a continuously reachable feed.** No
amount of cleverness in the app changes that. Something that is always on has to
serve the file.

Note also: if the feed is unreachable when a platform polls it, the platform
does not block the dates — it keeps whatever it had. An intermittent feed is not
dangerous, just ineffective. The failure mode is stale availability, not
corruption.

---

## The options, cheapest first

### 0. Do not publish at all — just use the app as a monitor

**Cost: nothing. Effort: nothing. This is the current state.**

You keep one unified calendar, conflict warnings, and the classification
record. When you need to block dates elsewhere, you block them by hand on that
platform, having seen in the Export screen exactly which dates qualify.

For a small number of properties with a handful of bookings a month, this is
genuinely the right answer. The manual step is a few minutes, and you retain
total control. Given the several-hour latency of iCal in any case, you are
giving up less than it sounds.

**Recommended until the filtering rules have been watched over a real booking
cycle.**

---

### 1. iCloud Drive public link

**Cost: nothing (within your existing iCloud storage). Effort: low.
Reliability: poor.**

Write the `.ics` into iCloud Drive and share a public link.

The problem: iCloud's share links serve an HTML landing page rather than raw
file bytes, and the URL form is not stable or guaranteed. Platforms' iCal
importers generally choke on it. **Not recommended** — listed because it is the
first thing people try.

---

### 2. A static-hosting free tier

**Cost: nothing at small scale. Effort: low. Reliability: good.**

Cloudflare Pages, Netlify or GitHub Pages will serve a static file over HTTPS.
The app writes the `.ics`, a small script commits or uploads it, and the
platforms fetch it from a stable URL.

- **Cloudflare Pages / Netlify** — free tiers comfortably cover a few small
  files refreshed hourly. Deploy via their CLI from a `launchd` job.
- **GitHub Pages** — works, but **only from a public repository** on the free
  tier. Your occupancy calendar would be world-readable and indexed. Use a
  private repo with Cloudflare Pages instead, or pay for GitHub Pages on a
  private repo.

Caveat: the upload only happens when your Mac is awake, so the file served is as
fresh as your last upload. That is usually fine — the platforms only poll every
few hours anyway — but a booking made while your Mac is off will not propagate
until it wakes.

**Best value if you want publishing at all.**

---

### 3. A small always-on machine you already own

**Cost: nothing extra if you have one. Effort: medium. Reliability: good.**

A Raspberry Pi, an old Mac mini, or a NAS on your home network, serving the file
through a Cloudflare Tunnel so you do not have to open a router port or hold a
static IP. The Mac app syncs the file to it.

Keeps everything on hardware you control. Costs an evening to set up and a small
amount of ongoing attention.

---

### 4. A cheap VPS

**Cost: roughly $4–6/month. Effort: medium. Reliability: very good.**

Hetzner, DigitalOcean or Fly.io running nginx over a directory the Mac rsyncs
into. Always on, properly reachable, entirely yours.

This is the "do it properly" option, and it is still an order of magnitude
cheaper than a channel-manager subscription. It is more infrastructure than a
two-property operation really needs.

---

### 5. Object storage with a signed URL

**Cost: pennies per month. Effort: medium. Reliability: very good.**

Cloudflare R2 (no egress fees) or S3, with the file at an unguessable key. The
Mac uploads on change. No server to patch, no machine to keep alive.

Mechanically the best fit for "one small file, read occasionally by robots". R2's
free tier covers this use entirely.

---

### What to avoid

- **Anything with a guessable URL.** The feed reveals when your property is
  occupied, which is when you are likely not there. Treat the published URL as
  a secret, exactly as the inbound URLs are treated.
- **A public GitHub repository.** See above.
- **Re-exposing your platform feed URLs.** Publishing is for the *filtered*
  output only. The Airbnb and Vrbo URLs never leave the Keychain.

---

## Recommendation

**Stay on option 0 for now.** Watch the Export screen over a real booking cycle
and confirm that what it proposes to share matches what you would have shared by
hand. The point of this project was never to automate the sharing — it was to
stop the *wrong* dates from being shared. That goal is met today, with no
hosting at all.

If and when you want publishing, **Cloudflare R2 or Cloudflare Pages** is the
right first step: free at this scale, HTTPS by default, no machine to maintain.

Whichever you choose, the export gate must run at serve time rather than at
file-generation time, so that a classification you change is reflected in the
next poll rather than in whatever was last written to disk.
