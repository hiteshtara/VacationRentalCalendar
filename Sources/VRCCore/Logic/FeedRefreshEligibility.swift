import Foundation

/// Whether importing one feed is still worth doing.
///
/// Asked twice, for two different reasons. Once when the owner clicks Refresh,
/// and again when a queued request finally reaches the front — because a feed
/// can wait in `FeedRefreshQueue` for as long as the imports ahead of it take,
/// and in that time the owner may have archived the property or disconnected
/// the feed. Acting on the stale request would import against something they
/// had just taken out of service.
///
/// Deliberately a decision about state alone: it reads no Keychain, opens no
/// network connection and touches no database. Whether a credential is present
/// is passed in, because only the repository can answer that.
public enum FeedRefreshEligibility: Sendable, Equatable {
    case runnable
    /// The property is archived, or no longer exists at all.
    case propertyArchived
    /// The feed's connection state forbids it. A revoked or unreadable
    /// credential is never retried: the read cannot succeed, and attempting it
    /// blocks every later Keychain call in this process.
    case notConnected(FeedConnectionState)
    /// Nothing to fetch — no Keychain item and no stored URL.
    case noFeedURL

    public var canRun: Bool { self == .runnable }

    /// Why not, in words the owner sees. Empty when it can run.
    public var explanation: String {
        switch self {
        case .runnable:
            return ""
        case .propertyArchived:
            return "Not refreshed — the property is archived."
        case .notConnected(let state):
            return "Not refreshed — \(state.displayName.lowercased())."
        case .noFeedURL:
            return "Not refreshed — No calendar URL configured."
        }
    }

    /// The order of these checks decides only which reason is reported; the
    /// answer is no in every case. Archived comes first because it is the
    /// thing the owner changed most recently.
    public static func of(
        listing: PlatformListing,
        property: Property?,
        hasStoredCredential: Bool
    ) -> FeedRefreshEligibility {
        guard let property, !property.isArchived else { return .propertyArchived }
        guard listing.connectionState.shouldAttemptImport else {
            return .notConnected(listing.connectionState)
        }
        guard hasStoredCredential || listing.hasURL else { return .noFeedURL }
        return .runnable
    }
}
