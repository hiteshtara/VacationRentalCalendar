import Foundation

public enum SyncOutcome: String, Codable, CaseIterable, Sendable {
    case success
    case failure
    case skipped
    /// The platform has revoked the credential, or the owner switched the feed
    /// off. Not an error to be retried — a settled state.
    case disconnected
}

/// Audit trail for one feed refresh. Kept so the owner can see what an import
/// changed, and so a bad feed response can be told apart from an empty calendar.
public struct SyncRun: Identifiable, Hashable, Sendable {
    public var id: Int64?
    public var listingID: Int64
    public var startedAt: Date
    public var finishedAt: Date?
    public var outcome: SyncOutcome
    public var httpStatus: Int?
    public var eventsSeen: Int
    public var eventsInserted: Int
    public var eventsUpdated: Int
    public var eventsTombstoned: Int
    public var eventsNeedingReview: Int
    public var errorMessage: String?

    public init(
        id: Int64? = nil,
        listingID: Int64,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        outcome: SyncOutcome = .success,
        httpStatus: Int? = nil,
        eventsSeen: Int = 0,
        eventsInserted: Int = 0,
        eventsUpdated: Int = 0,
        eventsTombstoned: Int = 0,
        eventsNeedingReview: Int = 0,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.listingID = listingID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.httpStatus = httpStatus
        self.eventsSeen = eventsSeen
        self.eventsInserted = eventsInserted
        self.eventsUpdated = eventsUpdated
        self.eventsTombstoned = eventsTombstoned
        self.eventsNeedingReview = eventsNeedingReview
        self.errorMessage = errorMessage
    }

    public var summaryLine: String {
        switch outcome {
        case .failure:
            return "Failed: \(errorMessage ?? "unknown error")"
        case .skipped:
            return "Skipped: \(errorMessage ?? "no URL configured")"
        case .disconnected:
            return "Disconnected: \(errorMessage ?? "the platform no longer accepts this URL")"
        case .success:
            var parts = ["\(eventsSeen) in feed"]
            if eventsInserted > 0 { parts.append("\(eventsInserted) new") }
            if eventsUpdated > 0 { parts.append("\(eventsUpdated) changed") }
            if eventsTombstoned > 0 { parts.append("\(eventsTombstoned) removed") }
            if eventsNeedingReview > 0 { parts.append("\(eventsNeedingReview) need review") }
            return parts.joined(separator: ", ")
        }
    }
}
