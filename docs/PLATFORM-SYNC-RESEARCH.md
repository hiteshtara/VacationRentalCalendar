# What Airbnb, Vrbo and Booking.com actually support

Phase 4 research. **Nothing outbound is enabled in this project.** This
document exists so that any future decision to enable it is made on evidence
rather than optimism.

Last reviewed: 2026-11-08.

---

## Summary

| | Airbnb | Vrbo | Booking.com |
|---|---|---|---|
| Export your calendar as iCal | Yes | Yes | Yes |
| Import someone else's iCal URL | Yes | Yes | Yes |
| How often it re-reads an imported URL | ~every 3 hours | ~every 30 min–4 hours | ~every 2 hours |
| Manual "sync now" | Yes | Yes (incl. mobile) | Yes |
| What iCal carries | Dates only | Dates only | Dates only |
| Public write API for an individual host | **No** | **No** | **No** |
| Partner/channel-manager API | Yes, gated | Yes, gated | Yes, gated |

**The practical conclusion: there is no way for this app to write availability
to a platform.** All three reserve programmatic writes for approved channel
manager partners, which requires a commercial agreement, a certification
process and in most cases a minimum portfolio size. For an individual owner,
the only supported mechanism in both directions is iCal.

---

## What iCal can and cannot carry

iCal moves **availability and nothing else.** Prices, guest names, messages,
payouts and minimum-stay rules do not travel. That is a limitation, but for this
project it is also a feature: an outbound feed that physically cannot carry
guest data cannot leak any.

The more serious limitation is latency. Every platform polls on its own
schedule, and nothing you do makes it poll sooner except a manual refresh:

- Airbnb re-reads each imported calendar roughly every 3 hours.
- Vrbo documents 30 minutes, though observed delays run to several hours.
- Booking.com refreshes roughly every 2 hours.

Worst case across a pairing is therefore several hours, and reports of 12-hour
delays are common. **No iCal-based system, paid or free, offers real-time
double-booking protection.** A channel manager that charges a monthly fee and
syncs over iCal has exactly the same exposure this app does. Only a direct API
integration closes that window, and that is not available to individual hosts.

This matters for expectation-setting: the value here is *visibility and
control*, not elimination of double-booking risk.

---

## The asymmetry that drives this project

Each platform exports blocked dates with a label, and the labels are not
trustworthy in the way a sync tool would need:

**Airbnb** emits `SUMMARY:Airbnb (Not available)` for every unavailable range
that is not a booking — whether you blocked it yourself, or Airbnb blocked it
as a penalty after you cancelled a reservation. The observed export for this
owner's listing carries no `DESCRIPTION` at all. A confirmed booking, an owner
block and a cancellation penalty block are indistinguishable.

Confirmed Airbnb bookings *are* distinguishable, when present: they carry
`SUMMARY:Reserved` and a `DESCRIPTION` containing a reservation URL and the last
four digits of the guest's phone number. That is the one reliable positive
signal, and it is what this app keys on.

**Vrbo** emits `SUMMARY:Blocked` for blocks and `SUMMARY:Reserved` for bookings.
The observed export carries no description for blocks. The word "Reserved" is
reliable; "Blocked" tells you nothing about cause.

**Booking.com** is the worst case: its standard export labels **both** bookings
and owner blocks `CLOSED - Not available`. A `CLOSED` event is not evidence of
either, and this app treats it as unknown.

### Booking-window artefacts

All three platforms export the dates beyond the end of your booking window as
unavailable. These appear as very long blocks — 193 and 641 nights in the two
live feeds examined here. They are not holds, and propagating one destroys
months of sellable inventory in a single sync. The classifier flags any block of
90 nights or more and names the likely cause in the review queue.

---

## If outbound sync were ever enabled

It would work by **publishing a filtered `.ics` URL** that you paste into each
platform's calendar-import box. That is the only supported path. It would
require:

1. A reachable HTTPS endpoint serving the filtered feed (see
   [HOSTING-OPTIONS.md](HOSTING-OPTIONS.md)).
2. A separate feed per destination platform, since each should exclude its own
   events.
3. An unguessable URL per feed, because the feed reveals your occupancy
   pattern. Treat it exactly as the inbound URLs are treated here.
4. **The same export gate applied at serve time, not at generation time**, so a
   classification changed after a file was written cannot be served stale.

### Preconditions before switching it on

- The filtering rules verified against real data over at least one full booking
  cycle.
- The review queue empty, or every outstanding item understood.
- An audit of the generated feed, event by event, read by the owner.
- Explicit written approval. `OutboundSyncGate.isEnabled` is a hard-coded
  constant specifically so that enabling it is a deliberate code change under
  review, not a toggle someone clicks by accident.

### What must never be automated

Flipping an Airbnb cancellation block or an unknown block into an outbound feed
on the app's own judgement. If a future version adds any automatic
classification of blocks, the export gate must still require a human decision —
the two layers are deliberately independent so that a classifier bug cannot
become an inventory loss.

---

## Sources

- [Airbnb Calendar Synchronisation Explained: A 2026 Guide for Hosts](https://update247.cloud/resources/airbnb-calendar-synchronisation-explained-a-2026-guide-for-hosts)
- [How Airbnb's iCal Sync Actually Works: A Teardown](https://www.duskolicanin.com/blog/how-airbnb-ical-sync-works-teardown-2026)
- [Import a calendar to sync with Vrbo](https://help.vrbo.com/articles/How-do-I-import-my-iCal-or-Google-calendar)
- [How to Sync Airbnb and Booking.com Calendars (2026)](https://www.futurestay.com/read/how-to-sync-airbnb-and-booking-com-calendars)
- [How to Sync Your Airbnb and Vrbo Calendars (and Avoid Double-Bookings)](https://www.hostfully.com/blog/sync-airbnb-vrbo-calendars/)
- [What Is iCal Sync in Short-Term Rentals](https://www.airroi.com/glossary/ical-sync)

Direct observation of the owner's live Airbnb and Vrbo exports, 2026-11-08,
informs the per-platform label findings above.
