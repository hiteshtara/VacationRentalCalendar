import Foundation

/// Whether a re-imported event changed in a way that could invalidate a
/// decision the owner already made about it.
///
/// The distinction matters because the two guarantees pull against each other:
/// a manual classification must survive every import (R4), yet a platform that
/// moves an event's dates or rewrites its summary may have turned it into
/// something else entirely (R5). The resolution is to keep the classification
/// and the fact a human made it, while sending it back to the review queue —
/// never to silently discard the decision, and never to silently keep applying
/// it to an event that no longer matches.
public enum MaterialChange {

    public struct Assessment: Sendable {
        public var isMaterial: Bool
        public var reasons: [String]

        public var explanation: String {
            reasons.joined(separator: " ")
        }
    }

    public static func assess(
        previous: CalendarEvent,
        updated: CalendarEvent,
        platform: RentalPlatform
    ) -> Assessment {
        var reasons: [String] = []

        if DayMath.utcMidnight(previous.checkIn) != DayMath.utcMidnight(updated.checkIn)
            || DayMath.utcMidnight(previous.checkOut) != DayMath.utcMidnight(updated.checkOut) {
            reasons.append(
                "The dates moved from "
                    + "\(DayMath.mediumString(previous.checkIn))–\(DayMath.mediumString(previous.checkOut))"
                    + " to "
                    + "\(DayMath.mediumString(updated.checkIn))–\(DayMath.mediumString(updated.checkOut))."
            )
        }

        if previous.feedStatus != updated.feedStatus {
            reasons.append(
                "The platform changed its status from \(previous.feedStatus.rawValue) to "
                    + "\(updated.feedStatus.rawValue)."
            )
        }

        if previous.summary != updated.summary {
            reasons.append(
                "The title changed from \"\(previous.summary)\" to \"\(updated.summary)\"."
            )
        }

        // A description gaining or losing booking evidence changes what the
        // event can be proven to be, even when nothing else moved.
        let wasIdentifiable = FeedDiagnostics.identifiesReservation(
            summary: previous.summary, details: previous.details, platform: platform
        )
        let isIdentifiable = FeedDiagnostics.identifiesReservation(
            summary: updated.summary, details: updated.details, platform: platform
        )
        if wasIdentifiable != isIdentifiable {
            reasons.append(
                isIdentifiable
                    ? "The platform now supplies booking details it did not before."
                    : "The booking details the platform previously supplied have gone."
            )
        }

        return Assessment(isMaterial: !reasons.isEmpty, reasons: reasons)
    }

    /// Applies R5 to a stored decision: keep what the owner chose, keep that
    /// they chose it, but ask them to look again.
    public static func flagForReReview(
        _ classification: EventClassification,
        assessment: Assessment,
        at date: Date = Date()
    ) -> EventClassification {
        var updated = classification
        updated.needsReview = true
        updated.rationale = "You classified this as "
            + "\(classification.kind.displayName.lowercased()), but "
            + "\(assessment.explanation) Your decision is kept, and these nights stay out of "
            + "every outbound feed until you confirm it still applies."
        updated.decidedAt = date
        // A changed event is no longer covered by the earlier approval.
        updated.exportApproved = false
        return updated
    }
}
