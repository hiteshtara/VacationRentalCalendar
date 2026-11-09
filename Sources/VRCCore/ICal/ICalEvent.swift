import Foundation

/// A VEVENT as it appeared in the feed, before any interpretation.
///
/// Kept separate from `CalendarEvent` on purpose: this type is what the feed
/// said, and `CalendarEvent` is what the app decided to record. Keeping them
/// apart is what makes "do not trust the feed's classification" enforceable
/// rather than aspirational.
public struct ICalEvent: Hashable, Sendable {
    public var uid: String
    public var recurrenceID: String?
    public var summary: String
    public var description: String
    public var location: String
    public var status: String?
    public var sequence: Int
    public var dtStart: ICalDateValue?
    public var dtEnd: ICalDateValue?
    public var duration: TimeInterval?
    public var dtStamp: Date?
    public var lastModified: Date?
    public var hasRecurrenceRule: Bool
    /// Every content line, so nothing is silently discarded and the review UI
    /// can show the owner exactly what the platform sent.
    public var allLines: [ICalContentLine]

    public init(
        uid: String = "",
        recurrenceID: String? = nil,
        summary: String = "",
        description: String = "",
        location: String = "",
        status: String? = nil,
        sequence: Int = 0,
        dtStart: ICalDateValue? = nil,
        dtEnd: ICalDateValue? = nil,
        duration: TimeInterval? = nil,
        dtStamp: Date? = nil,
        lastModified: Date? = nil,
        hasRecurrenceRule: Bool = false,
        allLines: [ICalContentLine] = []
    ) {
        self.uid = uid
        self.recurrenceID = recurrenceID
        self.summary = summary
        self.description = description
        self.location = location
        self.status = status
        self.sequence = sequence
        self.dtStart = dtStart
        self.dtEnd = dtEnd
        self.duration = duration
        self.dtStamp = dtStamp
        self.lastModified = lastModified
        self.hasRecurrenceRule = hasRecurrenceRule
        self.allLines = allLines
    }

    /// Resolved check-in, normalised to UTC midnight for all-day events.
    public var resolvedCheckIn: Date? {
        guard let dtStart else { return nil }
        return dtStart.isDateOnly ? DayMath.utcMidnight(dtStart.date) : dtStart.date
    }

    /// Resolved exclusive check-out. Falls back to DURATION, then to one night.
    public var resolvedCheckOut: Date? {
        guard let start = resolvedCheckIn else { return nil }
        if let dtEnd {
            let end = dtEnd.isDateOnly ? DayMath.utcMidnight(dtEnd.date) : dtEnd.date
            return end > start ? end : DayMath.adding(days: 1, to: start)
        }
        if let duration {
            return start.addingTimeInterval(duration)
        }
        return DayMath.adding(days: 1, to: start)
    }

    public var isAllDay: Bool { dtStart?.isDateOnly ?? true }

    /// Hash of only the fields whose change constitutes a modified event, so a
    /// feed re-serving identical data does not look like a change.
    public func contentHash() -> String {
        let start = resolvedCheckIn.map { String($0.timeIntervalSince1970) } ?? ""
        let end = resolvedCheckOut.map { String($0.timeIntervalSince1970) } ?? ""
        let material = [
            uid, recurrenceID ?? "", summary, description, location,
            status ?? "", String(sequence), start, end, String(isAllDay),
        ].joined(separator: "\u{1F}")
        return EventKey.sha256(material)
    }
}
