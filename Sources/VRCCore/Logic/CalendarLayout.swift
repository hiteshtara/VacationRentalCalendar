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
