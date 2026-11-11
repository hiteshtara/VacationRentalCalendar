# Live migration runbook — Developer ID + data protection Keychain

**Status: awaiting explicit approval. Nothing in this document has been executed.**

| | |
|---|---|
| Build to install | `dist-developer-id/VacationRentalCalendar.app` |
| Commit | `acc0a2a` (clean tree), CFBundleVersion 96 |
| CDHash | `50eb2e030765dbb8ad5afed0d41a1212d2df1f90` |
| Signed by | `Developer ID Application: hitesh tara (26JLFSV9YS)` → Apple Root CA |
| Access group | `26JLFSV9YS.com.vacationrentalcalendar.shared` |
| Currently installed | `86c31a9`, local certificate, CDHash `092784bf…` |
| Preflight | `READY` — 0 blockers, 2026-11-11T13:48Z |

## What this fixes, and why a reinstall alone would not

Every refresh prompts because each credential's ACL carries a **partition list**
whose entries are `cdhash:` — one per binary. A rebuild changes the hash, so
every "Always Allow" grant stops matching. The installed build's hash is in
none of the lists. The cause is the self-signed certificate: it carries no team
identifier, so macOS has nothing stable to attribute the code to.

A Developer ID build gets `teamid:26JLFSV9YS`, and the data protection Keychain
has no ACLs or partitions at all — access is governed by the entitlement.
Measured on this machine: **ten consecutive rebuilds, no prompts, slowest read
0.25s** (`test-keychain-integration.sh`, case B).

## Fixes carried by this build

| | |
|---|---|
| `-25320` dark wake | `errSecInDarkWake` — the Mac woke under Power Nap with no screen for a dialog. Previously latched all three feeds overnight; now retryable. |
| Unknown status codes | **Reversed default**: retryable unless known-settled. Only `-25293` and `-25300` latch. |
| `-128` cancelled authorization | Retryable, with a 10-minute hold-off so retrying is not a stream of dialogs. |
| Migration completeness gate | Derived from the destination on every ask, so a half-finished run cannot read as finished. |
| Refresh queue | Per-feed progress; a queued request is never silently dropped. |
| Out-of-service check | An archived property's feeds are refused with a recorded skip, withdrawing nothing. |

Verified present in the signed binary (strings `nowhere to show the request`,
`known verdict about the saved URL`, `MIGRATION INCOMPLETE`), absent from the
installed build.

---

## Step 1 — Stop the GUI

```sh
osascript -e 'tell application "VacationRentalCalendar" to quit'
pgrep -lf "/Applications/VacationRentalCalendar.app/Contents/MacOS/" || echo stopped
```

**Stop if** any process remains. A credential read racing the migration is what
caused the 23:05 incident on 2026-11-10.

## Step 2 — Fresh backup, GUI stopped

```sh
./Scripts/backup-before-install.sh
```

Takes ~0.5s. Reads item **attributes only**, executes neither the app nor the
helper. Captures the database through `sqlite3 .backup` (never a file copy, so
the WAL is included), the installed bundle, the manifest with row counts, and
reference **names**.

**Stop unless** all four verifier lines pass: `integrity_check ok`, row counts
match, no feed URL anywhere, backup verified.

Record the directory it prints — it is the rollback target.

## Step 3 — Preflight: the 18 legacy items

```sh
./Scripts/preflight-migration.sh
```

**Stop unless it exits 0 and prints `READY`.** It asserts:

* 18 Keychain items under `com.vacationrentalcalendar.feed-url`
* all **6 active** present: `vrbo-5550554-v6`, `airbnb-1759472334611502986-v6`,
  `booking-17482435-v3`, `aws-access-key-id`, `aws-secret-access-key`,
  `feed-key-1-booking_com-v1`
* **12 historical** present (vrbo v1–v5, airbnb v1–v5, booking v1–v2)
* **no configured listing references a missing secret**
* 3 Test Cottage placeholders correctly excluded — unconfigured, not missing
* Developer ID signature, Apple Root CA chain, embedded profile, authorized
  access group, data protection selected
* backup integrity, and the preserved bundle matching the installed identity
* the data counts to compare against in step 9

## Step 4 — Install the Developer ID build

```sh
sudo cp -R dist-developer-id/VacationRentalCalendar.app /Applications/
codesign -d -r- /Applications/VacationRentalCalendar.app | grep designated
```

**Expect the designated requirement to change.** This is deliberate:

```
before: identifier "…app" and certificate root = H"5828da64…"
after:  identifier "…app" and anchor apple generic and … leaf[subject.OU] = "26JLFSV9YS"
```

The new requirement survives rebuilds *and* certificate renewal. It does not
satisfy the old one, which is why step 6 prompts.

**Stop if** `codesign --verify --deep --strict` fails.

## Step 5 — Confirm the new identity

```sh
/Applications/VacationRentalCalendar.app/Contents/MacOS/VacationRentalCalendar \
    --credential-store
```

**Stop unless** it prints `team-signed true`, `running-team 26JLFSV9YS`,
`data-protection true`, and the access group above. Reads no credential.

## Step 6 — Migrate

```sh
/Applications/VacationRentalCalendar.app/Contents/MacOS/VacationRentalCalendar \
    --migrate-credentials --dry-run     # review the plan first
/Applications/VacationRentalCalendar.app/Contents/MacOS/VacationRentalCalendar \
    --migrate-credentials
```

Enumerates the **Keychain**, not the database — three of the six active secrets
are referenced by no table, and a listings-driven migration would leave them
behind. Prints references, outcomes and digests. **Never a value.**

**Expect up to six one-time authorization prompts**, one per secret, because the
new identity is not yet on any legacy ACL. Approve each with *Always Allow*.
This is the only time it happens.

Stop conditions, each a distinct exit code:

| exit | meaning | action |
|---|---|---|
| 3 | not team-signed — nowhere to migrate to | stop; the wrong build is installed |
| 4 | a configured listing references a missing secret | **stop, nothing written** |
| 5 | the migration itself errored | stop; legacy untouched |
| 6 | **`MIGRATION INCOMPLETE`** | stop; see below |
| 0 | `migration complete — 18 of 18` | continue |

Any `sourceUnreadable` step means a **cancelled authorization**: that reference
carries no digest and **nothing was written** for it. Re-run step 6 and approve
the prompt. A `-34018` anywhere is an entitlement failure — stop and do not
retry; the build or profile is wrong.

## Step 7 — The Booking.com outbound token

`feed-key-1-booking_com-v1` is the one secret the application has never been
able to read: its ACL trusts only `/usr/bin/security`, partition `apple-tool:`.
It **cannot** be re-entered — Booking.com is already subscribed to the URL
containing it, so re-issuing means handing the platform a new URL.

Only needed if step 6 reported it `sourceUnreadable`:

```sh
security find-generic-password -s com.vacationrentalcalendar.feed-url \
    -a feed-key-1-booking_com-v1 -w \
  | /Applications/VacationRentalCalendar.app/Contents/MacOS/VacationRentalCalendar \
      --import-secret feed-key-1-booking_com-v1
```

One prompt, from the tool that is trusted. The value is **piped** — it never
reaches the screen, never becomes an argument (visible in `ps`, recorded in
shell history), and is never logged. Only a 12-character digest is printed. An
empty or whitespace-only value is **refused rather than written**, so a
cancelled read cannot destroy the credential. The write is verified by reading
it back and comparing digests, under the **same reference name**, so the URL
Booking.com holds does not change.

**Stop if** the digest does not verify.

## Step 8 — The completion gate

```sh
/Applications/VacationRentalCalendar.app/Contents/MacOS/VacationRentalCalendar \
    --migration-status
```

**Stop unless** it prints `migration complete — 18 of 18` and exits 0.

This is measured against the **destination**, not the layered store. Asking the
layer would always answer "present", because the legacy fallback holds
everything — which is exactly how a half-finished migration passes for a
finished one. Nothing is recorded anywhere, so the answer cannot go stale.

## Step 9 — Recover the three stale connection states

Only after step 8 reports complete. All three feeds are currently
`credential_unreadable`, latched by last night's dark-wake failures, and that
state is never retried.

```sh
for id in 1 2 3; do
  /Applications/VacationRentalCalendar.app/Contents/MacOS/vrc connection \
    --listing $id --state failing \
    --detail "Latch cleared after data protection migration; OSStatus -25320 on 2026-11-11 00:49 was dark wake, not a credential fault (HANDOFF 31)" \
    --actor assistant-on-owner-approval
done
```

**Append-only**: each call writes a new `listing_connection_events` row. No
existing row is altered or deleted, and the connection history keeps every
earlier entry.

**Correctly attributed**: `--actor assistant-on-owner-approval`, not `owner`.
The two rows at `2026-11-10 23:30:14` carry `actor owner` incorrectly — they
were my command, not yours. They are left exactly as written; correcting them
needs its own append-only entry and your separate approval.

`failing` rather than `connected`: claiming connected would assert a successful
read nobody has performed. This touches no credential and no reference.

## Step 10 — GUI-initiated imports

Open the app and click **Refresh** on each feed, waiting for each row to finish.

**Expect, and stop unless:**

| feed | HTTP | events |
|---|---|---|
| Airbnb | 200 | 7 |
| Vrbo | 200 | 3 |
| Booking.com | 200 | 2 |

**And no Keychain dialog at all.** A prompt here means the migration did not
take effect for that feed.

```sh
sqlite3 "$HOME/Library/Application Support/VacationRentalCalendar/VacationRentalCalendar.sqlite" \
  "SELECT id, listing_id, datetime(started_at,'unixepoch'), outcome, http_status,
          events_seen, events_tombstoned FROM sync_runs WHERE id > 335 ORDER BY id;"
```

**Stop if** `events_tombstoned` is anything but 0 on any run.

## Step 11 — Quit, relaunch, refresh again

Quit the app, reopen it, and refresh all three feeds again.

**Stop unless there is no Keychain prompt.** Then, to prove the class of bug is
gone rather than merely postponed:

```sh
./Scripts/package-developer-id.sh          # a NEW code hash
sudo cp -R dist-developer-id/VacationRentalCalendar.app /Applications/
```

Relaunch and refresh. **Still no prompt.** This is the step that distinguishes
this from every previous fix: the cdhash changed and access did not depend on it.

## Step 12 — Confirm nothing else moved

```sh
./Scripts/preflight-migration.sh    # section 5 prints the same counts
```

**Stop unless all of these are unchanged from step 3:**

| | expected |
|---|---|
| active events | 12 |
| classifications | 13 |
| decisions | 2, both `cancelled` |
| publication UIDs | 2 — `vrc-812d1978…`, `vrc-a5a1dbf5…` |
| audit rows | 10 |
| January reservation | `2027-01-04 → 01-12 Reserved` = `confirmed_reservation` |
| preparation nights | `01-03→04` and `01-12→13` = `unknown_unavailable` |
| Keychain items | 18, all 6 active readable |

Connection events will have **three new rows** from step 9 and nothing removed.

```sh
grep -n "isEnabled = false" Sources/VRCCore/Logic/ExportPolicy.swift
aws scheduler get-schedule --name vrc-staging-import       --query State --output text
aws scheduler get-schedule --name vrc-staging-hold-sweeper --query State --output text
```

**Stop unless** the gate is `false` and both schedules are `DISABLED`.

---

## Rollback

Verified in rehearsal (`Migration rehearsal`, 15 cases) and by
`test-keychain-integration.sh` case H.

**If the migration fails or behaves unexpectedly:**

1. Delete the data protection copies. `LayeredFeedCredentialStore` then falls
   through to the legacy entries, which the migration **copied from and never
   wrote to, moved, re-homed or deleted**, and refreshes continue as before.
2. Restore the previous application:
   ```sh
   sudo rm -rf /Applications/VacationRentalCalendar.app
   sudo cp -R "<backup>/VacationRentalCalendar.app" /Applications/
   codesign -d -r- /Applications/VacationRentalCalendar.app | grep designated
   ```
   **Expect** `certificate root = H"5828da64…"` — the preflight confirmed the
   preserved bundle's identity matches the installed one, so this is a copy.
3. Restore the database only if it is actually damaged:
   ```sh
   ./Scripts/backup-before-install.sh --restore "<backup>"
   ```
   It sets the existing database aside first, so the restore is itself
   reversible.

**What rollback preserves, by construction:** all 18 legacy Keychain entries,
every reference name, and therefore **the exact Booking.com feed URL the
platform is subscribed to**. No credential is re-entered and nothing is
rotated. `--migration-status` immediately reports incomplete again, because the
status is measured rather than recorded.

**What rollback does not undo:** the three connection-state rows from step 9.
They are append-only history; re-latching them would be another live write.

## Not covered

Notarization — the `vrc-notary` notarytool profile does not exist. Not needed
to install locally; needed before distributing to anyone else.
