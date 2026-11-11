import Foundation
import VRCCore

/// Whether a reservation's nights are actually protected elsewhere — and
/// whether the interface is entitled to call a night available.
///
/// Both come from the same mistake. A calendar that draws nothing for a night
/// is claiming it is free; a calendar that tints it green is claiming it
/// loudly. Neither is justified when the feed that would have reported a
/// booking is seventeen hours stale, which is exactly the state Airbnb and
/// Vrbo were in while a Booking.com reservation for 11–21 December sat
/// unprotected.
///
/// **No observation is not evidence of availability.** It is evidence of
/// nothing, and the difference has to survive all the way to the pixel.
public enum ProtectionStatusTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

    static func item(
        _ platform: RentalPlatform, _ ci: Date, _ co: Date, _ kind: BlockKind,
        needsReview: Bool = false, property: Int64 = 1
    ) -> ClassifiedEvent {
        let key = "p-\(platform.rawValue)-\(Int(ci.timeIntervalSince1970))-\(kind.rawValue)"
        return ClassifiedEvent(
            event: CalendarEvent(
                listingID: 1, eventKey: key, uid: key, platform: platform,
                summary: "synthetic", details: "", checkIn: ci, checkOut: co),
            classification: EventClassification(
                eventKey: key, kind: kind, confidence: .high,
                source: .automatic, needsReview: needsReview),
            listingLabel: platform.displayName, propertyID: property,
            propertyName: "39 G Street")
    }

    static let now = DayMath.day(2026, 11, 11)

    /// A feed fetched minutes ago.
    static func fresh(_ p: RentalPlatform) -> FeedFreshness {
        FeedFreshness(platform: p, lastSuccess: now.addingTimeInterval(-600), lastOutcome: .success)
    }
    /// A feed last fetched seventeen hours ago — the real state of Airbnb and
    /// Vrbo during the incident.
    static func stale(_ p: RentalPlatform) -> FeedFreshness {
        FeedFreshness(platform: p, lastSuccess: now.addingTimeInterval(-17 * 3600),
                      lastOutcome: .success)
    }
    static func failing(_ p: RentalPlatform) -> FeedFreshness {
        FeedFreshness(platform: p, lastSuccess: now.addingTimeInterval(-600),
                      lastOutcome: .failure)
    }
    static func never(_ p: RentalPlatform) -> FeedFreshness {
        FeedFreshness(platform: p, lastSuccess: nil, lastOutcome: nil)
    }

    public static var cases: [TestCase] { [

        // MARK: - A night is only "available" if something can vouch for it

        TestCase(group: "Protection",
                 name: "a fresh feed with no observation is genuinely available") { expect in
            let state = NightState.of(
                occupied: false, freshness: fresh(.airbnb), now: now)
            expect.equal(state, .available)
            expect.ok(state.isReassuring)
        },

        TestCase(group: "Protection",
                 name: "a STALE feed with no observation is unknown, never available") { expect in
            // The exact condition. Airbnb's feed was 17 hours old, so its
            // silence about 11-20 December meant nothing at all.
            let state = NightState.of(
                occupied: false, freshness: stale(.airbnb), now: now)
            expect.equal(state, .unknownStaleFeed)
            expect.ok(!state.isReassuring, "a stale feed must not read as green")
        },

        TestCase(group: "Protection",
                 name: "a failed or never-fetched feed is also unknown") { expect in
            for freshness in [failing(.vrbo), never(.vrbo)] {
                let state = NightState.of(occupied: false, freshness: freshness, now: now)
                expect.ok(!state.isReassuring, "\(freshness.lastOutcome.map(\.rawValue) ?? "never")")
                expect.equal(state, .unknownStaleFeed)
            }
        },

        TestCase(group: "Protection",
                 name: "an occupied night is occupied regardless of freshness") { expect in
            expect.equal(NightState.of(occupied: true, freshness: stale(.airbnb), now: now),
                         .occupied)
            expect.equal(NightState.of(occupied: true, freshness: fresh(.airbnb), now: now),
                         .occupied)
        },

        // MARK: - Destination protection, from the destinations' own feeds

        TestCase(group: "Protection",
                 name: "the December reservation is NOT protected on Airbnb or Vrbo") { expect in
            // The incident, as an assertion. Booking.com holds 11-21; neither
            // other platform covers those nights.
            let reservation = item(.bookingCom, day(2026, 12, 11), day(2026, 12, 21),
                                   .unknownUnavailable, needsReview: true)
            let assessment = ProtectionAssessment.assess(
                reservation: reservation,
                others: [item(.airbnb, day(2026, 12, 17), day(2026, 12, 19), .cancellationBlock)],
                freshness: [fresh(.airbnb), fresh(.vrbo), fresh(.bookingCom)],
                now: now)

            expect.equal(assessment.destinations.count, 2, "Airbnb and Vrbo")
            for destination in assessment.destinations {
                expect.equal(destination.state, .notCovered,
                             "\(destination.platform.displayName) must read as unprotected")
            }
            expect.ok(!assessment.isFullyProtected)
            expect.contains(assessment.headline, "Not protected")
            expect.contains(assessment.headline, "Airbnb")
            expect.contains(assessment.headline, "Vrbo")
        },

        TestCase(group: "Protection",
                 name: "a cancellation restriction does NOT count as protection") { expect in
            // Airbnb's 17-19 penalty overlaps the stay but covers only part of
            // it, and a penalty is not a hold anyone placed. Counting it would
            // report nights protected that are still for sale.
            let reservation = item(.bookingCom, day(2026, 12, 17), day(2026, 12, 19),
                                   .confirmedReservation)
            let assessment = ProtectionAssessment.assess(
                reservation: reservation,
                others: [item(.airbnb, day(2026, 12, 17), day(2026, 12, 19), .cancellationBlock)],
                freshness: [fresh(.airbnb), fresh(.vrbo), fresh(.bookingCom)],
                now: now)
            let airbnb = assessment.destinations.first { $0.platform == .airbnb }
            expect.equal(airbnb?.state, .notCovered,
                         "a cancellation penalty is not protection")
        },

        TestCase(group: "Protection",
                 name: "full coverage by a real block counts as protected") { expect in
            let reservation = item(.bookingCom, day(2026, 12, 11), day(2026, 12, 21),
                                   .confirmedReservation)
            let assessment = ProtectionAssessment.assess(
                reservation: reservation,
                others: [
                    item(.airbnb, day(2026, 12, 11), day(2026, 12, 21), .ownerBlock),
                    item(.vrbo, day(2026, 12, 10), day(2026, 12, 22), .ownerBlock),
                ],
                freshness: [fresh(.airbnb), fresh(.vrbo), fresh(.bookingCom)],
                now: now)
            expect.ok(assessment.isFullyProtected)
            expect.contains(assessment.headline, "Protected")
        },

        TestCase(group: "Protection",
                 name: "partial coverage is NOT protection") { expect in
            // Airbnb blocks only half the stay. Reporting that as protected
            // would leave the other half quietly sellable.
            let reservation = item(.bookingCom, day(2026, 12, 11), day(2026, 12, 21),
                                   .confirmedReservation)
            let assessment = ProtectionAssessment.assess(
                reservation: reservation,
                others: [item(.airbnb, day(2026, 12, 11), day(2026, 12, 15), .ownerBlock)],
                freshness: [fresh(.airbnb), fresh(.vrbo), fresh(.bookingCom)],
                now: now)
            let airbnb = assessment.destinations.first { $0.platform == .airbnb }
            expect.equal(airbnb?.state, .notCovered)
            expect.ok(!assessment.isFullyProtected)
        },

        TestCase(group: "Protection",
                 name: "a stale destination feed is UNVERIFIED, not protected and not clear") { expect in
            // The honest third answer. We cannot say either way, and saying
            // either would be a guess.
            let reservation = item(.bookingCom, day(2026, 12, 11), day(2026, 12, 21),
                                   .confirmedReservation)
            let assessment = ProtectionAssessment.assess(
                reservation: reservation,
                others: [item(.airbnb, day(2026, 12, 11), day(2026, 12, 21), .ownerBlock)],
                freshness: [stale(.airbnb), fresh(.vrbo), fresh(.bookingCom)],
                now: now)
            let airbnb = assessment.destinations.first { $0.platform == .airbnb }
            guard case .unverified = airbnb?.state else {
                return expect.fail("expected unverified, got \(String(describing: airbnb?.state))")
            }
            expect.ok(!assessment.isFullyProtected, "unverified is never protected")
            expect.contains(assessment.headline, "Unverified")
        },

        TestCase(group: "Protection",
                 name: "outbound being disabled is stated, not implied") { expect in
            // Nothing in this app pushes availability. The panel must say so
            // rather than leave a person assuming the app is handling it.
            expect.ok(!OutboundSyncGate.isEnabled)
            expect.contains(ProtectionAssessment.mechanismNote, "not")
            expect.ok(ProtectionAssessment.mechanismNote.lowercased().contains("manually")
                   || ProtectionAssessment.mechanismNote.lowercased().contains("directly"),
                      "it must say where protection actually comes from")
        },

        TestCase(group: "Protection",
                 name: "the source platform is never assessed against itself") { expect in
            let reservation = item(.vrbo, day(2026, 12, 11), day(2026, 12, 21),
                                   .confirmedReservation)
            let assessment = ProtectionAssessment.assess(
                reservation: reservation, others: [],
                freshness: [fresh(.airbnb), fresh(.vrbo), fresh(.bookingCom)], now: now)
            expect.ok(!assessment.destinations.contains { $0.platform == .vrbo })
            expect.equal(assessment.destinations.count, 2)
        },

        TestCase(group: "Protection",
                 name: "freshness has a stated threshold, not a vibe") { expect in
            expect.equal(FeedFreshness.staleAfter, 3 * 3600, "three hours")
            let borderline = FeedFreshness(
                platform: .airbnb,
                lastSuccess: now.addingTimeInterval(-FeedFreshness.staleAfter - 1),
                lastOutcome: .success)
            expect.ok(borderline.isStale(now: now))
            let justInside = FeedFreshness(
                platform: .airbnb,
                lastSuccess: now.addingTimeInterval(-FeedFreshness.staleAfter + 60),
                lastOutcome: .success)
            expect.ok(!justInside.isStale(now: now))
        },
    ] }
}
