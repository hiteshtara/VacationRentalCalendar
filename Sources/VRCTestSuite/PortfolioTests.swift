import Foundation
import VRCCore

/// The portfolio view's data, and the calendar behaviour a reviewer would
/// otherwise have to check by eye.
///
/// These exist because "I looked at it and it seemed right" does not survive a
/// refactor. Everything here is a property of the layout engine or the
/// portfolio rollup, both of which live in `VRCCore` precisely so they can be
/// asserted without a running app. What genuinely cannot be automated here —
/// colour, contrast, truncation, whether a bar *looks* continuous — is listed
/// in HANDOFF §22 as requiring visual inspection.
public enum PortfolioTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

    static func event(
        _ key: String, _ platform: RentalPlatform, _ kind: BlockKind,
        _ from: (Int, Int, Int), _ to: (Int, Int, Int),
        propertyID: Int64 = 1, propertyName: String = "39 G Street"
    ) -> ClassifiedEvent {
        ClassifiedEvent(
            event: CalendarEvent(
                listingID: propertyID, eventKey: key, uid: key, platform: platform,
                summary: kind == .confirmedReservation ? "Reserved" : "CLOSED - Not available",
                checkIn: day(from.0, from.1, from.2), checkOut: day(to.0, to.1, to.2)),
            classification: EventClassification(
                eventKey: key, kind: kind, confidence: .high, source: .automatic,
                needsReview: kind == .unknownUnavailable),
            listingLabel: platform.displayName,
            propertyID: propertyID, propertyName: propertyName)
    }

    /// Every week row a multi-week bar touches, in order.
    static func weeks(from: Date, count: Int, events: [ClassifiedEvent]) -> [WeekLayout] {
        (0..<count).map {
            CalendarLayout.layout(weekStart: DayMath.adding(days: $0 * 7, to: from), events: events)
        }
    }

    public static var cases: [TestCase] { [

        // --- Multi-week and multi-month continuity ----------------------------

        TestCase(group: "Portfolio",
                 name: "a multi-week bar is capped only at its real ends") { expect in
            // The visual claim "the bar runs continuously" reduces to this:
            // only the first segment is a start and only the last is an end.
            // Every middle week must be open at both sides, or the bar reads
            // as several separate stays.
            let long = event("long", .airbnb, .confirmedReservation, (2027, 6, 2), (2027, 6, 23))
            let rows = weeks(from: day(2027, 5, 30), count: 4, events: [long])
            let segments = rows.compactMap { $0.segments.first }
            expect.equal(segments.count, 4, "it should appear in all four week rows")
            expect.ok(segments[0].isStart, "capped at the true start")
            expect.ok(!segments[0].isEnd)
            expect.ok(!segments[1].isStart && !segments[1].isEnd, "middle week is open both sides")
            expect.ok(!segments[2].isStart && !segments[2].isEnd)
            expect.ok(segments[3].isEnd, "capped at the true end")
            expect.ok(!segments[3].isStart)
        },

        TestCase(group: "Portfolio",
                 name: "a bar spanning a month boundary is continuous across it") { expect in
            // Booking.com's live export has 2027-04-01 to 2028-05-10 on it, so
            // this is not hypothetical: a bar crossing December into January
            // must not restart.
            let across = event("across", .bookingCom, .unknownUnavailable,
                               (2026, 12, 28), (2027, 1, 6))
            let rows = weeks(from: day(2026, 12, 27), count: 2, events: [across])
            let segments = rows.compactMap { $0.segments.first }
            expect.equal(segments.count, 2)
            expect.ok(segments[0].isStart && !segments[0].isEnd,
                      "December week opens the bar and leaves it open")
            expect.ok(segments[1].isEnd && !segments[1].isStart,
                      "January week closes it without re-opening it")
        },

        // --- Checkout-exclusive ------------------------------------------------

        TestCase(group: "Portfolio",
                 name: "checkout day is not drawn as occupied") { expect in
            // DTEND is exclusive. A 1st-to-5th stay occupies four nights, and
            // the 5th belongs to whoever arrives that day.
            let stay = event("stay", .vrbo, .confirmedReservation, (2027, 8, 1), (2027, 8, 5))
            let row = CalendarLayout.layout(weekStart: day(2027, 8, 1), events: [stay])
            let segment = row.segments.first
            expect.equal(segment?.startColumn, 0, "Sunday the 1st")
            expect.equal(segment?.endColumn, 3, "through Wednesday the 4th, not Thursday")
            expect.equal(segment?.columnSpan, 4, "four nights, not five")
        },

        TestCase(group: "Portfolio",
                 name: "an arrival on another stay's checkout day shares a lane") { expect in
            // The visual consequence of the rule above: back-to-back stays sit
            // on one row rather than stacking, because they never overlap.
            let out = event("out", .airbnb, .confirmedReservation, (2027, 8, 1), (2027, 8, 5))
            let into = event("in", .vrbo, .confirmedReservation, (2027, 8, 5), (2027, 8, 8))
            let row = CalendarLayout.layout(weekStart: day(2027, 8, 1), events: [out, into])
            expect.equal(row.laneCount, 1, "no overlap, so no stacking")
            expect.equal(row.segments.count, 2)
        },

        // --- Overlapping platforms ---------------------------------------------

        TestCase(group: "Portfolio",
                 name: "three platforms overlapping stay separately identifiable") { expect in
            // Each keeps its own lane and its own event key, so the view can
            // colour them per platform and the owner can tell them apart.
            let a = event("a", .airbnb, .confirmedReservation, (2027, 8, 2), (2027, 8, 6))
            let v = event("v", .vrbo, .ownerBlock, (2027, 8, 3), (2027, 8, 7))
            let b = event("b", .bookingCom, .unknownUnavailable, (2027, 8, 4), (2027, 8, 8))
            let row = CalendarLayout.layout(weekStart: day(2027, 8, 1), events: [a, v, b])
            expect.equal(row.laneCount, 3, "all three overlap, so none may share a lane")
            expect.equal(Set(row.segments.map(\.eventKey)).count, 3,
                         "each keeps its own identity")
            expect.equal(Set(row.segments.map(\.lane)).count, 3)
        },

        // --- Booking.com CLOSED -------------------------------------------------

        TestCase(group: "Portfolio",
                 name: "a Booking.com CLOSED observation is unknown, never a reservation") { expect in
            // The live feed sends `CLOSED - Not available` for reservations AND
            // for owner blocks, identically. Treating one as a confirmed
            // booking would be guessing, and this is the single rule the
            // project exists to protect.
            let closed = event("closed", .bookingCom, .unknownUnavailable,
                               (2026, 11, 10), (2026, 12, 1))
            expect.equal(closed.classification.kind, .unknownUnavailable)
            expect.ok(closed.classification.needsReview, "it lands in the review queue")
            expect.ok(!closed.classification.kind.describesGenuineUnavailability,
                      "and is never exported anywhere")
            let row = CalendarLayout.layout(weekStart: day(2026, 11, 8), events: [closed])
            expect.equal(row.segments.count, 1, "it is still DRAWN — hidden is not the same as unexported")
        },

        // --- Portfolio rollup ---------------------------------------------------

        TestCase(group: "Portfolio",
                 name: "the portfolio summarises each property independently") { expect in
            let store = try RentalStore.makeInMemory()
            var ids: [String: Int64] = [:]
            for name in ["39 G Street", "Harbour Cottage"] {
                let property = try store.properties.insert(Property(name: name))
                ids[name] = property.id!
                let listing = try store.listings.insert(PlatformListing(
                    propertyID: property.id!, platform: .airbnb, label: "Airbnb",
                    icalURL: "https://example.test/\(name).ics", urlStorage: .database))
                let key = "e-\(name)"
                try store.events.upsert(CalendarEvent(
                    listingID: listing.id!, eventKey: key, uid: key, platform: .airbnb,
                    summary: "Blocked", checkIn: day(2027, 7, 1), checkOut: day(2027, 7, 8)))
                try store.classifications.save(EventClassification(
                    eventKey: key, kind: name == "Harbour Cottage" ? .unknownUnavailable : .ownerBlock,
                    confidence: .high, source: .automatic,
                    needsReview: name == "Harbour Cottage"))
            }

            let rows = try store.portfolio()
            expect.equal(rows.count, 2)
            let harbour = rows.first { $0.property.name == "Harbour Cottage" }
            let gStreet = rows.first { $0.property.name == "39 G Street" }
            expect.equal(harbour?.needsReviewCount, 1, "only Harbour Cottage has a review item")
            expect.equal(gStreet?.needsReviewCount, 0)
            expect.equal(harbour?.activeEventCount, 1)
            expect.equal(gStreet?.listingCount, 1)
        },

        TestCase(group: "Portfolio",
                 name: "an archived property is out of the portfolio but keeps its data") { expect in
            let store = try RentalStore.makeInMemory()
            let kept = try store.properties.insert(Property(name: "39 G Street"))
            let gone = try store.properties.insert(Property(name: "Old Flat"))
            try store.properties.archive(id: gone.id!, at: Date())

            let rows = try store.portfolio()
            expect.equal(rows.count, 1, "archived properties are not in the portfolio")
            expect.equal(rows.first?.property.id, kept.id)
            expect.ok(try store.properties.find(id: gone.id!) != nil, "but the record survives")
        },
        // --- Portfolio month strip ---------------------------------------------

        TestCase(group: "Portfolio",
                 name: "a month strip draws one continuous bar, not one per week") { expect in
            // The portfolio compares properties on the same DATE, so its bars
            // run the width of the month rather than resetting every Sunday.
            let long = event("long", .airbnb, .confirmedReservation, (2027, 6, 2), (2027, 6, 23))
            let bars = CalendarLayout.monthStrip(
                monthStart: day(2027, 6, 1), dayCount: 30, events: [long])
            expect.equal(bars.count, 1, "one event, one bar")
            expect.equal(bars.first?.startColumn, 1, "the 2nd is column 1")
            expect.equal(bars.first?.columnSpan, 21, "2nd to 22nd inclusive — checkout excluded")
            expect.ok(!(bars.first?.isClippedAtStart ?? true))
            expect.ok(!(bars.first?.isClippedAtEnd ?? true))
        },

        TestCase(group: "Portfolio",
                 name: "a bar overrunning the month is clipped and says so") { expect in
            // Booking.com's live export runs 2027-04-01 to 2028-05-10. Viewed
            // in any middle month it must fill the strip and be marked clipped
            // at both ends, so the view does not cap it like a real boundary.
            let huge = event("huge", .bookingCom, .unknownUnavailable,
                             (2027, 4, 1), (2028, 5, 10))
            let bars = CalendarLayout.monthStrip(
                monthStart: day(2027, 9, 1), dayCount: 30, events: [huge])
            expect.equal(bars.count, 1)
            expect.equal(bars.first?.startColumn, 0)
            expect.equal(bars.first?.columnSpan, 30, "it covers every day of September")
            expect.ok(bars.first?.isClippedAtStart == true)
            expect.ok(bars.first?.isClippedAtEnd == true)
        },

        TestCase(group: "Portfolio",
                 name: "strip lanes follow the same checkout-exclusive rule") { expect in
            let out = event("out", .airbnb, .confirmedReservation, (2027, 8, 1), (2027, 8, 5))
            let into = event("in", .vrbo, .confirmedReservation, (2027, 8, 5), (2027, 8, 9))
            let overlapping = event("ov", .bookingCom, .ownerBlock, (2027, 8, 3), (2027, 8, 7))
            let bars = CalendarLayout.monthStrip(
                monthStart: day(2027, 8, 1), dayCount: 31, events: [out, into, overlapping])
            let byKey = Dictionary(uniqueKeysWithValues: bars.map { ($0.eventKey, $0) })
            expect.equal(byKey["out"]?.lane, byKey["in"]?.lane,
                         "back-to-back stays share a lane")
            expect.ok(byKey["ov"]?.lane != byKey["out"]?.lane,
                      "the overlapping block needs its own")
        },

        TestCase(group: "Portfolio",
                 name: "an event outside the month produces no bar at all") { expect in
            let elsewhere = event("x", .vrbo, .ownerBlock, (2027, 3, 1), (2027, 3, 5))
            expect.equal(CalendarLayout.monthStrip(
                monthStart: day(2027, 8, 1), dayCount: 31, events: [elsewhere]).count, 0)
        },
    ] }
}
