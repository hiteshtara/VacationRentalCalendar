import Foundation
import VRCCore
#if canImport(Security)
import Security
#endif

/// The replacement for the code-hash-pinned Keychain, tested in isolation.
///
/// What it replaces. `KeychainFeedCredentialStore` builds an access control
/// list with `SecTrustedApplicationCreateFromPath` and `SecAccessCreate`. That
/// list identifies code by its designated requirement, which for this project
/// has repeatedly meant the binary's code hash — so every rebuild orphans
/// every credential. It cost three separate debugging sessions on 2026-11-10
/// alone, and it is also unavailable to a sandboxed App Store build, where
/// items are scoped by ACCESS GROUP instead.
///
/// The replacement therefore has to satisfy two things at once: survive
/// rebuilds, and work inside the sandbox. A data protection keychain item with
/// an access group does both, because an access group is a property of the
/// signing TEAM, not of any particular binary.
///
/// Policy is kept separate from the Security framework on purpose. The rules —
/// which keychain, which access group, which accessibility class, never
/// synchronised, never an ACL — are decisions that can be asserted on any
/// platform. Translating them into `kSec*` dictionaries is Apple-only
/// plumbing, and is tested separately where it can run.
public enum KeychainModernisationTests {

    static let teamID = "A1B2C3D4E5"
    static var policy: KeychainPolicy {
        KeychainPolicy(teamID: teamID, service: "com.vacationrentalcalendar.feed-url")
    }

    public static var cases: [TestCase] { [

        // --- The policy -------------------------------------------------------

        TestCase(group: "Keychain modernisation",
                 name: "items go in the data protection keychain, not the file keychain") { expect in
            // The file keychain is where ACLs live. Everything else here
            // follows from not being in it.
            let spec = policy.spec(forReference: "airbnb-p1-v6")
            expect.ok(spec.usesDataProtectionKeychain)
            expect.ok(!spec.usesLegacyAccessControlList,
                      "an ACL is the thing being removed, not carried forward")
        },

        TestCase(group: "Keychain modernisation",
                 name: "access is scoped by team access group, never by binary") { expect in
            // The whole point: an access group belongs to the signing team, so
            // the app and its bundled helper share it and a rebuild changes
            // nothing.
            let spec = policy.spec(forReference: "airbnb-p1-v6")
            expect.equal(spec.accessGroup, "\(teamID).com.vacationrentalcalendar.shared")
            expect.contains(spec.accessGroup ?? "", teamID)
        },

        TestCase(group: "Keychain modernisation",
                 name: "the GUI and the helper resolve to the same access group") { expect in
            // If these ever differ, the two code objects stop sharing
            // credentials — which is exactly today's bug wearing a new hat.
            expect.equal(policy.spec(forReference: "r").accessGroup,
                         policy.spec(forReference: "r").accessGroup)
            expect.equal(KeychainPolicy(teamID: teamID, service: "s").accessGroup,
                         KeychainPolicy(teamID: teamID, service: "other").accessGroup,
                         "the group is a property of the team, not of the service")
        },

        TestCase(group: "Keychain modernisation",
                 name: "credentials never leave the device") { expect in
            // A feed URL is a bearer token for a whole booking calendar.
            // iCloud Keychain sync would put it on every device on the account
            // and in Apple's infrastructure; this is an explicit no.
            expect.ok(!policy.spec(forReference: "r").synchronizable)
        },

        TestCase(group: "Keychain modernisation",
                 name: "accessible after first unlock, not only while unlocked") { expect in
            // Imports run on a timer while the app is open but the screen may
            // be locked. `whenUnlocked` would fail those silently; `always`
            // would weaken it needlessly.
            expect.equal(policy.spec(forReference: "r").accessibility, .afterFirstUnlock)
        },

        TestCase(group: "Keychain modernisation",
                 name: "the reference is carried through untouched") { expect in
            // Migration depends on references being stable: the database
            // records them, and a changed one loses the pointer.
            for reference in ["airbnb-1759472334611502986-v6", "booking-17482435-v3",
                              "vrbo-5550554-v6"] {
                expect.equal(policy.spec(forReference: reference).account, reference)
            }
        },

        TestCase(group: "Keychain modernisation",
                 name: "a policy without a team identifier refuses to produce a group") { expect in
            // Fail loudly rather than silently writing ungrouped items that
            // only the creating binary can read — which is the old bug again.
            let unsigned = KeychainPolicy(teamID: "", service: "s")
            expect.ok(unsigned.spec(forReference: "r").accessGroup == nil)
            expect.ok(!unsigned.isUsable,
                      "an unusable policy must be detectable before anything is written")
            expect.ok(policy.isUsable)
        },

        // --- Migration, planned without touching anything ---------------------

        TestCase(group: "Keychain migration",
                 name: "a readable legacy credential is planned for migration") { expect in
            let legacy = InMemoryFeedCredentialStore()
            try legacy.save(url: "https://a.test/f.ics", reference: "airbnb-p1-v6")
            let plan = try CredentialMigration.plan(
                references: ["airbnb-p1-v6"], from: legacy, to: InMemoryFeedCredentialStore())
            expect.equal(plan.count, 1)
            expect.equal(plan.first?.outcome, .willMigrate)
        },

        TestCase(group: "Keychain migration",
                 name: "an unreadable legacy credential is reported, never guessed at") { expect in
            // The case that actually happens after a rebuild. It must be named
            // so the owner can re-enter it — not silently skipped, and
            // certainly not replaced with an empty entry.
            let legacy = UnreadableFeedCredentialStore(presentReferences: ["booking-v3"])
            let plan = try CredentialMigration.plan(
                references: ["booking-v3"], from: legacy, to: InMemoryFeedCredentialStore())
            expect.equal(plan.first?.outcome, .sourceUnreadable)
        },

        TestCase(group: "Keychain migration",
                 name: "a reference with nothing behind it is not a failure") { expect in
            // Test Cottage. Never configured is not the same as broken, and
            // conflating them made the diagnostics useless once already.
            let plan = try CredentialMigration.plan(
                references: ["airbnb-p2-test-cottage"],
                from: InMemoryFeedCredentialStore(), to: InMemoryFeedCredentialStore())
            expect.equal(plan.first?.outcome, .notConfigured)
        },

        TestCase(group: "Keychain migration",
                 name: "a credential already in the destination is left alone") { expect in
            // Migration must be repeatable. Running it twice is a no-op.
            let legacy = InMemoryFeedCredentialStore()
            try legacy.save(url: "https://a.test/f.ics", reference: "r")
            let modern = InMemoryFeedCredentialStore()
            try modern.save(url: "https://a.test/f.ics", reference: "r")
            let plan = try CredentialMigration.plan(references: ["r"], from: legacy, to: modern)
            expect.equal(plan.first?.outcome, .alreadyPresent)
        },

        TestCase(group: "Keychain migration",
                 name: "a plan carries no secret value, only a digest") { expect in
            // A plan is printed, logged and reasoned about. It must be safe to
            // look at: enough to prove the right value moved, never enough to
            // read a calendar.
            let legacy = InMemoryFeedCredentialStore()
            let url = "https://www.airbnb.com/calendar/ical/123.ics?s=secret"
            try legacy.save(url: url, reference: "r")
            let plan = try CredentialMigration.plan(
                references: ["r"], from: legacy, to: InMemoryFeedCredentialStore())
            let described = "\(plan)"
            expect.notContains(described, "secret")
            expect.notContains(described, url)
            expect.equal(plan.first?.sourceDigest, EventKey.sha256(url).prefix(12).description)
        },

        TestCase(group: "Keychain migration",
                 name: "applying a plan copies the value and keeps the original") { expect in
            // Nothing is deleted. If the new store turns out to be wrong, the
            // old entry is still there — the same rule the feed-URL migration
            // already follows.
            let legacy = InMemoryFeedCredentialStore()
            try legacy.save(url: "https://a.test/f.ics", reference: "r")
            let modern = InMemoryFeedCredentialStore()

            let applied = try CredentialMigration.apply(
                try CredentialMigration.plan(references: ["r"], from: legacy, to: modern),
                from: legacy, to: modern)

            expect.equal(applied.migrated, 1)
            expect.equal(try modern.url(reference: "r"), "https://a.test/f.ics")
            expect.equal(try legacy.url(reference: "r"), "https://a.test/f.ics",
                         "the original is preserved")
        },

        TestCase(group: "Keychain migration",
                 name: "applying verifies the copy and reports a mismatch") { expect in
            // A migration that says it worked and did not is the failure mode
            // this project has already been bitten by twice today.
            let legacy = InMemoryFeedCredentialStore()
            try legacy.save(url: "https://a.test/f.ics", reference: "r")
            let refusing = UnreadableFeedCredentialStore(presentReferences: [])

            let applied = try CredentialMigration.apply(
                try CredentialMigration.plan(references: ["r"], from: legacy, to: refusing),
                from: legacy, to: refusing)

            expect.equal(applied.migrated, 0)
            expect.equal(applied.failed, 1, "a copy that cannot be read back has not migrated")
        },

        TestCase(group: "Keychain migration",
                 name: "a mixed portfolio is planned per reference") { expect in
            // 39 G Street and Test Cottage as they actually stand: three
            // readable, three never configured.
            let legacy = InMemoryFeedCredentialStore()
            for reference in ["airbnb-p1-v6", "vrbo-p1-v6", "booking-p1-v3"] {
                try legacy.save(url: "https://a.test/\(reference).ics", reference: reference)
            }
            let plan = try CredentialMigration.plan(
                references: ["airbnb-p1-v6", "vrbo-p1-v6", "booking-p1-v3",
                             "airbnb-p2-test-cottage", "vrbo-p2-test-cottage",
                             "booking_com-p2-test-cottage"],
                from: legacy, to: InMemoryFeedCredentialStore())
            expect.equal(plan.filter { $0.outcome == .willMigrate }.count, 3)
            expect.equal(plan.filter { $0.outcome == .notConfigured }.count, 3)
            expect.equal(plan.filter { $0.outcome == .sourceUnreadable }.count, 0)
        },
        // --- The Security translation, where it can run ----------------------

        TestCase(group: "Keychain modernisation",
                 name: "the policy translates to the right Security attributes") { expect in
            #if canImport(Security)
            let query = DataProtectionFeedCredentialStore.query(
                for: policy.spec(forReference: "airbnb-p1-v6"))

            expect.equal(query[kSecUseDataProtectionKeychain as String] as? Bool, true,
                         "the data protection keychain, not the file keychain")
            expect.equal(query[kSecAttrAccessGroup as String] as? String,
                         "\(teamID).com.vacationrentalcalendar.shared")
            expect.equal(query[kSecAttrAccount as String] as? String, "airbnb-p1-v6")
            expect.equal(query[kSecAttrSynchronizable as String] as? Bool, false,
                         "never iCloud Keychain")
            expect.ok(query[kSecAttrAccessible as String] as? String
                        == kSecAttrAccessibleAfterFirstUnlock as String)
            expect.ok(query[kSecAttrAccess as String] == nil,
                      "no access control list — that is the whole point")
            #else
            expect.ok(true, "Security is Apple-only; the policy itself is asserted above")
            #endif
        },

        TestCase(group: "Keychain modernisation",
                 name: "an unusable policy refuses to write rather than writing ungrouped") { expect in
            #if canImport(Security)
            let store = DataProtectionFeedCredentialStore(
                policy: KeychainPolicy(teamID: "", service: "s"))
            expect.ok(!store.exists(reference: "r"))
            do {
                try store.save(url: "https://a.test/f.ics", reference: "r")
                expect.fail("a policy with no access group must refuse to write")
            } catch {}
            expect.contains(store.storageDescription, "UNUSABLE")
            #else
            expect.ok(true)
            #endif
        },
    ] }
}
