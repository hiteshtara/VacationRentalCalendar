import Foundation

/// Brings unusually long unavailable periods back for a second look.
///
/// A range of several months is rarely a real hold. Far more often it is the
/// edge of a booking window, which the platform exports as "unavailable" and
/// which means nothing about the property. The two in this owner's data run
/// 193 and 641 nights.
///
/// The important constraint is what this does **not** do. It never changes a
/// classification, never changes who made it, and never touches an imported
/// event. It only raises the review flag and writes a rationale explaining
/// why, so the owner's own decision is preserved exactly while being brought
/// back to their attention. Export eligibility is unaffected by the flag
/// itself — a classification that was already barred from export stays barred.
public enum LongPeriodReview {

    /// Anything at or above this is worth a second look.
    public static let thresholdNights = 90

    /// Recorded so the sweep runs once rather than re-flagging something the
    /// owner has deliberately cleared.
    public static let settingKey = "long_period_review_sweep_v1"

    public struct Flagged: Sendable {
        public var eventKey: String
        public var platform: RentalPlatform
        public var nights: Int
        public var previousKind: BlockKind
        public var summary: String
    }

    /// Flags long periods that are not already marked as needing review and
    /// are not already classified as a platform restriction.
    ///
    /// - Returns: what was flagged, for reporting.
    @discardableResult
    public static func flagLongPeriods(
        in store: RentalStore,
        thresholdNights: Int = LongPeriodReview.thresholdNights,
        at date: Date = Date()
    ) throws -> [Flagged] {
        var flagged: [Flagged] = []

        for item in try store.classifiedEvents() {
            let nights = item.event.nights
            guard nights >= thresholdNights else { continue }
            guard !item.classification.needsReview else { continue }
            // Already named as a booking-window restriction: nothing to ask.
            guard item.classification.kind != .platformRestriction else { continue }

            var updated = item.classification
            // Kind and source are deliberately untouched.
            updated.needsReview = true
            updated.exportApproved = false
            updated.rationale = "You classified this as "
                + "\(item.classification.kind.displayName.lowercased()), and it is kept that way. "
                + "It covers \(nights) nights, which is long enough to be the edge of your "
                + "\(item.event.platform.displayName) booking window rather than a real hold — "
                + "platforms export the dates past the end of your window as unavailable. "
                + "Worth confirming. These nights stay out of every outbound feed either way."
            updated.decidedAt = date
            try store.classifications.save(updated)

            flagged.append(Flagged(
                eventKey: item.event.eventKey,
                platform: item.event.platform,
                nights: nights,
                previousKind: item.classification.kind,
                summary: item.event.summary
            ))
        }

        return flagged
    }

    /// Runs the sweep once per database, so clearing a flag makes it stay clear.
    @discardableResult
    public static func runOnce(in store: RentalStore, at date: Date = Date()) throws -> [Flagged] {
        guard !(try store.settings.bool(settingKey, default: false)) else { return [] }
        let flagged = try flagLongPeriods(in: store, at: date)
        try store.settings.set(settingKey, true)
        return flagged
    }
}
