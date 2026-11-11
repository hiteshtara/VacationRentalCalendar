import Foundation
import VRCCore

/// Which classifications may protect which platforms, and whether a
/// destination has actually received them.
///
/// The rule that shapes everything: **Airbnb's export cannot distinguish an
/// owner block from a cancellation penalty.** Both are `Airbnb (Not
/// available)`. So an outbound calendar can never be a relay of an incoming
/// feed — it has to be built from classified evidence, and an Airbnb block
/// can only propagate once a person has said which kind it is.
///
/// All synthetic.
public enum OutboundPolicyTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

    static func item(
        _ platform: RentalPlatform, _ kind: BlockKind,
        needsReview: Bool = false,
        _ ci: Date = DayMath.day(2026, 12, 11),
        _ co: Date = DayMath.day(2026, 12, 21)
    ) -> ClassifiedEvent {
        let key = "o-\(platform.rawValue)-\(kind.rawValue)-\(Int(ci.timeIntervalSince1970))"
        return ClassifiedEvent(
            event: CalendarEvent(
                listingID: 1, eventKey: key, uid: key, platform: platform,
                summary: "synthetic", details: "", checkIn: ci, checkOut: co),
            classification: EventClassification(
                eventKey: key, kind: kind, confidence: needsReview ? .low : .high,
                source: .automatic, needsReview: needsReview),
            listingLabel: platform.displayName, propertyID: 1, propertyName: "39 G Street")
    }

    static func fresh(_ p: RentalPlatform) -> FeedFreshness {
        FeedFreshness(platform: p,
                      lastSuccess: DayMath.day(2026, 11, 11).addingTimeInterval(-600),
                      lastOutcome: .success)
    }

    public static var cases: [TestCase] { [

        // MARK: - 1. Confirmed reservations always protect the others

        TestCase(group: "Outbound policy",
                 name: "a confirmed reservation protects both other platforms") { expect in
            let policy = OutboundPolicy.default
            let reservation = item(.bookingCom, .confirmedReservation)
            expect.ok(policy.propagates(reservation, to: .airbnb))
            expect.ok(policy.propagates(reservation, to: .vrbo))
            expect.ok(!policy.propagates(reservation, to: .bookingCom),
                      "never back to its own source")
        },

        // MARK: - 3. Cancellation penalties never leave

        TestCase(group: "Outbound policy",
                 name: "an Airbnb cancellation penalty NEVER propagates") { expect in
            // The founding rule. These nights stay sellable everywhere else.
            let penalty = item(.airbnb, .cancellationBlock)
            for policy in [OutboundPolicy.default, OutboundPolicy.everything] {
                for destination in [RentalPlatform.vrbo, .bookingCom, .airbnb] {
                    expect.ok(!policy.propagates(penalty, to: destination),
                              "leaked to \(destination.displayName)")
                }
            }
        },

        TestCase(group: "Outbound policy",
                 name: "no configuration can switch cancellation penalties on") { expect in
            // Not a setting. A policy that could be configured to export these
            // would eventually be configured that way.
            var policy = OutboundPolicy.default
            policy.ownerBlockDestinations = [.airbnb, .vrbo, .bookingCom]
            policy.maintenanceDestinations = [.airbnb, .vrbo, .bookingCom]
            expect.ok(!policy.propagates(item(.airbnb, .cancellationBlock), to: .vrbo))
            expect.ok(!OutboundPolicy.exportableKinds.contains(.cancellationBlock))
        },

        // MARK: - 4 & 5. Undecided and booking windows stay put

        TestCase(group: "Outbound policy",
                 name: "unknown unavailable never propagates, and stays in review") { expect in
            let unknown = item(.bookingCom, .unknownUnavailable, needsReview: true)
            expect.ok(!OutboundPolicy.default.propagates(unknown, to: .airbnb))
            expect.ok(!OutboundPolicy.default.propagates(unknown, to: .vrbo))
            expect.equal(OutboundPolicy.default.decision(unknown, to: .airbnb),
                         .blocked(reason: .needsReview))
        },

        TestCase(group: "Outbound policy",
                 name: "a booking-window restriction never propagates") { expect in
            let window = item(.bookingCom, .platformRestriction)
            expect.ok(!OutboundPolicy.default.propagates(window, to: .airbnb))
            expect.equal(OutboundPolicy.default.decision(window, to: .airbnb),
                         .blocked(reason: .neverExportable))
        },

        // MARK: - 2 & 6. Owner and maintenance blocks are selectable

        TestCase(group: "Outbound policy",
                 name: "an owner block propagates to both by default") { expect in
            let block = item(.vrbo, .ownerBlock)
            expect.ok(OutboundPolicy.default.propagates(block, to: .airbnb))
            expect.ok(OutboundPolicy.default.propagates(block, to: .bookingCom))
        },

        TestCase(group: "Outbound policy",
                 name: "an owner block can be limited to chosen platforms") { expect in
            var policy = OutboundPolicy.default
            policy.ownerBlockDestinations = [.vrbo]
            let block = item(.airbnb, .ownerBlock)
            expect.ok(policy.propagates(block, to: .vrbo))
            expect.ok(!policy.propagates(block, to: .bookingCom))
            expect.equal(policy.decision(block, to: .bookingCom),
                         .blocked(reason: .destinationNotSelected))
        },

        TestCase(group: "Outbound policy",
                 name: "maintenance is opt-in, not on by default") { expect in
            // Requirement 6 says "only to platforms I select", so the default
            // selection is empty rather than everything.
            let maintenance = item(.vrbo, .maintenanceBlock)
            expect.ok(!OutboundPolicy.default.propagates(maintenance, to: .airbnb))
            expect.equal(OutboundPolicy.default.maintenanceDestinations, [])
            var policy = OutboundPolicy.default
            policy.maintenanceDestinations = [.airbnb]
            expect.ok(policy.propagates(maintenance, to: .airbnb))
            expect.ok(!policy.propagates(maintenance, to: .bookingCom))
        },

        // MARK: - Evidence gates propagation

        TestCase(group: "Outbound policy",
                 name: "an UNREVIEWED reservation does not propagate") { expect in
            // The Airbnb consequence: its export labels a booking, an owner
            // block and a cancellation penalty identically, so anything the
            // classifier could not settle arrives needing review — and
            // nothing undecided may protect another platform.
            let unsure = item(.airbnb, .confirmedReservation, needsReview: true)
            expect.ok(!OutboundPolicy.default.propagates(unsure, to: .vrbo))
            expect.equal(OutboundPolicy.default.decision(unsure, to: .vrbo),
                         .blocked(reason: .needsReview))
        },

        TestCase(group: "Outbound policy",
                 name: "an Airbnb owner block propagates only once a person decides") { expect in
            // Automatic: ambiguous, so no. Manually classified: yes.
            let automatic = item(.airbnb, .ownerBlock, needsReview: true)
            expect.ok(!OutboundPolicy.default.propagates(automatic, to: .vrbo))

            var decided = automatic
            decided.classification.needsReview = false
            decided.classification.source = .manual
            expect.ok(OutboundPolicy.default.propagates(decided, to: .vrbo))
        },

        TestCase(group: "Outbound policy",
                 name: "the exportable set matches the allow-list, not a copy of it") { expect in
            // Two lists that must agree would drift. This asserts they are the
            // same list.
            for kind in BlockKind.allCases {
                expect.equal(OutboundPolicy.exportableKinds.contains(kind),
                             kind.describesGenuineUnavailability,
                             "\(kind.rawValue) disagrees with the allow-list")
            }
        },

        // MARK: - 7. Checkout-exclusive

        TestCase(group: "Outbound policy",
                 name: "a propagated block covers the occupied nights only") { expect in
            let reservation = item(.bookingCom, .confirmedReservation,
                                   day(2026, 12, 11), day(2026, 12, 21))
            let nights = OutboundPolicy.protectedNights(of: reservation)
            expect.equal(nights.count, 10)
            expect.equal(nights.first, day(2026, 12, 11))
            expect.equal(nights.last, day(2026, 12, 20), "the 21st is released")
        },

        // MARK: - 9 & 10. Did it actually arrive

        TestCase(group: "Outbound delivery",
                 name: "a destination with no evidence is PENDING, never protected") { expect in
            let reservation = item(.bookingCom, .confirmedReservation)
            let status = DeliveryStatus.assess(
                item: reservation, destination: .airbnb,
                policy: .default, observedAtDestination: [],
                destinationFeed: FeedFreshness(platform: .airbnb,
                                               lastSuccess: day(2026, 11, 11), lastOutcome: .success),
                lastPublishFailed: false, now: day(2026, 11, 11))
            expect.equal(status, .pending)
        },

        TestCase(group: "Outbound delivery",
                 name: "evidence from the destination's own feed is PROTECTED") { expect in
            let reservation = item(.bookingCom, .confirmedReservation)
            let mirrored = item(.airbnb, .ownerBlock, day(2026, 12, 11), day(2026, 12, 21))
            let status = DeliveryStatus.assess(
                item: reservation, destination: .airbnb,
                policy: .default, observedAtDestination: [mirrored],
                destinationFeed: FeedFreshness(platform: .airbnb,
                                               lastSuccess: day(2026, 11, 11), lastOutcome: .success),
                lastPublishFailed: false, now: day(2026, 11, 11))
            expect.equal(status, .protected)
        },

        TestCase(group: "Outbound delivery",
                 name: "partial coverage at the destination is PENDING, not protected") { expect in
            let reservation = item(.bookingCom, .confirmedReservation)
            let half = item(.airbnb, .ownerBlock, day(2026, 12, 11), day(2026, 12, 15))
            let status = DeliveryStatus.assess(
                item: reservation, destination: .airbnb,
                policy: .default, observedAtDestination: [half],
                destinationFeed: FeedFreshness(platform: .airbnb,
                                               lastSuccess: day(2026, 11, 11), lastOutcome: .success),
                lastPublishFailed: false, now: day(2026, 11, 11))
            expect.equal(status, .pending)
        },

        TestCase(group: "Outbound delivery",
                 name: "a failed publication is FAILED, and says so") { expect in
            let reservation = item(.bookingCom, .confirmedReservation)
            let status = DeliveryStatus.assess(
                item: reservation, destination: .airbnb,
                policy: .default, observedAtDestination: [],
                destinationFeed: FeedFreshness(platform: .airbnb,
                                               lastSuccess: day(2026, 11, 11), lastOutcome: .success),
                lastPublishFailed: true, now: day(2026, 11, 11))
            expect.equal(status, .failed)
        },

        TestCase(group: "Outbound delivery",
                 name: "something needing review is NEEDS REVIEW at every destination") { expect in
            let unknown = item(.bookingCom, .unknownUnavailable, needsReview: true)
            for destination in [RentalPlatform.airbnb, .vrbo] {
                expect.equal(
                    DeliveryStatus.assess(
                        item: unknown, destination: destination,
                        policy: .default, observedAtDestination: [],
                        destinationFeed: FeedFreshness(platform: destination,
                                                       lastSuccess: day(2026, 11, 11),
                                                       lastOutcome: .success),
                        lastPublishFailed: false, now: day(2026, 11, 11)),
                    .needsReview)
            }
        },

        TestCase(group: "Outbound delivery",
                 name: "a stale destination feed cannot report PROTECTED") { expect in
            // Even with matching coverage, a stale feed is not evidence that
            // the block is there NOW.
            let reservation = item(.bookingCom, .confirmedReservation)
            let mirrored = item(.airbnb, .ownerBlock, day(2026, 12, 11), day(2026, 12, 21))
            let status = DeliveryStatus.assess(
                item: reservation, destination: .airbnb,
                policy: .default, observedAtDestination: [mirrored],
                destinationFeed: FeedFreshness(
                    platform: .airbnb,
                    lastSuccess: day(2026, 11, 11).addingTimeInterval(-24 * 3600),
                    lastOutcome: .success),
                lastPublishFailed: false, now: day(2026, 11, 11))
            expect.equal(status, .pending, "stale evidence is not evidence")
        },

        // MARK: - 8. Never reopen on its own

        // MARK: - 6. Coverage is not attribution

        TestCase(group: "Outbound attribution",
                 name: "an UNRELATED block covering the dates is NOT Protected") { expect in
            // The hole: a destination block that happens to cover the nights
            // proves the nights are busy there, not that our synchronisation
            // worked. If the owner later removes their unrelated block, the
            // nights reopen and we would still be reporting Protected.
            let reservation = item(.bookingCom, .confirmedReservation)
            var unrelated = item(.airbnb, .ownerBlock, needsReview: false, day(2026, 12, 11), day(2026, 12, 21))
            unrelated.event.uid = "someone-elses-block@airbnb.com"

            let result = DeliveryAssessment.assess(
                item: reservation, destination: .airbnb, policy: .default,
                observedAtDestination: [unrelated],
                publishedUID: "vrc-aaaa1111",
                destinationFeed: fresh(.airbnb),
                lastPublishFailed: false, now: day(2026, 11, 11))

            expect.ok(result.datesCovered, "the nights ARE busy there")
            expect.equal(result.attribution, .coverageAttributionUnverified)
            expect.ok(result.status != .protected,
                      "but that is not evidence our block arrived")
            expect.equal(result.status, .pending)
        },

        TestCase(group: "Outbound attribution",
                 name: "a block carrying OUR uid is Protected") { expect in
            let reservation = item(.bookingCom, .confirmedReservation)
            var mine = item(.airbnb, .ownerBlock, needsReview: false, day(2026, 12, 11), day(2026, 12, 21))
            mine.event.uid = "vrc-aaaa1111"

            let result = DeliveryAssessment.assess(
                item: reservation, destination: .airbnb, policy: .default,
                observedAtDestination: [mine],
                publishedUID: "vrc-aaaa1111",
                destinationFeed: fresh(.airbnb),
                lastPublishFailed: false, now: day(2026, 11, 11))
            expect.equal(result.attribution, .ours(uid: "vrc-aaaa1111"))
            expect.equal(result.status, .protected)
            expect.ok(result.datesCovered)
        },

        TestCase(group: "Outbound attribution",
                 name: "our uid present but covering the WRONG nights is not Protected") { expect in
            // A stale publication: our block is there, but it no longer covers
            // the stay — a shortened or shifted reservation.
            let reservation = item(.bookingCom, .confirmedReservation,
                                   needsReview: false,
                                   day(2026, 12, 11), day(2026, 12, 21))
            var mine = item(.airbnb, .ownerBlock, needsReview: false, day(2026, 12, 11), day(2026, 12, 15))
            mine.event.uid = "vrc-aaaa1111"

            let result = DeliveryAssessment.assess(
                item: reservation, destination: .airbnb, policy: .default,
                observedAtDestination: [mine],
                publishedUID: "vrc-aaaa1111",
                destinationFeed: fresh(.airbnb),
                lastPublishFailed: false, now: day(2026, 11, 11))
            expect.ok(!result.datesCovered)
            expect.equal(result.status, .pending)
        },

        TestCase(group: "Outbound attribution",
                 name: "nothing published yet means no attribution to claim") { expect in
            let reservation = item(.bookingCom, .confirmedReservation)
            let result = DeliveryAssessment.assess(
                item: reservation, destination: .airbnb, policy: .default,
                observedAtDestination: [], publishedUID: nil,
                destinationFeed: fresh(.airbnb),
                lastPublishFailed: false, now: day(2026, 11, 11))
            expect.equal(result.attribution, .none)
            expect.equal(result.status, .pending)
            expect.ok(!result.datesCovered)
        },

        TestCase(group: "Outbound attribution",
                 name: "unrelated coverage is reported, not silently discarded") { expect in
            // Worth telling the owner: the nights are busy there for a reason
            // we did not create, which they may want to look at.
            let reservation = item(.bookingCom, .confirmedReservation)
            var unrelated = item(.airbnb, .ownerBlock, needsReview: false, day(2026, 12, 11), day(2026, 12, 21))
            unrelated.event.uid = "manual-block@airbnb.com"
            let result = DeliveryAssessment.assess(
                item: reservation, destination: .airbnb, policy: .default,
                observedAtDestination: [unrelated], publishedUID: "vrc-aaaa1111",
                destinationFeed: fresh(.airbnb),
                lastPublishFailed: false, now: day(2026, 11, 11))
            expect.contains(result.explanation, "does not carry the identifier")
            expect.contains(result.explanation.lowercased(), "unavailable")
        },

        TestCase(group: "Outbound attribution",
                 name: "a cancellation penalty at the destination never counts as coverage") { expect in
            // It is not a hold anyone placed, and those nights stay sellable.
            let reservation = item(.bookingCom, .confirmedReservation)
            var penalty = item(.airbnb, .cancellationBlock, needsReview: false, day(2026, 12, 11), day(2026, 12, 21))
            penalty.event.uid = "penalty@airbnb.com"
            let result = DeliveryAssessment.assess(
                item: reservation, destination: .airbnb, policy: .default,
                observedAtDestination: [penalty], publishedUID: "vrc-aaaa1111",
                destinationFeed: fresh(.airbnb),
                lastPublishFailed: false, now: day(2026, 11, 11))
            expect.ok(!result.datesCovered)
            expect.equal(result.status, .pending)
        },

        TestCase(group: "Outbound delivery",
                 name: "a failed import never withdraws an existing protection") { expect in
            // The rule that matters most after a cancellation or an outage: a
            // feed that could not be read says nothing about whether a guest
            // is still staying.
            expect.ok(!OutboundPolicy.mayWithdraw(
                afterImportOutcome: .failure, sourceStillPresent: false))
            expect.ok(!OutboundPolicy.mayWithdraw(
                afterImportOutcome: .disconnected, sourceStillPresent: false))
            expect.ok(!OutboundPolicy.mayWithdraw(
                afterImportOutcome: .skipped, sourceStillPresent: false))
        },

        TestCase(group: "Outbound delivery",
                 name: "withdrawal needs a good import AND the source gone AND approval") { expect in
            // Even then it is a proposal, not an action: removals need the
            // owner, same as additions.
            expect.ok(OutboundPolicy.mayWithdraw(
                afterImportOutcome: .success, sourceStillPresent: false),
                      "only a successful import that no longer shows it")
            expect.ok(!OutboundPolicy.mayWithdraw(
                afterImportOutcome: .success, sourceStillPresent: true))
            expect.ok(OutboundPolicy.withdrawalRequiresApproval)
        },
    ] }
}
