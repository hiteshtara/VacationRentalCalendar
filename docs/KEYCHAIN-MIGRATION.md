# Retiring the legacy Keychain architecture

**Audit, certificate prerequisites, and test plan — for approval before any
code or credential moves.**

Nothing in this document has been executed. No credential has been migrated,
no application rebuilt, no certificate created.

Target: the data protection Keychain, access group
`26JLFSV9YS.com.vacationrentalcalendar.shared`. Credentials stay encrypted by
the system and are never written in plaintext — the migration moves items
between two Keychains and writes nothing to disk.

---

## 1. Audit — every remaining dependency

### The good news: there is one seam

Every secret in this product goes through the `FeedCredentialStore` protocol,
and that protocol is constructed in **exactly one place**:

```
Sources/VRCCore/RentalStore.swift:118   KeychainFeedCredentialStore(
Sources/VRCCore/RentalStore.swift:119       additionalTrustedPaths: AppPaths.siblingExecutablePaths())
```

Swapping that single construction changes the storage for all four classes of
secret at once. There is no second path and no direct `SecItem*` call anywhere
outside the two store implementations.

### Legacy API uses — all confined to one type

| Location | API | Fate |
|---|---|---|
| `FeedCredentialStore.swift:106` | `SecTrustedApplicationCreateFromPath` | deleted with `makeAccess()` |
| `FeedCredentialStore.swift:114` | `SecAccessCreate` | deleted with `makeAccess()` |
| `FeedCredentialStore.swift:146` | `kSecAttrAccess` | deleted from `save()` |
| `AppPaths.swift:19` | `siblingExecutablePaths()` | **becomes dead** — it exists solely to feed the ACL |
| `Scripts/build-app.sh:155` | comment describing the scheme | rewrite |

`KeychainFeedCredentialStore` itself should be **kept**, not deleted: it is
the only way to read the old items during migration and the only way to roll
back. It becomes a migration-source type rather than the production store.

### The four secret classes, all on the same seam

| Class | References | Count |
|---|---|---|
| Platform feed URLs | `airbnb-…-v6`, `booking-17482435-v3`, `vrbo-5550554-v6` | 3 live |
| AWS credentials | `aws-access-key-id`, `aws-secret-access-key` | 2 |
| Outbound feed token | `feed-key-1-booking_com-v1` | 1 |
| Superseded versions | `-v1`…`-v5`, unversioned originals | 12 kept as history |

**6 live items must survive.** `FeedSnapshotRepository:180` writes the
outbound feed token through the same protocol, so it is covered — but it is
easy to miss when thinking only about "feed URLs", and losing it would mean
re-minting a token Booking.com already subscribes to.

### The dependency that is NOT obvious

**`/usr/bin/security` cannot see data protection Keychain items at all.** It
operates on the file Keychain and has no flag to do otherwise — confirmed:
its help text contains no mention of the data protection keychain.

Two scripts rely on it:

* `Scripts/backup-before-install.sh` — presence check per reference. After
  migration it would report every live credential as `MISSING`.
* `Scripts/migrate-cloud-credential.sh` — the "skip references with no
  credential" logic added today. After migration it would skip **everything**.

Both must move to a `vrc` subcommand that uses the same store the app uses.
This is the piece most likely to be forgotten, because both scripts would keep
*running* and simply report the wrong thing — the same failure mode as the
`vrc keychain` call that reported every migration as failed.

### Behaviour that must not be lost

* `DeadlineFeedCredentialStore` — keep. The data protection Keychain does not
  prompt, so the deadline should rarely fire, but a bound on a system call is
  not something to remove on the assumption it is now unnecessary.
* `databaseLeaksAnyKeychainURL()` — keep. It asserts no feed URL is ever in
  SQLite, which is independent of which Keychain is used.
* Reference naming and the `-vN` versioning — keep. The database points at
  references by name; changing them loses the pointer.

---

## 2. Certificate prerequisites — exactly what is needed

Team **26JLFSV9YS**, Individual enrolment.

### For the isolated test build (minimum to proceed)

**One certificate: `Apple Development` or `Developer ID Application`.**

Either is sufficient, because the test only needs the signature to carry a
`keychain-access-groups` entitlement. This is the single blocking item — a
probe on 2026-11-10 confirmed `SecItemAdd` to the data protection Keychain
returns **-34018, missing entitlement**, from an unsigned binary, with *and*
without an access group.

How, without Xcode:

1. **Keychain Access → Certificate Assistant → Request a Certificate From a
   Certificate Authority.** Enter your Apple ID email, leave CA Email blank,
   choose **Saved to disk**. Produces a `.certSigningRequest`.
2. **developer.apple.com → Certificates, Identifiers & Profiles → Certificates
   → +.** Choose **Developer ID Application** (preferred — it also serves
   distribution) or **Apple Development**. Upload the request.
3. Download the `.cer` and double-click to install into the login Keychain.
4. Verify: `security find-identity -v -p codesigning` must list it, and
   `./Scripts/package-developer-id.sh --preflight` must pass.

### Also required for Developer ID distribution

* **Developer ID Certification Authority** intermediate — from
  <https://www.apple.com/certificateauthority/>. Without it `codesign`
  succeeds and Gatekeeper refuses, which is confusing after the fact.
* **Notarization credentials**, once:
  `xcrun notarytool store-credentials vrc-notary --apple-id <id> --team-id 26JLFSV9YS`
  using an app-specific password from appleid.apple.com. Stored by macOS; this
  repository never sees it.

### Not required

* **No App ID or provisioning profile** for the Developer ID path on macOS —
  `keychain-access-groups` is honoured from the signature alone. A profile
  *is* required later for the App Store path.
* **No paid team membership beyond the one already active.**

---

## 3. Test plan

Run by `Scripts/test-keychain-integration.sh`, which exists and currently
skips with the reason above. Each item below is a test that must pass before
anything touches a live credential.

### A. The core claim — survives a rebuild

1. Build probe **A**, sign with the entitlement, write an item.
2. Build probe **B** from different source so its **code hash differs**, sign,
   read the item.
3. Assert the hashes genuinely differ, and that B reads A's value.

Under the old scheme step 3 fails. That failure is the entire reason for this
work.

### B. Repeated rebuilds

Ten build-sign-read cycles. Assert zero failures and **zero authorization
prompts** — measured by running with stdin closed and asserting no call blocks
beyond one second, since a prompt would hang.

### C. GUI and CLI share

Sign two *differently named* binaries with the same entitlement, as the bundle
does. One writes, the other reads, then reversed. This is the exact scenario
that failed on 2026-11-10 at 18:22, where the app could not read what its own
bundled helper had written.

### D. Restart

Write, log out and back in — or at minimum terminate and relaunch — read
again. `kSecAttrAccessibleAfterFirstUnlock` must make this silent.

### E. CPU load

Run C while the machine is saturated (`swift build` plus the Docker parity
run, which is what broke it today). Assert reads complete well inside
`DeadlineFeedCredentialStore.defaultTimeout` and that no timeout is recorded.
The 4-second bound failed this exact test in production today; 20 seconds is
the new bound and it should be measured, not assumed.

### F. Application update

Install build **A**, write credentials, install build **B** over it, read. No
prompt, no re-entry. This is the scenario that has cost the most time, and it
is the one a user actually experiences.

### G. Migration correctness

Against throwaway stores, already covered by 15 unit tests: readable sources
migrate, unreadable ones are reported rather than guessed at, never-configured
references are not failures, re-running is a no-op, the copy is read back
before being counted, source entries are never deleted, and plans print a
digest rather than a value.

### H. Rollback

After migrating, point `RentalStore` back at the legacy store and confirm all
six live credentials still read. This must pass **before** live migration, not
after.

---

## 4. Migration design

### One-time, additive, reversible

```
legacy file Keychain                data protection Keychain
  airbnb-…-v6          ──copy──▶      airbnb-…-v6
  booking-17482435-v3  ──copy──▶      booking-17482435-v3
  vrbo-5550554-v6      ──copy──▶      vrbo-5550554-v6
  aws-access-key-id    ──copy──▶      aws-access-key-id
  aws-secret-access-key──copy──▶      aws-secret-access-key
  feed-key-1-…-v1      ──copy──▶      feed-key-1-…-v1
  (12 superseded)          —          left where they are
```

* **References are unchanged.** The database points at them by name; changing
  a name loses the pointer.
* **Nothing is deleted.** Every legacy item stays exactly where it is, so
  rollback is a one-line change of store and no data movement at all.
* **Plan first, then apply.** `CredentialMigration.plan` writes nothing;
  `apply` reads each copy back before counting it migrated.
* **Idempotent.** A second run reports `alreadyPresent` for everything.

### Rollback

Point `RentalStore.makeDefault` at `KeychainFeedCredentialStore`. The legacy
items are untouched, so this is instantaneous and lossless. It should be
rehearsed as test H before the live migration, not discovered afterwards.

### Order of operations

1. Certificate installed, preflight passes.
2. `Scripts/test-keychain-integration.sh` passes A–F.
3. Replace the shell presence checks with a `vrc` subcommand, with tests.
4. Dry-run the plan against live credentials — **reads only, writes nothing**,
   prints six digests.
5. Fresh verified backup.
6. Apply, with the legacy store still intact behind it.
7. Verify real HTTP 200 imports and the January reservation.
8. Only after a stable period: consider deleting `makeAccess()`.

Steps 4 onward need separate approval.

---

## 5. Risks

| Risk | Mitigation |
|---|---|
| Entitlement wrong → every credential unreadable at once | Tests A–F run on throwaway items before any live item moves; legacy store stays as fallback |
| Scripts silently report nonsense after migration | Replace `security` presence checks with a `vrc` subcommand **before** migrating, with tests |
| Outbound feed token forgotten | Named explicitly above; Booking.com already subscribes to it, and re-minting would break that connection |
| Access group mismatch between signature and code | A test already asserts `AppleTeam.identifier` and `KeychainPolicy.groupSuffix` match `Scripts/apple-config.sh` and both entitlements files |
| Certificate expires | Developer ID certificates last five years; items are scoped to the **team**, not the certificate, so renewal does not orphan them |
