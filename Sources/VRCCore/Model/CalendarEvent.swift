import Foundation

/// What the feed itself claims about an event's lifecycle (RFC 5545 STATUS).
public enum FeedEventStatus: String, Codable, CaseIterable, Sendable {
    case confirmed
    case tentative
    case cancelled

    public static func parse(_ raw: String?) -> FeedEventStatus {
        switch raw?.uppercased() {
        case "CANCELLED": return .cancelled
        case "TENTATIVE": return .tentative
        default: return .confirmed
        }
    }
}

/// One imported unavailable date range. Deliberately named "event" and not
/// "booking": the whole point of this app is that an imported event is *not*
/// known to be a booking until something or someone establishes that.
public struct CalendarEvent: Identifiable, Hashable, Sendable {
    public var id: Int64?
    public var listingID: Int64
    /// Stable identity across re-imports: derived from listing + UID + RECURRENCE-ID.
    public var eventKey: String
    public var uid: String
    public var recurrenceID: String?
    public var platform: RentalPlatform
    public var summary: String
    public var details: String
    public var location: String
    /// Inclusive first night, normalised to UTC midnight for all-day events.
    public var checkIn: Date
    /// Exclusive departure day — `[checkIn, checkOut)`.
    public var checkOut: Date
    public var isAllDay: Bool
    public var feedStatus: FeedEventStatus
    public var sequence: Int
    public var lastModified: Date?
    /// Hash of the fields that matter, used to detect a modified event.
    public var contentHash: String
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    /// Set when the event disappears from the feed or is cancelled. Rows are
    /// tombstoned rather than deleted so history and decisions survive.
    public var isTombstoned: Bool
    /// True when the feed used a feature this app does not expand (e.g. RRULE),
    /// which forces a review rather than a silent misreading.
    public var hasUnsupportedRecurrence: Bool

    public init(
        id: Int64? = nil,
        listingID: Int64,
        eventKey: String,
        uid: String,
        recurrenceID: String? = nil,
        platform: RentalPlatform,
        summary: String,
        details: String = "",
        location: String = "",
        checkIn: Date,
        checkOut: Date,
        isAllDay: Bool = true,
        feedStatus: FeedEventStatus = .confirmed,
        sequence: Int = 0,
        lastModified: Date? = nil,
        contentHash: String = "",
        firstSeenAt: Date = Date(),
        lastSeenAt: Date = Date(),
        isTombstoned: Bool = false,
        hasUnsupportedRecurrence: Bool = false
    ) {
        self.id = id
        self.listingID = listingID
        self.eventKey = eventKey
        self.uid = uid
        self.recurrenceID = recurrenceID
        self.platform = platform
        self.summary = summary
        self.details = details
        self.location = location
        self.checkIn = checkIn
        self.checkOut = checkOut
        self.isAllDay = isAllDay
        self.feedStatus = feedStatus
        self.sequence = sequence
        self.lastModified = lastModified
        self.contentHash = contentHash
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.isTombstoned = isTombstoned
        self.hasUnsupportedRecurrence = hasUnsupportedRecurrence
    }

    /// Number of nights occupied. A same-day event counts as one night so it
    /// still occupies a cell in the calendar.
    public var nights: Int {
        let seconds = checkOut.timeIntervalSince(checkIn)
        if seconds <= 0 { return 1 }
        return max(1, Int((seconds / 86_400).rounded()))
    }

    /// Half-open overlap test: a checkout on the day of the next check-in is a
    /// normal turnover, not an overlap.
    public func overlaps(_ other: CalendarEvent) -> Bool {
        checkIn < other.checkOut && other.checkIn < checkOut
    }

    public func overlap(with other: CalendarEvent) -> (start: Date, end: Date)? {
        guard overlaps(other) else { return nil }
        return (max(checkIn, other.checkIn), min(checkOut, other.checkOut))
    }

    /// True when the event covers the given calendar day (UTC day arithmetic).
    public func covers(day: Date) -> Bool {
        let d = DayMath.utcMidnight(day)
        return d >= DayMath.utcMidnight(checkIn) && d < max(
            DayMath.utcMidnight(checkOut),
            DayMath.utcMidnight(checkIn).addingTimeInterval(86_400)
        )
    }

    /// Whether the event is live in the feed right now.
    public var isActive: Bool { !isTombstoned && feedStatus != .cancelled }
}
