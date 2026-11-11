import Foundation
import VRCCore

/// A full-scale rehearsal of the data protection Keychain migration.
///
/// Every reference here is disposable and every value is an obvious fake. The
/// shape mirrors the live Keychain audited on 2026-11-10 — six active secrets
/// in four classes plus twelve superseded entries — because the thing worth
/// rehearsing is not "does one copy work" but "does the whole set arrive, and
/// what happens when part of it does not".
///
/// The live inventory is deliberately NOT read here. These tests prove the
/// mechanism; the live run is a separate, approved step.
public enum MigrationRehearsalTests {

    // MARK: - A stand-in for the live inventory, with nothing live in it

    /// The three feed URLs, shaped like the real references.
    static let activeFeeds = [
        "rehearsal-vrbo-0000000-v6",
        "rehearsal-airbnb-0000000000000000-v6",
        "rehearsal-booking-00000000-v3",
    ]
    /// The two AWS keys — fixed names, referenced by no table.
    static let awsKeys = ["rehearsal-aws-access-key-id", "rehearsal-aws-secret-access-key"]
    /// The outbound feed token — referenced by nothing at all.
    static let outboundToken = "rehearsal-feed-key-1-booking_com-v1"
    /// Superseded entries, which a rollback reads and so must travel too.
    static let historical: [String] = {
        var names: [String] = []
        names += ["rehearsal-vrbo-0000000"]
            + (2...5).map { "rehearsal-vrbo-0000000-v\($0)" }
        names += ["rehearsal-airbnb-0000000000000000"]
            + (2...5).map { "rehearsal-airbnb-0000000000000000-v\($0)" }
        names += ["rehearsal-booking-00000000", "rehearsal-booking-00000000-v2"]
        return names
    }()

    static var allReferences: [String] {
        activeFeeds + awsKeys + [outboundToken] + historical
    }

    /// An obvious fake, distinct per reference so a mix-up is detectable.
    static func fakeValue(for reference: String) -> String {
        "https://example.invalid/not-a-real-credential/\(reference).ics"
    }

    static func seededLegacy() throws -> InMemoryFeedCredentialStore {
        let store = InMemoryFeedCredentialStore()
        for reference in allReferences {
            try store.save(url: fakeValue(for: reference), reference: reference)
        }
        return store
    }

    /// A source whose reads are cancelled for named references, the way a
    /// dismissed — or unpresentable — Keychain dialog returns -128.
    final class CancellingSourceStore: FeedCredentialStore, @unchecked Sendable {
        private let cancelling: Set<String>
        private let values: [String: String]
        init(cancelling: Set<String>, values: [String: String]) {
            self.cancelling = cancelling
            self.values = values
        }
        var storageDescription: String { "cancelling source" }
        func save(url: String, reference: String) throws {}
        func delete(reference: String) throws {}
        func exists(reference: String) -> Bool { values[reference] != nil }
        func url(reference: String) throws -> String? {
            if cancelling.contains(reference) {
                throw FeedCredentialError.keychainFailure(
                    KeychainFailure.userCanceled, "read")
            }
            return values[reference]
        }
    }

    /// A destination that refuses a named set of references, so a partial
    /// failure can be rehearsed rather than imagined.
    final class SelectivelyRefusingStore: FeedCredentialStore, @unchecked Sendable {
        private let inner = InMemoryFeedCredentialStore()
        private let refuse: Set<String>
        init(refusing: Set<String>) { self.refuse = refusing }
        var storageDescription: String { "rehearsal destination" }
        func save(url: String, reference: String) throws {
            guard !refuse.contains(reference) else {
                throw FeedCredentialError.keychainFailure(-34018, "add")
            }
            try inner.save(url: url, reference: reference)
        }
        func url(reference: String) throws -> String? { try inner.url(reference: reference) }
        func delete(reference: String) throws { try inner.delete(reference: reference) }
        func exists(reference: String) -> Bool { inner.exists(reference: reference) }
    }

    public static var cases: [TestCase] { [

        // MARK: - Requirement 3 & 8: the whole set arrives

        TestCase(group: "Migration rehearsal",
                 name: "all 18 references migrate in one run") { expect in
            let legacy = try seededLegacy()
            let modern = InMemoryFeedCredentialStore()
            expect.equal(allReferences.count, 18, "the rehearsal set matches the live shape")

            let plan = try CredentialMigration.plan(
                references: allReferences, from: legacy, to: modern)
            expect.equal(plan.filter { $0.outcome == .willMigrate }.count, 18)

            let result = try CredentialMigration.apply(plan, from: legacy, to: modern)
            expect.equal(result.migrated, 18)
            expect.equal(result.failed, 0)
            for reference in allReferences {
                expect.equal(try modern.url(reference: reference), fakeValue(for: reference),
                             "\(reference) arrived intact")
            }
        },

        TestCase(group: "Migration rehearsal",
                 name: "all four secret classes arrive, not just the feed URLs") { expect in
            // The trap the live audit found: three of six active secrets are
            // referenced by no table, so a listings-driven migration misses
            // them. Asserted class by class.
            let legacy = try seededLegacy()
            let modern = InMemoryFeedCredentialStore()
            _ = try CredentialMigration.apply(
                try CredentialMigration.plan(
                    references: allReferences, from: legacy, to: modern),
                from: legacy, to: modern)

            for feed in activeFeeds { expect.ok(modern.exists(reference: feed), feed) }
            for key in awsKeys { expect.ok(modern.exists(reference: key), key) }
            expect.ok(modern.exists(reference: outboundToken),
                      "the outbound feed token is not reproducible — it must travel")
            expect.equal(historical.count, 12)
            for old in historical { expect.ok(modern.exists(reference: old), old) }
        },

        TestCase(group: "Migration rehearsal",
                 name: "the legacy store is untouched, so rollback stays possible") { expect in
            // Requirement 6. Migration COPIES. Nothing is moved, deleted or
            // re-homed, and no reference name changes — which is what keeps
            // the existing Booking.com feed URL exactly as the platform has it.
            let legacy = try seededLegacy()
            let modern = InMemoryFeedCredentialStore()
            _ = try CredentialMigration.apply(
                try CredentialMigration.plan(
                    references: allReferences, from: legacy, to: modern),
                from: legacy, to: modern)

            for reference in allReferences {
                expect.equal(try legacy.url(reference: reference), fakeValue(for: reference),
                             "\(reference) still readable from the legacy store")
            }
        },

        // MARK: - Requirement 7: partial failure

        TestCase(group: "Migration rehearsal",
                 name: "a partial failure is reported per reference, and loses nothing") { expect in
            // Three of eighteen refused, the way an entitlement problem would
            // refuse: -34018. The run must not claim success, must say how
            // many failed, and must leave every source value intact.
            let refused: Set<String> = [activeFeeds[1], awsKeys[0], outboundToken]
            let legacy = try seededLegacy()
            let modern = SelectivelyRefusingStore(refusing: refused)

            let result = try CredentialMigration.apply(
                try CredentialMigration.plan(
                    references: allReferences, from: legacy, to: modern),
                from: legacy, to: modern)

            expect.equal(result.failed, 3, "the refusals are counted, not swallowed")
            expect.equal(result.migrated, 15)
            for reference in refused {
                expect.ok(!modern.exists(reference: reference),
                          "\(reference) did not arrive")
                expect.equal(try legacy.url(reference: reference), fakeValue(for: reference),
                             "and is still safe in the legacy store")
            }
        },

        TestCase(group: "Migration rehearsal",
                 name: "retrying after a partial failure completes the set") { expect in
            // The recovery path: fix the cause, run again. Already-migrated
            // references are left alone rather than rewritten.
            let refused: Set<String> = [activeFeeds[1], outboundToken]
            let legacy = try seededLegacy()
            let failing = SelectivelyRefusingStore(refusing: refused)
            _ = try CredentialMigration.apply(
                try CredentialMigration.plan(
                    references: allReferences, from: legacy, to: failing),
                from: legacy, to: failing)

            // Second attempt against a destination that accepts everything.
            let modern = InMemoryFeedCredentialStore()
            for reference in allReferences where failing.exists(reference: reference) {
                try modern.save(url: fakeValue(for: reference), reference: reference)
            }
            let plan = try CredentialMigration.plan(
                references: allReferences, from: legacy, to: modern)
            expect.equal(plan.filter { $0.outcome == .willMigrate }.count, refused.count,
                         "only the ones that failed are planned again")
            expect.equal(plan.filter { $0.outcome == .alreadyPresent }.count,
                         18 - refused.count)

            let result = try CredentialMigration.apply(plan, from: legacy, to: modern)
            expect.equal(result.migrated, refused.count)
            expect.equal(result.failed, 0)
            for reference in allReferences {
                expect.ok(modern.exists(reference: reference), reference)
            }
        },

        // MARK: - Requirement 7: repeated migration

        TestCase(group: "Migration rehearsal",
                 name: "running the migration twice changes nothing the second time") { expect in
            let legacy = try seededLegacy()
            let modern = InMemoryFeedCredentialStore()
            _ = try CredentialMigration.apply(
                try CredentialMigration.plan(
                    references: allReferences, from: legacy, to: modern),
                from: legacy, to: modern)

            let second = try CredentialMigration.plan(
                references: allReferences, from: legacy, to: modern)
            expect.equal(second.filter { $0.outcome == .alreadyPresent }.count, 18)
            let result = try CredentialMigration.apply(second, from: legacy, to: modern)
            expect.equal(result.migrated, 0, "nothing was rewritten")
            expect.equal(result.alreadyPresent, 18)
            expect.equal(result.failed, 0)
        },

        // MARK: - Requirement 7: missing credentials

        TestCase(group: "Migration rehearsal",
                 name: "a reference with nothing behind it is not a failure") { expect in
            // An unconfigured listing's placeholder. Reported as such, and it
            // must not make the run look broken.
            let legacy = try seededLegacy()
            let modern = InMemoryFeedCredentialStore()
            let withPlaceholders = allReferences + ["rehearsal-never-configured-p2"]

            let plan = try CredentialMigration.plan(
                references: withPlaceholders, from: legacy, to: modern)
            expect.equal(plan.filter { $0.outcome == .notConfigured }.count, 1)

            let result = try CredentialMigration.apply(plan, from: legacy, to: modern)
            expect.equal(result.migrated, 18)
            expect.equal(result.notConfigured, 1)
            expect.equal(result.failed, 0, "an absent placeholder is not a failure")
        },

        TestCase(group: "Migration rehearsal",
                 name: "an unreadable source is named, never guessed at or emptied") { expect in
            // The state a cdhash-partitioned item is in for a rebuilt app. It
            // must be reported for re-entry — never copied as an empty value,
            // which would destroy the credential while appearing to succeed.
            let backing = InMemoryFeedCredentialStore()
            try backing.save(url: fakeValue(for: "r"), reference: "r")
            let unreadable = UnreadableFeedCredentialStore(presentReferences: ["r"])
            let modern = InMemoryFeedCredentialStore()

            let plan = try CredentialMigration.plan(
                references: ["r"], from: unreadable, to: modern)
            expect.equal(plan.first?.outcome, .sourceUnreadable)
            _ = try CredentialMigration.apply(plan, from: unreadable, to: modern)
            expect.ok(!modern.exists(reference: "r"),
                      "nothing was written for an unreadable source")
        },

        // MARK: - Requirement 6: rollback

        TestCase(group: "Migration rehearsal",
                 name: "rollback removes the copies and leaves every legacy secret") { expect in
            let legacy = try seededLegacy()
            let modern = InMemoryFeedCredentialStore()
            _ = try CredentialMigration.apply(
                try CredentialMigration.plan(
                    references: allReferences, from: legacy, to: modern),
                from: legacy, to: modern)

            // The rollback: discard the destination copies.
            for reference in allReferences { try modern.delete(reference: reference) }

            for reference in allReferences {
                expect.ok(!modern.exists(reference: reference), "copy gone: \(reference)")
                expect.equal(try legacy.url(reference: reference), fakeValue(for: reference),
                             "legacy intact: \(reference)")
            }
        },

        TestCase(group: "Migration rehearsal",
                 name: "after a rollback the layered store serves the legacy copy again") { expect in
            // What the application actually does on rollback: the data
            // protection store is empty, so the layered store falls through to
            // the legacy one and refreshes keep working.
            let legacy = try seededLegacy()
            let modern = InMemoryFeedCredentialStore()
            let layered = LayeredFeedCredentialStore(primary: modern, fallback: legacy)

            _ = try CredentialMigration.apply(
                try CredentialMigration.plan(
                    references: allReferences, from: legacy, to: modern),
                from: legacy, to: modern)
            expect.equal(try layered.url(reference: activeFeeds[0]),
                         fakeValue(for: activeFeeds[0]), "served from the new store")

            for reference in allReferences { try modern.delete(reference: reference) }
            expect.equal(try layered.url(reference: activeFeeds[0]),
                         fakeValue(for: activeFeeds[0]),
                         "and still served after rollback, from legacy")
        },

        TestCase(group: "Migration rehearsal",
                 name: "no reference name changes, so no platform URL changes") { expect in
            // Requirement 6's second half. A changed reference would mean a
            // re-homed credential; a re-issued Booking.com token would mean
            // handing the platform a new URL. Neither happens: the plan is
            // keyed by the same names throughout.
            let legacy = try seededLegacy()
            let modern = InMemoryFeedCredentialStore()
            let plan = try CredentialMigration.plan(
                references: allReferences, from: legacy, to: modern)
            expect.equal(plan.map(\.reference).sorted(), allReferences.sorted())
            _ = try CredentialMigration.apply(plan, from: legacy, to: modern)
            expect.equal(try modern.url(reference: outboundToken),
                         try legacy.url(reference: outboundToken),
                         "the outbound token is byte-identical under the same name")
        },

        // MARK: - Requirement 1: a cancelled authorization mid-run

        TestCase(group: "Migration rehearsal",
                 name: "a cancelled Keychain authorization migrates nothing for that reference") { expect in
            // The realistic interruption. Migrating under the Developer ID
            // identity prompts once per legacy secret, and the owner may
            // dismiss one — or macOS may fail to present it. Either way the
            // read returns -128 and the value is unknown. It must be reported
            // for a retry and NOT written, because writing what was not read
            // would replace a credential with nothing.
            let cancelling = CancellingSourceStore(
                cancelling: [activeFeeds[1], outboundToken], values: allReferences.reduce(
                    into: [:]) { $0[$1] = fakeValue(for: $1) })
            let modern = InMemoryFeedCredentialStore()

            let plan = try CredentialMigration.plan(
                references: allReferences, from: cancelling, to: modern)
            let cancelled = plan.filter { $0.outcome == .sourceUnreadable }
            expect.equal(cancelled.count, 2, "both cancellations are reported")
            expect.equal(Set(cancelled.map(\.reference)),
                         [activeFeeds[1], outboundToken])
            for step in cancelled {
                expect.equal(step.sourceDigest, nil,
                             "no digest can exist for a value that was not read")
            }

            let result = try CredentialMigration.apply(plan, from: cancelling, to: modern)
            expect.equal(result.migrated, 16)
            expect.ok(!modern.exists(reference: activeFeeds[1]),
                      "nothing was written for the cancelled read")
            expect.ok(!modern.exists(reference: outboundToken))
        },

        TestCase(group: "Migration rehearsal",
                 name: "a run interrupted by cancellations is reported INCOMPLETE") { expect in
            // Requirement 7 joined to requirement 1. After the partial run the
            // app must not describe itself as migrated, even though every
            // refresh would still work through the fallback.
            let cancelling = CancellingSourceStore(
                cancelling: [activeFeeds[1]], values: allReferences.reduce(
                    into: [:]) { $0[$1] = fakeValue(for: $1) })
            let modern = InMemoryFeedCredentialStore()
            _ = try CredentialMigration.apply(
                try CredentialMigration.plan(
                    references: allReferences, from: cancelling, to: modern),
                from: cancelling, to: modern)

            let status = MigrationCompleteness.evaluate(
                expected: allReferences, destination: modern)
            expect.ok(!status.isComplete)
            expect.contains(status.headline, "MIGRATION INCOMPLETE")
            expect.equal(status.outstanding, [activeFeeds[1]])

            // And the retry finishes it, once the authorization is given.
            let willing = InMemoryFeedCredentialStore()
            for reference in allReferences {
                try willing.save(url: fakeValue(for: reference), reference: reference)
            }
            _ = try CredentialMigration.apply(
                try CredentialMigration.plan(
                    references: allReferences, from: willing, to: modern),
                from: willing, to: modern)
            expect.ok(MigrationCompleteness.evaluate(
                expected: allReferences, destination: modern).isComplete,
                "the retry completed the set")
        },

        // MARK: - Requirement 4: the database is not part of this

        TestCase(group: "Migration rehearsal",
                 name: "migration cannot touch the database at all") { expect in
            // Connection states, classifications, reservations, decisions and
            // audit history are all in SQLite. The migration must be unable to
            // affect them — asserted structurally rather than by checking
            // afterwards, because "it did not this time" is not a property.
            guard let source = try? String(
                contentsOfFile: "Sources/VRCCore/Platform/CredentialMigration.swift",
                encoding: .utf8) else {
                return expect.fail("cannot read CredentialMigration.swift")
            }
            for forbidden in ["Repository", "Database", "DataStore", "RentalStore",
                              "setConnectionState", "recordSync", "INSERT", "UPDATE"] {
                expect.ok(!source.contains(forbidden),
                          "CredentialMigration must not reference \(forbidden)")
            }
            // Its whole surface is credential stores.
            expect.contains(source, "from source: FeedCredentialStore")
            expect.contains(source, "to destination: FeedCredentialStore")
        },

        TestCase(group: "Migration rehearsal",
                 name: "a plan can be reviewed without exposing any value") { expect in
            // The plan is printed during a migration, so it must be printable.
            let legacy = try seededLegacy()
            let modern = InMemoryFeedCredentialStore()
            let plan = try CredentialMigration.plan(
                references: allReferences, from: legacy, to: modern)
            let printed = plan.map(\.description).joined(separator: "\n")
            expect.ok(!printed.contains("example.invalid"),
                      "no value may appear in a plan")
            expect.ok(!printed.contains("https://"))
            expect.contains(printed, outboundToken)
        },
    ] }
}
