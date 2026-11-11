import Foundation

/// What a credential migration must carry, compared against what it would find
/// by looking only at the database.
///
/// This exists because of what an audit of the live Keychain on 2026-11-10
/// turned up: of the six active secrets, **only three have a database row.**
///
///   * the three feed URLs are referenced by `platform_listings.credential_ref`
///   * `aws-access-key-id` and `aws-secret-access-key` are fixed names that
///     appear in no table at all
///   * `feed-key-1-booking_com-v1`, the Booking.com outbound feed token, is in
///     the Keychain with **no row anywhere** — `feed_tokens` is empty
///
/// So a migration that enumerates listings, which is the obvious way to write
/// one, would move three secrets and silently leave three behind. The two AWS
/// keys would be the cloud service losing its credentials, and the outbound
/// token is not reproducible — it is the token Booking.com already subscribed
/// to, so losing it means re-issuing a URL to the platform.
///
/// The rule this encodes: **enumerate the SOURCE, not the database.** The
/// Keychain is the authority on what exists; the database only says what is
/// referenced. Anything in the Keychain under our service is migrated, and
/// anything referenced but absent is a stop condition rather than a warning.
public struct CredentialInventory: Sendable, Equatable {

    /// Referenced by the database and present in the Keychain. The
    /// uncontroversial set.
    public var referencedAndPresent: [String]

    /// Present in the Keychain but referenced by no table. **Must still be
    /// migrated** — this is where the AWS keys and the outbound feed token
    /// live, and it is exactly what a database-driven migration misses.
    public var presentButUnreferenced: [String]

    /// Referenced by the database but absent from the Keychain. A dangling
    /// reference: migrating cannot fix it and proceeding would hide it.
    public var referencedButMissing: [String]

    /// Everything a migration should attempt, in a stable order.
    public var toMigrate: [String] {
        (referencedAndPresent + presentButUnreferenced).sorted()
    }

    /// Whether a migration may proceed at all. A dangling reference means the
    /// database and the Keychain disagree, and that has to be understood
    /// before anything is copied.
    public var isSafeToMigrate: Bool { referencedButMissing.isEmpty }

    public init(
        referencedAndPresent: [String] = [],
        presentButUnreferenced: [String] = [],
        referencedButMissing: [String] = []
    ) {
        self.referencedAndPresent = referencedAndPresent
        self.presentButUnreferenced = presentButUnreferenced
        self.referencedButMissing = referencedButMissing
    }

    /// Compares what the database refers to with what the Keychain holds.
    ///
    /// Both lists are names only. No value is read to build this, which is why
    /// it is safe to run before a migration and before any approval.
    public static func compare(
        databaseReferences: [String],
        keychainReferences: [String]
    ) -> CredentialInventory {
        let referenced = Set(databaseReferences.filter { !$0.isEmpty })
        let present = Set(keychainReferences.filter { !$0.isEmpty })
        return CredentialInventory(
            referencedAndPresent: referenced.intersection(present).sorted(),
            presentButUnreferenced: present.subtracting(referenced).sorted(),
            referencedButMissing: referenced.subtracting(present).sorted()
        )
    }

    /// A summary safe to print: names and counts, never a value.
    public var summary: String {
        var lines = ["\(toMigrate.count) secret(s) to migrate"]
        if !presentButUnreferenced.isEmpty {
            lines.append("  \(presentButUnreferenced.count) held in the Keychain only, "
                + "which a database-driven migration would miss: "
                + presentButUnreferenced.joined(separator: ", "))
        }
        if !referencedButMissing.isEmpty {
            lines.append("  REFUSE: \(referencedButMissing.count) reference(s) point at "
                + "nothing: " + referencedButMissing.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}
