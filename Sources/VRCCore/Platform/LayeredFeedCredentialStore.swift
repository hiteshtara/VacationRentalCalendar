import Foundation

/// Reads from a new store, falling back to an old one. Writes only to the new.
///
/// This is what makes the move to the data protection Keychain additive and
/// reversible rather than a flag day. A credential that has not been migrated
/// is still readable; one that has been is preferred; and the legacy entry is
/// never written to or deleted, so rolling back is a one-line change of which
/// store gets constructed.
///
/// The read order matters in one direction only. **The new store wins.** If
/// the legacy value won, a migrated credential would keep being served from
/// the old item and the migration would be a silent no-op — a failure shape
/// this project has shipped twice already.
///
/// A failure in either layer falls through to the other rather than
/// propagating. During migration the new store may be unusable — no
/// entitlement, no profile, wrong team — and the app has to keep working on
/// the legacy credential instead of reporting everything broken.
public struct LayeredFeedCredentialStore: FeedCredentialStore {
    public let primary: FeedCredentialStore
    public let fallback: FeedCredentialStore

    public init(primary: FeedCredentialStore, fallback: FeedCredentialStore) {
        self.primary = primary
        self.fallback = fallback
    }

    public var storageDescription: String {
        "\(primary.storageDescription), falling back to \(fallback.storageDescription)"
    }

    public func save(url: String, reference: String) throws {
        // Never the fallback. That entry is the rollback.
        try primary.save(url: url, reference: reference)
    }

    public func url(reference: String) throws -> String? {
        // `try?` flattens String? to String?, so a throw and a genuine "no
        // value" look the same here — which is fine, because both mean "ask
        // the other layer".
        if let value = try? primary.url(reference: reference) { return value }
        return try fallback.url(reference: reference)
    }

    public func exists(reference: String) -> Bool {
        primary.exists(reference: reference) || fallback.exists(reference: reference)
    }

    /// Removes the migrated copy only. The legacy entry survives, which is how
    /// a rollback is completed without losing the thing being rolled back to.
    public func delete(reference: String) throws {
        try primary.delete(reference: reference)
    }
}

/// Decides which credential store production should use.
///
/// Kept separate from the stores themselves so the decision is testable and
/// states its own reasoning. The data protection Keychain is selected only
/// when the running code is actually signed by this team: without the
/// entitlement every call returns `-34018`, so selecting it in an unsigned
/// build would break every credential rather than upgrading it.
public enum CredentialStoreSelection {

    public static var shouldUseDataProtection: Bool {
        AppleTeam.runningCodeCanUseAccessGroup
    }

    /// Why, in words the diagnostics can print.
    public static var explanation: String {
        shouldUseDataProtection
            ? "signed by team \(AppleTeam.identifier) — using the data protection Keychain"
            : "not signed by team \(AppleTeam.identifier) — using the login Keychain. "
                + "The data protection Keychain needs an entitlement that only a "
                + "properly signed build carries."
    }
}
