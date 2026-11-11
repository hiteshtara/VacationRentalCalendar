import Foundation

/// Whether the move to the data protection Keychain actually finished.
///
/// `LayeredFeedCredentialStore` falls back to the legacy Keychain for anything
/// not yet migrated, which is what makes the move additive and reversible. It
/// also means a HALF-FINISHED migration looks exactly like a working app:
/// refreshes keep succeeding, served quietly from the old items, and nothing
/// says the job is incomplete. The owner would reasonably conclude it was done
/// — and then discover otherwise at the next rebuild, when the legacy grants
/// stop matching and the prompts come back.
///
/// So completion is not a flag anyone sets. It is **derived, every time it is
/// asked for**, by checking that every expected reference is actually present
/// in the destination. A marker written at the end of a run would be a claim;
/// this is a measurement.
///
/// Nothing here reads a legacy value, so it cannot prompt: it asks the
/// destination what it holds and compares names.
public struct MigrationCompleteness: Sendable, Equatable {

    /// Every reference the migration was supposed to carry.
    public let expected: [String]
    /// Those now present in the destination.
    public let copied: [String]
    /// Those still missing from it.
    public let outstanding: [String]

    public var isComplete: Bool { outstanding.isEmpty && !expected.isEmpty }

    /// Nothing has been migrated at all. Distinct from a partial run: this is
    /// the normal state before the migration, not a half-finished one.
    public var hasNotStarted: Bool { copied.isEmpty && !expected.isEmpty }

    public var isPartial: Bool { !copied.isEmpty && !outstanding.isEmpty }

    /// What the app should say about itself. Never "migrated" unless it is.
    public var headline: String {
        if expected.isEmpty { return "nothing to migrate" }
        if isComplete { return "migration complete — \(copied.count) of \(expected.count)" }
        if hasNotStarted { return "not migrated — using the legacy Keychain" }
        return "MIGRATION INCOMPLETE — \(copied.count) of \(expected.count) copied, "
            + "\(outstanding.count) still served from the legacy Keychain"
    }

    /// The detail a person needs in order to finish it, names only.
    public var detail: String {
        guard !outstanding.isEmpty else { return "" }
        return "still to copy: " + outstanding.joined(separator: ", ")
    }

    /// Derives the status by asking the destination what it holds.
    ///
    /// Uses `exists`, which reads attributes rather than values, so this is
    /// safe to call while drawing the interface and cannot raise a dialog.
    /// Verification that the right VALUE arrived happens at copy time, in
    /// `CredentialMigration.apply`, which compares digests before reporting
    /// success — this is the separate question of whether anything was missed.
    public static func evaluate(
        expected: [String], destination: FeedCredentialStore
    ) -> MigrationCompleteness {
        let names = expected.filter { !$0.isEmpty }
        let copied = names.filter { destination.exists(reference: $0) }.sorted()
        let outstanding = names.filter { !destination.exists(reference: $0) }.sorted()
        return MigrationCompleteness(
            expected: names.sorted(), copied: copied, outstanding: outstanding)
    }
}
