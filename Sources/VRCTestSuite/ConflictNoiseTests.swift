import Foundation
import VRCCore

/// A conflict has to be actionable, or it is noise that hides the real ones.
///
/// 39 G Street reported **nine conflicts** with nothing booked on any
/// platform. Every one of its observations is a `cancellationBlock` — nights
/// Airbnb closed after a host cancellation, which this app deliberately keeps
/// on sale. Two of those overlapping is not a collision: neither one claims
/// the property is occupied, so there is nothing to resolve and nothing the
/// owner can do about it.
///
/// Worse than useless: the portfolio marked the property "needs attention",
/// and a genuine double booking would have been the tenth row in a list of
/// nine false ones.
///
/// The rule: a pair is only a conflict if **at least one** side actually
/// asserts the property is unavailable. `describesGenuineUnavailability` is
/// already the single source of truth for that, so this reuses it rather than
/// inventing a second list.
public enum ConflictNoiseTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

    static func event(
        _ key: String, _ platform: RentalPlatform, _ kind: BlockKind,
        _ from: (Int, Int, Int), _ to: (Int, Int, Int)
    ) -> ClassifiedEvent {
        ClassifiedEvent(
            event: CalendarEvent(
                listingID: platform == .airbnb ? 1 : (platform == .vrbo ? 2 : 3),
                eventKey: key, uid: key, platform: platform, summary: "x",
                checkIn: day(from.0, from.1, from.2), checkOut: day(to.0, to.1, to.2)),
            classification: EventClassification(
                eventKey: key, kind: kind, confidence: .high, source: .manual,
                needsReview: false),
            listingLabel: platform.displayName, propertyID: 1, propertyName: "39 G Street")
    }

    static func conflicts(_ events: [ClassifiedEvent]) -> [ReservationConflict] {
        ConflictDetector().detect(in: events)
    }

    public static var cases: [TestCase] { [

        TestCase(group: "Conflict noise",
                 name: "two overlapping cancellation blocks are not a conflict") { expect in
            // The exact shape that produced nine false conflicts.
            let a = event("a", .vrbo, .cancellationBlock, (2026, 11, 1), (2026, 11, 30))
            let b = event("b", .airbnb, .cancellationBlock, (2026, 11, 8), (2026, 11, 15))
            expect.equal(conflicts([a, b]).count, 0,
                         "neither claims the property is occupied")
        },

        TestCase(group: "Conflict noise",
                 name: "overlapping unknown blocks are not a conflict either") { expect in
            // Booking.com sends CLOSED for bookings AND owner blocks alike, so
            // unknowns overlap constantly. They belong in the review queue, not
            // in the conflicts list.
            let a = event("a", .bookingCom, .unknownUnavailable, (2027, 4, 1), (2028, 5, 10))
            let b = event("b", .vrbo, .unknownUnavailable, (2027, 4, 1), (2029, 1, 1))
            expect.equal(conflicts([a, b]).count, 0)
        },

        TestCase(group: "Conflict noise",
                 name: "a real double booking is still reported") { expect in
            // The case the whole detector exists for. If this ever stops
            // firing, the change has gone too far.
            let a = event("a", .airbnb, .confirmedReservation, (2027, 7, 1), (2027, 7, 8))
            let b = event("b", .vrbo, .confirmedReservation, (2027, 7, 5), (2027, 7, 12))
            let found = conflicts([a, b])
            expect.equal(found.count, 1)
            expect.equal(found.first?.severity, .doubleBooking)
        },

        TestCase(group: "Conflict noise",
                 name: "a reservation overlapping a cancellation block is still reported") { expect in
            // Only ONE side needs to assert unavailability. A confirmed
            // reservation sitting under dates another platform cancelled is
            // exactly the situation worth a human look.
            let real = event("r", .airbnb, .confirmedReservation, (2027, 7, 1), (2027, 7, 8))
            let cancelled = event("c", .vrbo, .cancellationBlock, (2027, 7, 3), (2027, 7, 10))
            expect.equal(conflicts([real, cancelled]).count, 1,
                         "the reservation side makes it actionable")
        },

        TestCase(group: "Conflict noise",
                 name: "two genuine blocks overlapping are still reported") { expect in
            // Owner and maintenance blocks DO assert unavailability, so two of
            // them overlapping is a real double-held range worth seeing.
            let owner = event("o", .vrbo, .ownerBlock, (2027, 7, 1), (2027, 7, 8))
            let maintenance = event("m", .airbnb, .maintenanceBlock, (2027, 7, 3), (2027, 7, 10))
            expect.equal(conflicts([owner, maintenance]).count, 1)
        },

        TestCase(group: "Conflict noise",
                 name: "the rule follows describesGenuineUnavailability, not a second list") { expect in
            // Stated directly so a new BlockKind is governed by the allow-list
            // that already decides everything else, rather than being forgotten
            // here.
            let reservation = event("r", .airbnb, .confirmedReservation, (2027, 7, 1), (2027, 7, 8))
            for kind in BlockKind.allCases {
                let other = event("o", .vrbo, kind, (2027, 7, 3), (2027, 7, 10))
                let pairWithReservation = conflicts([reservation, other])
                expect.equal(pairWithReservation.count, 1,
                             "\(kind.rawValue) against a reservation is always actionable")

                let quiet = event("q", .bookingCom, kind, (2027, 7, 4), (2027, 7, 9))
                let pairAlone = conflicts([other, quiet])
                expect.equal(pairAlone.count, kind.describesGenuineUnavailability ? 1 : 0,
                             "\(kind.rawValue) overlapping itself: "
                                + "conflict only if it asserts unavailability")
            }
        },

        TestCase(group: "Conflict noise",
                 name: "39 G Street's real data produces no conflicts") { expect in
            // The live observations as of 2026-11-10: nine cancellation blocks
            // across three platforms, heavily overlapping. Before the fix this
            // produced nine conflicts and a "needs attention" flag on a
            // property with nothing booked.
            let live = [
                event("v1", .vrbo, .cancellationBlock, (2026, 11, 1), (2026, 11, 2)),
                event("v2", .vrbo, .cancellationBlock, (2026, 11, 1), (2026, 11, 30)),
                event("a1", .airbnb, .cancellationBlock, (2026, 11, 8), (2026, 11, 15)),
                event("b1", .bookingCom, .cancellationBlock, (2026, 11, 10), (2026, 12, 1)),
                event("a2", .airbnb, .cancellationBlock, (2026, 12, 17), (2026, 12, 19)),
                event("b2", .bookingCom, .cancellationBlock, (2027, 4, 1), (2028, 5, 10)),
                event("v3", .vrbo, .cancellationBlock, (2027, 4, 1), (2029, 1, 1)),
                event("a3", .airbnb, .cancellationBlock, (2027, 4, 17), (2027, 4, 20)),
                event("a4", .airbnb, .cancellationBlock, (2027, 5, 1), (2027, 11, 11)),
            ]
            expect.equal(conflicts(live).count, 0,
                         "nothing is booked, so nothing collides")
        },
    ] }
}
