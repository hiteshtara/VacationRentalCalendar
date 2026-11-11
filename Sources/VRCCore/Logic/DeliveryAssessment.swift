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
        /// The nights are covered, but by something we did not publish.
        case unrelatedCoverage
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
            return DeliveryAssessment(
                status: .pending,
                attribution: .unrelatedCoverage,
                datesCovered: true,
                explanation: "These nights are unavailable on \(destination.displayName), but "
                    + "the block there is not from this app. If it is removed the nights "
                    + "reopen, so this is not counted as protected.")
        }
        return DeliveryAssessment(
            status: .pending,
            attribution: publishedUID == nil ? .none : .none,
            datesCovered: false,
            explanation: "\(destination.displayName) is not yet showing a block for these "
                + "nights.")
    }
}
