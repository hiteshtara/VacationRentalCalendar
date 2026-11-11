import Foundation

/// Whether a destination is protected *because of us*.
///
/// `DeliveryStatus` alone had a hole: it reported Protected whenever some
/// genuine block at the destination covered the nights. A block that happens
/// to cover them proves the nights are busy there — it does not prove our
/// synchronisation worked. If the owner later removes their own unrelated
/// block the nights reopen, and we would still be claiming Protected.
///
/// So **date coverage and source attribution are reported separately**, and
/// only the two together earn Protected. Attribution comes from the UID we
/// published: publication UIDs are migrated verbatim and never regenerated,
/// which makes them the one durable link between a source reservation and the
/// block standing at a destination.
public struct DeliveryAssessment: Sendable, Equatable {

    public enum Attribution: Sendable, Equatable {
        /// A block carrying the UID we published for this reservation.
        case ours(uid: String)
        /// The nights are covered by a block whose identifier is not ours.
        ///
        /// That has two possible causes and **nothing in the data separates
        /// them**: either the block is unrelated — the owner's own hold —
        /// or the destination rewrote the UID when it imported our calendar,
        /// which several platforms do. Two states here would imply we can
        /// tell which, so there is one.
        ///
        /// Coverage verified, attribution not. **Never Protected.**
        case coverageAttributionUnverified
        /// Nothing of ours, and nothing covering.
        case none
    }

    public let status: DeliveryStatus
    public let attribution: Attribution
    /// Whether the occupied nights are unavailable at the destination at all,
    /// whoever caused it.
    public let datesCovered: Bool
    public let explanation: String

    public static func assess(
        item: ClassifiedEvent,
        destination: RentalPlatform,
        policy: OutboundPolicy,
        observedAtDestination: [ClassifiedEvent],
        publishedUID: String?,
        destinationFeed: FeedFreshness,
        lastPublishFailed: Bool,
        now: Date = Date()
    ) -> DeliveryAssessment {

        // Policy and review state come first; a block that may not travel is
        // not a delivery question.
        switch policy.decision(item, to: destination) {
        case .blocked(let reason) where reason == .needsReview:
            return DeliveryAssessment(
                status: .needsReview, attribution: .none, datesCovered: false,
                explanation: "Undecided, so it protects nothing yet.")
        case .blocked:
            return DeliveryAssessment(
                status: .pending, attribution: .none, datesCovered: false,
                explanation: "Not sent to \(destination.displayName) by policy.")
        case .propagate:
            break
        }

        if lastPublishFailed {
            return DeliveryAssessment(
                status: .failed, attribution: .none, datesCovered: false,
                explanation: "The last publication to \(destination.displayName) failed.")
        }
        guard !destinationFeed.isStale(now: now) else {
            return DeliveryAssessment(
                status: .pending, attribution: .none, datesCovered: false,
                explanation: "\(destination.displayName)'s feed is stale, so nothing there "
                    + "can be confirmed right now.")
        }

        let needed = Set(OutboundPolicy.protectedNights(of: item))

        // Only genuine holds count. A cancellation penalty is not a hold
        // anyone placed and those nights stay sellable.
        let holds = observedAtDestination.filter {
            $0.event.platform == destination
                && $0.propertyID == item.propertyID
                && $0.classification.kind.describesGenuineUnavailability
        }

        var allCovered: Set<Date> = []
        var oursCovered: Set<Date> = []
        for hold in holds {
            let nights = Set(CalendarVisibility.occupiedNights(of: hold.event))
            allCovered.formUnion(nights)
            if let publishedUID, hold.event.uid == publishedUID {
                oursCovered.formUnion(nights)
            }
        }

        let coveredByAnything = needed.isSubset(of: allCovered)
        let coveredByUs = needed.isSubset(of: oursCovered)

        if coveredByUs {
            return DeliveryAssessment(
                status: .protected,
                attribution: .ours(uid: publishedUID ?? ""),
                datesCovered: true,
                explanation: "\(destination.displayName) is showing the block this app "
                    + "published, covering every night.")
        }
        if coveredByAnything {
            // A platform that imports an external calendar often re-exports
            // the block under its OWN uid, so our uid can be absent even when
            // our block is what is holding the dates. We cannot tell that
            // apart from an unrelated block of the owner's, so we say exactly
            // that rather than guessing in either direction.
            return DeliveryAssessment(
                status: .pending,
                attribution: .coverageAttributionUnverified,
                datesCovered: true,
                explanation: "These nights are unavailable on \(destination.displayName), but "
                    + "the block there does not carry the identifier this app published — it is "
                    + "either not from this app, or that platform rewrote the identifier on "
                    + "import. Coverage is verified; attribution is not, so this is not counted "
                    + "as protected.")
        }
        return DeliveryAssessment(
            status: .pending,
            attribution: publishedUID == nil ? .none : .none,
            datesCovered: false,
            explanation: "\(destination.displayName) is not yet showing a block for these "
                + "nights.")
    }
}
