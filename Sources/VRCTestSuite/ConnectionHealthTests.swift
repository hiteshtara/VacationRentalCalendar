import Foundation
import VRCCore

/// A configured connection is not a working connection.
///
/// Skipping publication because a subscription is listed in someone's
/// settings leaves nights uncovered when that subscription has quietly
/// stopped fetching. And switching routes automatically when a link looks
/// unhealthy produces duplicate blocks at the exact moment the original
/// recovers. So health is measured, the route is declared, and changing the
/// route is a proposal a person approves.
public enum ConnectionHealthTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }
    static let now = DayMath.day(2026, 11, 11)

    static func item(
        _ platform: RentalPlatform, _ kind: BlockKind,
        _ ci: Date, _ co: Date, uid: String = ""
    ) -> ClassifiedEvent {
        let key = "ch-\(platform.rawValue)-\(Int(ci.timeIntervalSince1970))-\(kind.rawValue)"
        return ClassifiedEvent(
            event: CalendarEvent(
                listingID: 1, eventKey: key, uid: uid.isEmpty ? key : uid,
                platform: platform, summary: "Reserved", details: "",
                checkIn: ci, checkOut: co),
            classification: EventClassification(
                eventKey: key, kind: kind, confidence: .high, source: .manual,
                needsReview: false, exportApproved: true),
            listingLabel: platform.displayName, propertyID: 1, propertyName: "39 G Street")
    }

    static func fresh(_ p: RentalPlatform) -> FeedFreshness {
        FeedFreshness(platform: p, lastSuccess: now.addingTimeInterval(-300),
                      lastOutcome: .success)
    }
    static func stale(_ p: RentalPlatform) -> FeedFreshness {
        FeedFreshness(platform: p, lastSuccess: now.addingTimeInterval(-20 * 3600),
                      lastOutcome: .success)
    }

    static let reservation = item(.bookingCom, .confirmedReservation,
                                  DayMath.day(2026, 12, 11), DayMath.day(2026, 12, 21))

    public static var cases: [TestCase] { [

        TestCase(group: "Connection health",
                 name: "a link whose destination holds the nights is DELIVERING") { expect in
            let mirrored = item(.airbnb, .ownerBlock,
                                day(2026, 12, 11), day(2026, 12, 21))
            let state = ConnectionHealth.assess(
                source: .bookingCom, destination: .airbnb,
                sourceEvents: [reservation], destinationEvents: [mirrored],
                destinationFeed: fresh(.airbnb), policy: .default, now: now)
            expect.equal(state, .delivering(confirmedNights: 10))
        },

        TestCase(group: "Connection health",
                 name: "a CONFIGURED link that delivers nothing is NOT delivering") { expect in
            // The real December case: Booking.com → Airbnb is connected, and
            // Airbnb's calendar shows none of the ten nights.
            let state = ConnectionHealth.assess(
                source: .bookingCom, destination: .airbnb,
                sourceEvents: [reservation], destinationEvents: [],
                destinationFeed: fresh(.airbnb), policy: .default, now: now)
            expect.equal(state, .notDelivering(missingNights: 10))
        },

        TestCase(group: "Connection health",
                 name: "partial delivery is not delivery") { expect in
            let half = item(.airbnb, .ownerBlock, day(2026, 12, 11), day(2026, 12, 16))
            let state = ConnectionHealth.assess(
                source: .bookingCom, destination: .airbnb,
                sourceEvents: [reservation], destinationEvents: [half],
                destinationFeed: fresh(.airbnb), policy: .default, now: now)
            expect.equal(state, .notDelivering(missingNights: 5))
        },

        TestCase(group: "Connection health",
                 name: "a stale destination feed yields UNKNOWN, never a verdict") { expect in
            let state = ConnectionHealth.assess(
                source: .bookingCom, destination: .airbnb,
                sourceEvents: [reservation], destinationEvents: [],
                destinationFeed: stale(.airbnb), policy: .default, now: now)
            guard case .unknown = state else {
                return expect.fail("expected unknown, got \(state)")
            }
        },

        TestCase(group: "Connection health",
                 name: "a cancellation penalty at the destination is not delivery") { expect in
            let penalty = item(.airbnb, .cancellationBlock,
                               day(2026, 12, 11), day(2026, 12, 21))
            let state = ConnectionHealth.assess(
                source: .bookingCom, destination: .airbnb,
                sourceEvents: [reservation], destinationEvents: [penalty],
                destinationFeed: fresh(.airbnb), policy: .default, now: now)
            expect.equal(state, .notDelivering(missingNights: 10))
        },

        // MARK: - Route changes are proposals

        TestCase(group: "Connection health",
                 name: "a broken direct link PROPOSES our feed, it does not switch") { expect in
            let proposal = ConnectionHealth.proposal(
                source: .bookingCom, destination: .airbnb,
                route: .directConnection, state: .notDelivering(missingNights: 10),
                destinationAlreadyCovered: false)
            guard let proposal else { return expect.fail("expected a proposal") }
            expect.equal(proposal.current, .directConnection)
            expect.equal(proposal.proposed, .ourFeed)
            expect.ok(proposal.requiresApproval, "never applied by code")
            expect.contains(proposal.reason, "configured")
            expect.contains(proposal.reason, "10 nights")
        },

        TestCase(group: "Connection health",
                 name: "an UNKNOWN state proposes nothing at all") { expect in
            // The dangerous case: a brief outage must not replace a working
            // route. Not knowing is not evidence of breakage.
            for route in [ConnectionHealth.Route.directConnection, .ourFeed] {
                expect.ok(ConnectionHealth.proposal(
                    source: .bookingCom, destination: .airbnb, route: route,
                    state: .unknown(reason: "feed stale"),
                    destinationAlreadyCovered: false) == nil,
                    "proposed a change from \(route.rawValue) on no evidence")
            }
        },

        TestCase(group: "Connection health",
                 name: "a healthy link proposes nothing") { expect in
            expect.ok(ConnectionHealth.proposal(
                source: .bookingCom, destination: .airbnb, route: .directConnection,
                state: .delivering(confirmedNights: 10),
                destinationAlreadyCovered: true) == nil)
        },

        TestCase(group: "Connection health",
                 name: "a proposal warns when acting would duplicate") { expect in
            let proposal = ConnectionHealth.proposal(
                source: .bookingCom, destination: .airbnb,
                route: .directConnection, state: .notDelivering(missingNights: 3),
                destinationAlreadyCovered: true)
            expect.ok(proposal?.wouldDuplicate == true,
                      "the owner must see that before approving")
        },

        TestCase(group: "Connection health",
                 name: "nothing carrying a pair is proposed, not assumed") { expect in
            let proposal = ConnectionHealth.proposal(
                source: .airbnb, destination: .vrbo, route: .none,
                state: .notDelivering(missingNights: 8),
                destinationAlreadyCovered: false)
            expect.equal(proposal?.proposed, .ourFeed)
            expect.ok(proposal?.requiresApproval == true)
        },

        TestCase(group: "Connection health",
                 name: "publishing follows the declared route only") { expect in
            expect.ok(ConnectionHealth.publishes(route: .ourFeed))
            expect.ok(!ConnectionHealth.publishes(route: .directConnection))
            expect.ok(!ConnectionHealth.publishes(route: .none))
        },
    ] }
}
