# Deployment checklist — synchronisation

Two columns, and the line between them is the point: **staging actions touch
nothing the owner depends on; live actions change what guests can book.**

Nothing in the right-hand column has been done.

## Safe in staging — no approval needed

| action | why it is safe |
|---|---|
| Run the Swift suite, parity, scanner | no network, no live data |
| Build `dist-developer-id/` | never touches `/Applications` |
| Render the timeline preview | offscreen, synthetic data, no window |
| Create disposable Keychain items prefixed `rehearsal-` | cannot name a production credential |
| Read the live database read-only (`mode=ro`) | no writes |
| Publish to a **staging** S3 prefix with throwaway tokens | no platform subscribes to it |
| Fetch our own staging feed over HTTP | we are the only consumer |
| Run `vrc` against `--memory` or a verified disposable `--database` | `RehearsalIsolation` refuses production |

## Requires explicit approval — changes live behaviour

| # | action | what it risks |
|---|---|---|
| 1 | **Mint destination tokens for 39 G Street** | creates AWS resources; a leaked token exposes a calendar |
| 2 | **Write real feeds to the production S3 prefix** | the object becomes fetchable by anyone holding the token |
| 3 | **Subscribe Airbnb / Vrbo to our URLs** | a live platform change; additive to the existing Booking.com links, never replacing them |
| 4 | **Change a declared publishing route** | duplicate blocks, or nights left uncovered |
| 5 | **Flip `OutboundSyncGate.isEnabled`** | a reviewed code change, never a UI toggle |
| 6 | **Approve an owner block for export** | withdraws sellable inventory on other platforms |
| 7 | **Approve a withdrawal** | reopens nights; the one irreversible direction |
| 8 | **Enable `vrc-staging-import` / `vrc-staging-hold-sweeper`** | the Mac stops being the only thing that can act |
| 9 | **Install any build** | replaces the working application |
| 10 | **Merge PR #13** | — |
| 11 | **Revoke or rotate a token** | breaks any platform currently subscribed to it |
| 12 | **Migrate credentials to the data protection Keychain** | separate, currently stopped |

## Order, if all of it is approved

1 → 2 → verify our own feed over HTTP → 3 (one destination first) → observe
one full polling cycle → confirm **Protected** from that platform's own
export → repeat for the second destination → 5 → 8.

Steps 6 and 7 stay per-item for ever; they are not a mode anything enters.

## Stop conditions

- any destination reports `coverageAttributionUnverified` after a full polling
  cycle — we cannot prove our block is what is holding the nights
- duplicate blocks appear over the same nights
- a token fetch returns anything but 200 for a token we expect to be live
- an existing Booking.com → Airbnb / Vrbo connection changes state
- any night that was Protected becomes uncovered

## What approval does not buy

Serving a feed is not evidence a platform read it. **Protected** requires that
platform's own export showing our UID over every night, while its feed is
current. Until then the status is Pending, however many 200s our endpoint has
returned.
