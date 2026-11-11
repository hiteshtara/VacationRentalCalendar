import Foundation

/// Geometry for a horizontal multi-property calendar.
///
/// Properties down the left, nights across the top, one continuous bar per
/// reservation or block. A month grid was the wrong shape for this job: it
/// breaks a stay at every month boundary, has no room for a per-platform
/// label, and — the reason this exists — it leaves a cell blank when it has
/// nothing to draw, which on a calendar reads as "free".
///
/// Pure geometry, no SwiftUI, so the rules that matter can be tested: a bar
/// spans exactly the nights occupied, checkout exclusive; a stay crossing a
/// month boundary stays one bar; overlapping bars are stacked into lanes
/// rather than hidden; and a bar running past either edge of the window is
/// clipped with its continuation marked rather than dropped.
public struct TimelineLayout: Sendable, Equatable {

    /// One drawn bar.
    public struct Bar: Sendable, Equatable, Identifiable {
        public let id: String
        public let item: ClassifiedEvent
        public let emphasis: CalendarEmphasis
        /// Index of the first visible night, 0-based from the window start.
        public let startColumn: Int
        /// Number of night columns the bar covers inside the window.
        public let columnCount: Int
        /// Stacking position when bars overlap. 0 is the top lane.
        public let lane: Int
        /// The stay begins before the window and is clipped here.
        public let continuesBefore: Bool
        /// The stay ends after the window and is clipped here.
        public let continuesAfter: Bool

        public var endColumn: Int { startColumn + columnCount - 1 }
    }

    /// One property's band of the timeline.
    public struct Row: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let propertyName: String
        public let bars: [Bar]
        /// How many lanes this row needs — at least one, so an empty property
        /// still has height and is visibly empty rather than absent.
        public var laneCount: Int { max(1, (bars.map(\.lane).max() ?? -1) + 1) }
    }

    public let nights: [Date]
    public let rows: [Row]

    /// Builds the layout for a window of nights.
    ///
    /// `nights` are the night columns, each the UTC midnight that starts the
    /// night. A stay from the 11th to the 21st occupies the nights of the 11th
    /// to the 20th: ten columns, and the 21st stays free for someone else.
    public static func build(
        items: [ClassifiedEvent],
        properties: [(id: Int64, name: String)],
        windowStart: Date,
        nightCount: Int
    ) -> TimelineLayout {
        let start = DayMath.utcMidnight(windowStart)
        var nights: [Date] = []
        var cursor = start
        for _ in 0..<max(0, nightCount) {
            nights.append(cursor)
            cursor = DayMath.adding(days: 1, to: cursor)
        }
        let windowEnd = cursor   // exclusive

        var rows: [Row] = []
        for property in properties {
            let mine = items
                .filter { $0.propertyID == property.id }
                .sorted {
                    $0.event.checkIn == $1.event.checkIn
                        ? $0.id < $1.id
                        : $0.event.checkIn < $1.event.checkIn
                }

            // Lane assignment: first lane whose last occupied column is before
            // this bar's first. Overlaps therefore stack instead of hiding.
            var laneEnds: [Int] = []
            var bars: [Bar] = []

            for item in mine {
                let occupied = CalendarVisibility.occupiedNights(of: item.event)
                guard let first = occupied.first, let last = occupied.last else { continue }
                // Entirely outside the window.
                if last < start || first >= windowEnd { continue }

                let clippedFirst = max(first, start)
                let clippedLast = min(last, DayMath.adding(days: -1, to: windowEnd))
                guard let startColumn = nights.firstIndex(of: clippedFirst),
                      let endColumn = nights.firstIndex(of: clippedLast) else { continue }

                var lane = 0
                while lane < laneEnds.count, laneEnds[lane] >= startColumn { lane += 1 }
                if lane == laneEnds.count { laneEnds.append(endColumn) }
                else { laneEnds[lane] = endColumn }

                bars.append(Bar(
                    id: item.id,
                    item: item,
                    emphasis: CalendarVisibility.emphasis(for: item),
                    startColumn: startColumn,
                    columnCount: endColumn - startColumn + 1,
                    lane: lane,
                    continuesBefore: first < start,
                    continuesAfter: last >= windowEnd))
            }
            rows.append(Row(id: property.id, propertyName: property.name, bars: bars))
        }
        return TimelineLayout(nights: nights, rows: rows)
    }

    /// Whether any bar covers this column in this row — what tells an
    /// available night from an occupied one. A night with no bar is drawn as
    /// affirmatively available rather than left empty.
    public func isOccupied(row: Int, column: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        return rows[row].bars.contains { column >= $0.startColumn && column <= $0.endColumn }
    }
}
