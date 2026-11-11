import Foundation

/// What is actually awaiting a decision, split so a real booking cannot hide
/// inside a number dominated by noise.
///
/// The live warning read "436 nights awaiting decisions". True, and useless: a
/// genuine ten-night reservation sat inside a total swollen by two
/// booking-window edges of 406 and 195 nights — the dates past the end of the
/// booking window, which every platform exports as unavailable and which need
/// no decision at all.
///
/// Nights are counted as a **union of occupied nights**, not a sum of event
/// lengths. Two events covering the same nights are one problem, not two, and
/// checkout-exclusive semantics mean a stay of 11–21 December occupies ten
/// nights and releases the 21st.
public struct ReviewSummary: Sendable, Equatable {

    /// Short, near-term, and genuinely undecided. What a person should look at.
    public let actionable: [ClassifiedEvent]
    /// Booking-window edges and other long-horizon ranges. Kept, never hidden,
    /// but not what the headline is about.
    public let longHorizon: [ClassifiedEvent]

    /// Distinct nights, deduplicated across overlaps.
    public let actionableNights: Int
    public let longHorizonNights: Int

    /// Anything at or beyond this is treated as a horizon artefact rather than
    /// a decision. Matches the classifier's own long-horizon threshold in
    /// spirit: a range this long is the edge of a booking window, not a hold.
    public static let longHorizonThreshold = 180

    public var headline: String {
        if actionable.isEmpty && longHorizon.isEmpty {
            return "Nothing awaiting a decision."
        }
        if actionable.isEmpty {
            return "Nothing urgent. \(longHorizon.count) long-range "
                + "restriction\(longHorizon.count == 1 ? "" : "s") recorded."
        }
        let noun = actionable.count == 1 ? "block" : "blocks"
        var line = "\(actionable.count) \(noun) need a decision "
            + "(\(actionableNights) night\(actionableNights == 1 ? "" : "s"))"
        if !longHorizon.isEmpty {
            line += ", plus \(longHorizon.count) long-range "
                + "restriction\(longHorizon.count == 1 ? "" : "s")"
        }
        return line + "."
    }

    public init(
        actionable: [ClassifiedEvent], longHorizon: [ClassifiedEvent],
        actionableNights: Int, longHorizonNights: Int
    ) {
        self.actionable = actionable
        self.longHorizon = longHorizon
        self.actionableNights = actionableNights
        self.longHorizonNights = longHorizonNights
    }

    /// Splits what needs review, keeping every record.
    public static func make(
        from items: [ClassifiedEvent],
        longHorizonThreshold threshold: Int = ReviewSummary.longHorizonThreshold
    ) -> ReviewSummary {
        var actionable: [ClassifiedEvent] = []
        var longHorizon: [ClassifiedEvent] = []
        for item in items {
            let nights = CalendarVisibility.occupiedNights(of: item.event).count
            if nights >= threshold || item.classification.kind == .platformRestriction {
                longHorizon.append(item)
            } else {
                actionable.append(item)
            }
        }
        return ReviewSummary(
            actionable: actionable,
            longHorizon: longHorizon,
            actionableNights: distinctNights(of: actionable),
            longHorizonNights: distinctNights(of: longHorizon))
    }

    /// The union of nights, so overlapping ranges are not double counted and
    /// abutting ones are not merged away.
    public static func distinctNights(of items: [ClassifiedEvent]) -> Int {
        var nights: Set<Date> = []
        for item in items {
            for night in CalendarVisibility.occupiedNights(of: item.event) {
                nights.insert(night)
            }
        }
        return nights.count
    }
}
