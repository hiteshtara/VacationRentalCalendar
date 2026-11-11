import Foundation
import VRCCore

/// A half-finished migration must never pass for a finished one.
///
/// `LayeredFeedCredentialStore` falls back to the legacy Keychain for anything
/// not yet migrated — which is what makes the move reversible, and also what
/// makes a partial run invisible. Refreshes keep working, served quietly from
/// the old items, and the app looks migrated. The truth surfaces at the next
/// rebuild, when the legacy grants stop matching and the prompts return.
public enum MigrationCompletenessTests {

    static let all = (1...18).map { "rehearsal-ref-\($0)" }

    static func destination(holding references: [String]) throws -> InMemoryFeedCredentialStore {
        let store = InMemoryFeedCredentialStore()
        for reference in references {
            try store.save(url: "https://example.invalid/\(reference).ics", reference: reference)
        }
        return store
    }

    public static var cases: [TestCase] { [

        TestCase(group: "Migration completeness",
                 name: "all 18 copied is complete") { expect in
            let status = MigrationCompleteness.evaluate(
                expected: all, destination: try destination(holding: all))
            expect.ok(status.isComplete)
            expect.equal(status.outstanding, [])
            expect.contains(status.headline, "migration complete")
            expect.equal(status.detail, "")
        },

        TestCase(group: "Migration completeness",
                 name: "17 of 18 is NOT complete, and says so loudly") { expect in
            // The case that matters. One missed secret and the app must not
            // describe itself as migrated.
            let status = MigrationCompleteness.evaluate(
                expected: all, destination: try destination(holding: Array(all.dropLast())))
            expect.ok(!status.isComplete, "one outstanding reference is not complete")
            expect.ok(status.isPartial)
            expect.equal(status.outstanding, ["rehearsal-ref-18"])
            expect.contains(status.headline, "MIGRATION INCOMPLETE")
            expect.contains(status.headline, "17 of 18")
            expect.contains(status.detail, "rehearsal-ref-18")
        },

        TestCase(group: "Migration completeness",
                 name: "nothing copied is 'not migrated', not 'incomplete'") { expect in
            // Before the migration this is the normal state, and calling it
            // incomplete would cry wolf on every launch of a build that has
            // not been migrated yet.
            let status = MigrationCompleteness.evaluate(
                expected: all, destination: InMemoryFeedCredentialStore())
            expect.ok(status.hasNotStarted)
            expect.ok(!status.isPartial)
            expect.ok(!status.isComplete)
            expect.contains(status.headline, "not migrated")
        },

        TestCase(group: "Migration completeness",
                 name: "the status is derived, so it cannot go stale") { expect in
            // No flag is written anywhere. Deleting a copy immediately shows
            // as incomplete again — which is what makes a rollback honest.
            let store = try destination(holding: all)
            expect.ok(MigrationCompleteness.evaluate(
                expected: all, destination: store).isComplete)
            try store.delete(reference: all[3])
            let after = MigrationCompleteness.evaluate(expected: all, destination: store)
            expect.ok(!after.isComplete, "a removed copy is noticed at once")
            expect.equal(after.outstanding, [all[3]])
        },

        TestCase(group: "Migration completeness",
                 name: "a layered store serving from fallback is still incomplete") { expect in
            // Proof that a working app is not evidence of a finished
            // migration: every read succeeds through the fallback while the
            // status correctly reports nothing copied.
            let legacy = try destination(holding: all)
            let modern = InMemoryFeedCredentialStore()
            let layered = LayeredFeedCredentialStore(primary: modern, fallback: legacy)

            expect.ok(try layered.url(reference: all[0]) != nil,
                      "refreshes would keep working...")
            let status = MigrationCompleteness.evaluate(
                expected: all, destination: modern)
            expect.ok(!status.isComplete, "...but the migration is not done")
            expect.equal(status.copied.count, 0)
        },

        TestCase(group: "Migration completeness",
                 name: "completeness is measured against the destination, not the layer") { expect in
            // Asking the layered store would always say "present", because the
            // fallback holds everything. The question must be put to the new
            // store alone.
            let legacy = try destination(holding: all)
            let modern = try destination(holding: Array(all.prefix(6)))
            let layered = LayeredFeedCredentialStore(primary: modern, fallback: legacy)

            expect.equal(MigrationCompleteness.evaluate(
                expected: all, destination: layered).copied.count, 18,
                "asking the layer gives the wrong answer — this is the trap")
            expect.equal(MigrationCompleteness.evaluate(
                expected: all, destination: modern).copied.count, 6,
                "asking the destination gives the truth")
        },

        TestCase(group: "Migration completeness",
                 name: "an empty expectation is not silently 'complete'") { expect in
            let status = MigrationCompleteness.evaluate(
                expected: [], destination: InMemoryFeedCredentialStore())
            expect.ok(!status.isComplete, "an empty inventory proves nothing")
            expect.contains(status.headline, "nothing to migrate")
        },

        TestCase(group: "Migration completeness",
                 name: "the status never names a value, only references") { expect in
            let status = MigrationCompleteness.evaluate(
                expected: all, destination: try destination(holding: Array(all.dropLast(2))))
            for text in [status.headline, status.detail] {
                expect.ok(!text.contains("https://"), "no value may appear")
                expect.ok(!text.contains("example.invalid"))
            }
            expect.contains(status.detail, "rehearsal-ref-17")
        },
    ] }
}
