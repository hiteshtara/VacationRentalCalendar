import Foundation

/// What the owner wants done to a destination platform for a date range.
public enum AvailabilityAction: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Make the nights unavailable on the destination.
    case block
    /// Withdraw a block **this application created**. Never touches a block the
    /// platform itself imposed, and never touches a reservation.
    case unblock
    /// Explicitly do nothing. Recorded rather than implied, so "I considered
    /// Airbnb and chose to leave it alone" is distinguishable from "I forgot".
    case leaveUnchanged

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .block: return "Block"
        case .unblock: return "Remove our block"
        case .leaveUnchanged: return "Leave unchanged"
        }
    }

    public var verb: String {
        switch self {
        case .block: return "block"
        case .unblock: return "reopen"
        case .leaveUnchanged: return "leave unchanged"
        }
    }

    /// Whether this action puts anything into a destination feed.
    public var publishesEntries: Bool { self == .block }
}

/// Where a decision has got to.
///
/// The chain the brief specifies is
/// `draft → validated → awaitingApproval → published → awaitingPlatformRefresh → verified`.
///
/// `approved` is added between `awaitingApproval` and `published` because
/// publication cannot happen while outbound synchronisation is switched off.
/// Without it, work the owner has approved would be indistinguishable from work
/// they have not looked at, which is precisely the confusion this project
/// exists to avoid.
public enum AvailabilityStatus: String, CaseIterable, Codable, Sendable, Identifiable {
    case draft
    case validated
    case awaitingApproval = "awaiting_approval"
    case approved
    case published
    case awaitingPlatformRefresh = "awaiting_platform_refresh"
    case verified
    case failed
    case cancelled
    case unknown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .draft: return "Draft"
        case .validated: return "Checked"
        case .awaitingApproval: return "Waiting for your approval"
        case .approved: return "Approved, not yet published"
        case .published: return "Published — awaiting platform confirmation"
        case .awaitingPlatformRefresh: return "Published — awaiting platform confirmation"
        case .verified: return "Confirmed on the platform"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .unknown: return "Unknown"
        }
    }

    /// Longer line for the status panel.
    public var explanation: String {
        switch self {
        case .draft:
            return "Being written. Nothing has been checked yet."
        case .validated:
            return "Checked against your reservations and existing blocks. Not yet submitted."
        case .awaitingApproval:
            return "Waiting for you to approve it. Nothing leaves this Mac until you do."
        case .approved:
            return "You approved this. It will be included the next time a feed is published."
        case .published, .awaitingPlatformRefresh:
            return "The feed containing this has been published. Platforms re-read calendars on "
                + "their own schedule, usually every few hours, so the dates may not be blocked "
                + "there yet. Publishing a file is not proof the platform imported it."
        case .verified:
            return "Evidence from the destination confirms these nights are unavailable there."
        case .failed:
            return "Something went wrong. Nothing was changed on any platform."
        case .cancelled:
            return "Withdrawn before it was published."
        case .unknown:
            return "The state of this decision could not be determined. Treated as not published."
        }
    }

    /// States whose entries may appear in a generated feed.
    public var contributesToFeed: Bool {
        switch self {
        case .approved, .published, .awaitingPlatformRefresh, .verified: return true
        case .draft, .validated, .awaitingApproval, .failed, .cancelled, .unknown: return false
        }
    }

    /// Still open, so it counts as a pending operation during conflict checks.
    public var isPending: Bool {
        switch self {
        case .draft, .validated, .awaitingApproval, .approved: return true
        default: return false
        }
    }

    /// Whether a bulk sweep may discard this without asking again.
    ///
    /// Deliberately NOT `isPending`. `isPending` answers "does this still
    /// occupy these nights?", and an approved-but-unpublished decision does —
    /// which is why conflict checks must keep counting it. That is a different
    /// question from "is this safe to throw away in bulk?".
    ///
    /// Approval is the owner saying yes. A sweep that undoes it destroys
    /// deliberate work, which is exactly what happened to two approved Vrbo
    /// decisions when "Cancel all" reused `isPending` as a deletion scope.
    ///
    /// Listed exhaustively rather than with a `default`, so a status added
    /// later has to be classified on purpose instead of defaulting to
    /// discardable.
    public var isDiscardableInBulk: Bool {
        switch self {
        case .draft, .validated, .awaitingApproval: return true
        case .approved, .published, .awaitingPlatformRefresh, .verified,
             .failed, .cancelled, .unknown: return false
        }
    }

    public var isTerminal: Bool {
        self == .cancelled || self == .verified || self == .failed
    }

    /// The legal next states. Anything else is refused by `AvailabilityManager`,
    /// so a decision cannot jump from draft straight to published.
    public var allowedTransitions: Set<AvailabilityStatus> {
        switch self {
        case .draft: return [.validated, .failed, .cancelled, .unknown]
        case .validated: return [.awaitingApproval, .draft, .failed, .cancelled, .unknown]
        case .awaitingApproval: return [.approved, .draft, .failed, .cancelled, .unknown]
        case .approved: return [.published, .cancelled, .failed, .unknown]
        case .published: return [.awaitingPlatformRefresh, .verified, .failed, .unknown]
        case .awaitingPlatformRefresh: return [.verified, .failed, .unknown]
        case .verified: return [.unknown]
        case .failed: return [.draft, .cancelled]
        case .cancelled: return []
        case .unknown: return [.draft, .cancelled, .failed]
        }
    }
}

/// One platform's half of what the owner decided for a date range.
///
/// Decisions are per destination on purpose: choosing to block Vrbo says
/// nothing about Airbnb, and the editor records a separate row for each
/// platform the owner touched.
public struct AvailabilityDecision: Identifiable, Hashable, Sendable {
    public var id: Int64?
    public var propertyID: Int64
    public var destination: RentalPlatform
    public var action: AvailabilityAction
    /// First night, inclusive, at the property's local midnight.
    public var startDay: Date
    /// Departure day, **exclusive**. Blocking 10–15 December blocks the nights
    /// of the 10th to the 14th and leaves the 15th free to arrive.
    public var endDay: Date
    public var status: AvailabilityStatus
    public var reason: String
    /// Stable identifier for the entry this decision produces in a feed, so
    /// regenerating a feed does not look like a new event to the destination.
    public var publicationUID: String
    public var createdAt: Date
    public var updatedAt: Date
    public var validatedAt: Date?
    public var approvedAt: Date?
    public var approvedBy: String?
    public var publishedAt: Date?
    public var refreshExpectedBy: Date?
    public var verifiedAt: Date?
    public var cancelledAt: Date?
    public var failureReason: String?
    public var supersedesID: Int64?
    public var createdBy: String

    public init(
        id: Int64? = nil,
        propertyID: Int64,
        destination: RentalPlatform,
        action: AvailabilityAction,
        startDay: Date,
        endDay: Date,
        status: AvailabilityStatus = .draft,
        reason: String = "",
        publicationUID: String = AvailabilityDecision.makeUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        validatedAt: Date? = nil,
        approvedAt: Date? = nil,
        approvedBy: String? = nil,
        publishedAt: Date? = nil,
        refreshExpectedBy: Date? = nil,
        verifiedAt: Date? = nil,
        cancelledAt: Date? = nil,
        failureReason: String? = nil,
        supersedesID: Int64? = nil,
        createdBy: String = ""
    ) {
        self.id = id
        self.propertyID = propertyID
        self.destination = destination
        self.action = action
        self.startDay = startDay
        self.endDay = endDay
        self.status = status
        self.reason = reason
        self.publicationUID = publicationUID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.validatedAt = validatedAt
        self.approvedAt = approvedAt
        self.approvedBy = approvedBy
        self.publishedAt = publishedAt
        self.refreshExpectedBy = refreshExpectedBy
        self.verifiedAt = verifiedAt
        self.cancelledAt = cancelledAt
        self.failureReason = failureReason
        self.supersedesID = supersedesID
        self.createdBy = createdBy
    }

    public static func makeUID() -> String {
        "vrc-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    /// Nights covered. Half-open, so 10 → 15 December is five nights.
    public var nights: Int {
        max(0, DayMath.daysBetween(startDay, endDay))
    }

    public var dateRangeDescription: String {
        "\(DayMath.mediumString(startDay)) – \(DayMath.mediumString(endDay))"
    }

    /// The nights themselves, for explaining a range without ambiguity.
    public var nightsDescription: String {
        guard nights > 0 else { return "no nights" }
        let lastNight = DayMath.adding(days: -1, to: endDay)
        if nights == 1 {
            return "the night of \(DayMath.mediumString(startDay))"
        }
        return "the nights of \(DayMath.mediumString(startDay)) to "
            + "\(DayMath.mediumString(lastNight)) — \(nights) nights, leaving "
            + "\(DayMath.mediumString(endDay)) free to arrive"
    }

    /// Half-open overlap, consistent with how reservations are compared.
    public func overlaps(start: Date, end: Date) -> Bool {
        startDay < end && start < endDay
    }

    public func overlaps(_ other: AvailabilityDecision) -> Bool {
        overlaps(start: other.startDay, end: other.endDay)
    }

    public func covers(day: Date) -> Bool {
        let value = DayMath.utcMidnight(day)
        return value >= DayMath.utcMidnight(startDay) && value < DayMath.utcMidnight(endDay)
    }

    public var summaryLine: String {
        "\(action.displayName) \(destination.displayName) · \(dateRangeDescription) "
            + "(\(nights) night\(nights == 1 ? "" : "s"))"
    }
}
