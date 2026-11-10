import Foundation

/// One run of an event inside a single calendar week.
///
/// A reservation that spans a month boundary becomes several segments, one per
/// week row, each knowing whether it is the real beginning or end of the stay
/// so the bar can be capped on the right sides and left open where it continues.
public struct WeekSegment: Identifiable, Sendable, Hashable {
    public let eventKey: String
    /// 0–6, Sunday-based column where the bar starts in this week.
    public let startColumn: Int
    /// 0–6, inclusive column where the bar ends in this week.
    public let endColumn: Int
    /// True when the stay actually begins here rather than continuing in.
    public let isStart: Bool
    /// True when the stay actually ends here rather than continuing out.
    public let isEnd: Bool
    /// Which stacked row inside the week the bar occupies.
    public var lane: Int

    public var id: String { "\(eventKey)-\(startColumn)-\(lane)" }
    public var columnSpan: Int { endColumn - startColumn + 1 }

    public init(
        eventKey: String, startColumn: Int, endColumn: Int,
        isStart: Bool, isEnd: Bool, lane: Int = 0
    ) {
        self.eventKey = eventKey
        self.startColumn = startColumn
        self.endColumn = endColumn
        self.isStart = isStart
        self.isEnd = isEnd
        self.lane = lane
    }
}

/// One event's bar on a portfolio month strip.
public struct MonthStripBar: Sendable, Hashable, Identifiable {
    public let eventKey: String
    /// Days from the first of the month.
    public let startColumn: Int
    /// Days covered. Checkout day is excluded, as everywhere else.
    public let columnSpan: Int
    public let lane: Int
    /// The event began before this month; the bar should not be capped here.
    public let isClippedAtStart: Bool
    /// The event continues past this month.
    public let isClippedAtEnd: Bool

    public var id: String { "\(eventKey)-\(startColumn)-\(lane)" }

    public init(
        eventKey: String, startColumn: Int, columnSpan: Int, lane: Int,
        isClippedAtStart: Bool, isClippedAtEnd: Bool
    ) {
        self.eventKey = eventKey
        self.startColumn = startColumn
        self.columnSpan = columnSpan
        self.lane = lane
        self.isClippedAtStart = isClippedAtStart
        self.isClippedAtEnd = isClippedAtEnd
    }
}

public struct WeekLayout: Sendable {
    public let weekStart: Date
    public let segments: [WeekSegment]
    /// How many stacked rows this week needs.
    public var laneCount: Int { (segments.map(\.lane).max() ?? -1) + 1 }

    public func segments(inLane lane: Int) -> [WeekSegment] {
        segments.filter { $0.lane == lane }.sorted { $0.startColumn < $1.startColumn }
    }
}

/// Works out where continuous date-range bars go in a month grid.
///
/// Kept out of the view layer so it can be tested: getting a bar to span the
/// right columns, break correctly at a week boundary and not collide with its
/// neighbours is arithmetic, not appearance.
public enum CalendarLayout {

    /// Lays out one week.
    ///
    /// - Parameters:
    ///   - weekStart: the Sunday the row begins on, at UTC midnight.
    ///   - events: candidate events; those not touching the week are ignored.
    ///   - maxLanes: bars beyond this are dropped so the caller can show an
    ///     overflow count rather than an unbounded stack.
    public static func layout(
        weekStart: Date,
        events: [ClassifiedEvent],
        maxLanes: Int = 4
    ) -> WeekLayout {
        let start = DayMath.utcMidnight(weekStart)
        let weekEndExclusive = DayMath.adding(days: 7, to: start)

        // Longest first, then earliest, so long stays settle into the top lanes
        // and short ones fill in beneath. Ties break on key for stability, so
        // the same input always lays out the same way.
        let candidates = events
            .filter { event in
                let checkIn = DayMath.utcMidnight(event.event.checkIn)
                let checkOut = normalisedCheckOut(event)
                return checkIn < weekEndExclusive && checkOut > start
            }
            .sorted { lhs, rhs in
                let lhsLength = DayMath.daysBetween(
                    DayMath.utcMidnight(lhs.event.checkIn), normalisedCheckOut(lhs)
                )
                let rhsLength = DayMath.daysBetween(
                    DayMath.utcMidnight(rhs.event.checkIn), normalisedCheckOut(rhs)
                )
                if lhsLength != rhsLength { return lhsLength > rhsLength }
                if lhs.event.checkIn != rhs.event.checkIn {
                    return lhs.event.checkIn < rhs.event.checkIn
                }
                return lhs.event.eventKey < rhs.event.eventKey
            }

        // laneEnds[lane] is the last column already taken in that lane.
        var laneEnds: [Int] = []
        var segments: [WeekSegment] = []

        for item in candidates {
            let checkIn = DayMath.utcMidnight(item.event.checkIn)
            let checkOut = normalisedCheckOut(item)

            let rawStart = DayMath.daysBetween(start, checkIn)
            let startColumn = max(0, rawStart)
            // checkOut is exclusive, so the last occupied night is the day before.
            let rawEnd = DayMath.daysBetween(start, checkOut) - 1
            let endColumn = min(6, rawEnd)
            guard endColumn >= startColumn else { continue }

            var assigned: Int?
            for (lane, lastColumn) in laneEnds.enumerated() where lastColumn < startColumn {
                assigned = lane
                break
            }
            if assigned == nil, laneEnds.count < maxLanes {
                laneEnds.append(-1)
                assigned = laneEnds.count - 1
            }
            guard let lane = assigned else { continue }

            laneEnds[lane] = endColumn
            segments.append(WeekSegment(
                eventKey: item.event.eventKey,
                startColumn: startColumn,
                endColumn: endColumn,
                isStart: rawStart >= 0,
                isEnd: rawEnd <= 6,
                lane: lane
            ))
        }

        return WeekLayout(weekStart: start, segments: segments)
    }

    /// Events that touch a week but could not be given a lane, so the view can
    /// say "+2 more" rather than silently hiding them.
    public static func overflowCount(
        weekStart: Date, events: [ClassifiedEvent], maxLanes: Int = 4
    ) -> Int {
        let start = DayMath.utcMidnight(weekStart)
        let weekEndExclusive = DayMath.adding(days: 7, to: start)
        let touching = events.filter { event in
            DayMath.utcMidnight(event.event.checkIn) < weekEndExclusive
                && normalisedCheckOut(event) > start
        }
        let placed = Set(layout(weekStart: start, events: events, maxLanes: maxLanes)
            .segments.map(\.eventKey))
        return touching.filter { !placed.contains($0.event.eventKey) }.count
    }

    /// A zero- or negative-length event still occupies the night it starts on,
    /// so it gets one day rather than vanishing.
    private static func normalisedCheckOut(_ item: ClassifiedEvent) -> Date {
        let checkIn = DayMath.utcMidnight(item.event.checkIn)
        let checkOut = DayMath.utcMidnight(item.event.checkOut)
        return checkOut > checkIn ? checkOut : DayMath.adding(days: 1, to: checkIn)
    }

    /// The six-week grid a month view shows, starting on the Sunday on or
    /// before the first of the month.
    /// One continuous bar per event across a whole month, for the portfolio
    /// strip — where the comparison that matters is BETWEEN properties on the
    /// same date, so a repeated seven-column grid would make it impossible.
    ///
    /// Lives here rather than in the view for the same reason the week layout
    /// does: lane assignment and checkout-exclusive clipping are rules, not
    /// drawing, and a second copy in SwiftUI would drift from this one.
    ///
    /// Bars are clipped to the month, so an event running from last year to
    /// next still produces exactly one bar covering every day of it.
    public static func monthStrip(
        monthStart: Date, dayCount: Int, events: [ClassifiedEvent], maxLanes: Int = 4
    ) -> [MonthStripBar] {
        let first = DayMath.utcMidnight(monthStart)
        let endExclusive = DayMath.adding(days: dayCount, to: first)
        var laneEnds: [Date] = []
        var bars: [MonthStripBar] = []

        for item in events.filter({ $0.event.isActive })
            .sorted(by: { $0.event.checkIn < $1.event.checkIn }) {
            let checkIn = DayMath.utcMidnight(item.event.checkIn)
            // checkOut is exclusive: a stay ending on the 5th frees the 5th.
            let checkOut = DayMath.utcMidnight(item.event.checkOut)
            guard checkIn < endExclusive, checkOut > first else { continue }

            let start = max(checkIn, first)
            let end = min(checkOut, endExclusive)

            // The first lane whose previous occupant has already checked out.
            var lane = laneEnds.firstIndex { $0 <= checkIn } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(checkOut) } else { laneEnds[lane] = checkOut }
            let clamped = min(lane, maxLanes - 1)

            bars.append(MonthStripBar(
                eventKey: item.event.eventKey,
                startColumn: DayMath.daysBetween(first, start),
                columnSpan: max(1, DayMath.daysBetween(start, end)),
                lane: clamped,
                isClippedAtStart: checkIn < first,
                isClippedAtEnd: checkOut > endExclusive))
        }
        return bars
    }

    public static func monthGridDays(containing date: Date) -> [Date] {
        let calendar = DayMath.utcCalendar
        let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: date)
        ) ?? date
        let weekday = calendar.component(.weekday, from: monthStart)
        let gridStart = DayMath.adding(days: -(weekday - 1), to: monthStart)
        return (0..<42).map { DayMath.adding(days: $0, to: gridStart) }
    }

    public static func weekStarts(containing date: Date) -> [Date] {
        stride(from: 0, to: 42, by: 7).map { offset in
            DayMath.adding(days: offset, to: monthGridDays(containing: date)[0])
        }
    }
}
