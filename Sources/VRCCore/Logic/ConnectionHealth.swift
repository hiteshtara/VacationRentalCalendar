import Foundation

/// Whether a direct platform-to-platform calendar link is actually working,
/// and what to do when it is not.
///
/// `SyncLoopGuard` originally inferred the publishing route from whether a
/// connection was *configured*. That is wrong twice over. A configured link
/// can be silently broken — the subscription exists, the platform has stopped
/// fetching, and the nights are uncovered while we skip publishing because we
/// believe something else has it. And a link that momentarily looks absent or
/// unhealthy must not flip us into publishing on our own, because an
/// automatic route change can produce duplicate blocks at the exact moment
/// the original recovers.
///
/// So health is **measured**, the route is **declared**, and changing the
/// route is a **proposal the owner approves**. Nothing here switches anything.
public enum ConnectionHealth {

    /// What the owner has decided should carry a given source to a given
    /// destination. Configuration, not inference.
    public enum Route: String, Sendable, Equatable {
        /// The platforms are linked directly; we publish nothing for this pair.
        case directConnection
        /// We publish a feed the destination subscribes to.
        case ourFeed
        /// Nothing carries it. The nights are not protected at this
        /// destination and the interface must say so.
        case none
    }

    public enum State: Sendable, Equatable {
        /// The destination's own calendar shows the source's reservations.
        case delivering(confirmedNights: Int)
        /// The destination is current and does NOT show them.
        case notDelivering(missingNights: Int)
        /// The destination's feed is stale or failed, so nothing can be
        /// concluded either way.
        case unknown(reason: String)
    }

    /// Measures a direct connection by looking for the source's protectable
    /// nights in the destination's own feed.
    ///
    /// Deliberately not "is the subscription listed in their settings" —
    /// that is what the owner configured, not what is happening.
    public static func assess(
        source: RentalPlatform,
        destination: RentalPlatform,
        sourceEvents: [ClassifiedEvent],
        destinationEvents: [ClassifiedEvent],
        destinationFeed: FeedFreshness,
        policy: OutboundPolicy,
        now: Date = Date()
    ) -> State {
        guard !destinationFeed.isStale(now: now) else {
            return .unknown(reason: destinationFeed.describe(now: now))
        }
        // Only things that would be expected to travel.
        let expected = sourceEvents.filter {
            $0.event.platform == source && policy.propagates($0, to: destination)
        }
        guard !expected.isEmpty else { return .delivering(confirmedNights: 0) }

        var needed: Set<Date> = []
        for item in expected {
            needed.formUnion(CalendarVisibility.occupiedNights(of: item.event))
        }
        var held: Set<Date> = []
        for item in destinationEvents
        where item.event.platform == destination
            && item.classification.kind.describesGenuineUnavailability {
            held.formUnion(CalendarVisibility.occupiedNights(of: item.event))
        }
        let missing = needed.subtracting(held)
        return missing.isEmpty
            ? .delivering(confirmedNights: needed.count)
            : .notDelivering(missingNights: missing.count)
    }

    /// A change of route, for a person to approve. Never applied by code.
    public struct RouteProposal: Sendable, Equatable {
        public let source: RentalPlatform
        public let destination: RentalPlatform
        public let current: Route
        public let proposed: Route
        public let reason: String
        /// Whether acting on it would create a second block over nights that
        /// already have one — the risk of switching while the original
        /// recovers.
        public let wouldDuplicate: Bool

        /// Always. There is no path that applies a proposal automatically.
        public let requiresApproval = true
    }

    /// Suggests a route change when the measured state contradicts the
    /// declared route. Returns nil when nothing should change.
    ///
    /// Note what it never proposes: switching away from `ourFeed` because a
    /// direct connection started working. Two routes delivering is safe;
    /// turning one off is the dangerous half, and that is the owner's call
    /// with duplicates in front of them.
    public static func proposal(
        source: RentalPlatform,
        destination: RentalPlatform,
        route: Route,
        state: State,
        destinationAlreadyCovered: Bool
    ) -> RouteProposal? {
        switch (route, state) {
        case (.directConnection, .notDelivering(let missing)):
            return RouteProposal(
                source: source, destination: destination,
                current: .directConnection, proposed: .ourFeed,
                reason: "The direct \(source.displayName) → \(destination.displayName) link is "
                    + "configured but \(destination.displayName)'s own calendar is missing "
                    + "\(missing) night\(missing == 1 ? "" : "s") it should be holding. "
                    + "Publishing our own feed would cover them.",
                wouldDuplicate: destinationAlreadyCovered)

        case (.none, .notDelivering(let missing)):
            return RouteProposal(
                source: source, destination: destination,
                current: .none, proposed: .ourFeed,
                reason: "Nothing is carrying \(source.displayName) → "
                    + "\(destination.displayName), and \(missing) night"
                    + "\(missing == 1 ? " is" : "s are") unprotected there.",
                wouldDuplicate: destinationAlreadyCovered)

        case (.directConnection, .unknown(let why)), (.ourFeed, .unknown(let why)):
            // Explicitly no proposal. An unverifiable state is not evidence
            // that anything is broken, and switching on it is how a working
            // route gets replaced during a brief outage.
            _ = why
            return nil

        default:
            return nil
        }
    }

    /// Whether, given the declared route, we publish this pair ourselves.
    ///
    /// Reads the route only. Health never changes it — health produces
    /// proposals, and an approved proposal changes the route.
    public static func publishes(route: Route) -> Bool { route == .ourFeed }
}
