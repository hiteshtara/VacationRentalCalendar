import Foundation
import VRCCore

/// Geometry for the multi-property timeline.
///
/// A month grid breaks a stay at every month boundary, has nowhere to put a
/// platform label, and leaves a cell blank when it has nothing to draw — which
/// on a calendar reads as "free". That last property is what let a confirmed
/// Booking.com reservation for 11–21 December 2026 render as empty space.
///
/// All synthetic.
public enum TimelineLayoutTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

    static func item(
        _ platform: RentalPlatform, _ ci: Date, _ co: Date, _ kind: BlockKind,
        needsReview: Bool = false, property: Int64 = 1, key: String = ""
    ) -> ClassifiedEvent {
        let k = key.isEmpty
            ? "k-\(platform.rawValue)-\(Int(ci.timeIntervalSince1970))-\(kind.rawValue)"
            : key
        return ClassifiedEvent(
            event: CalendarEvent(
                listingID: 1, eventKey: k, uid: k, platform: platform,
                summary: "synthetic", details: "", checkIn: ci, checkOut: co),
            classification: EventClassification(
                eventKey: k, kind: kind, confidence: .high,
                source: .automatic, needsReview: needsReview),
            listingLabel: "\(platform.displayName)", propertyID: property,
            propertyName: property == 1 ? "39 G Street" : "Test Cottage")
    }

    static let properties: [(id: Int64, name: String)] = [
        (1, "39 G Street"), (2, "Test Cottage"),
    ]

    /// December window: 1 Dec 2026 for 31 nights.
    static func december(_ items: [ClassifiedEvent]) -> TimelineLayout {
        TimelineLayout.build(items: items, properties: properties,
                             windowStart: day(2026, 12, 1), nightCount: 31)
    }

    public static var cases: [TestCase] { [

        TestCase(group: "Timeline",
                 name: "a stay spans exactly its occupied nights, checkout exclusive") { expect in
            // 11 -> 21 December occupies ten nights and frees the 21st.
            let layout = december([item(.bookingCom, day(2026, 12, 11), day(2026, 12, 21),
                                        .unknownUnavailable, needsReview: true)])
            guard let bar = layout.rows.first?.bars.first else { return expect.fail("no bar") }
            expect.equal(bar.startColumn, 10, "1 Dec is column 0, so 11 Dec is column 10")
            expect.equal(bar.columnCount, 10, "ten nights")
            expect.equal(bar.endColumn, 19, "last occupied night is 20 Dec")
            expect.ok(!layout.isOccupied(row: 0, column: 20), "21 Dec is free to sell")
        },

        TestCase(group: "Timeline",
                 name: "an undecided reservation is a bar, never empty space") { expect in
            let layout = december([item(.bookingCom, day(2026, 12, 11), day(2026, 12, 21),
                                        .unknownUnavailable, needsReview: true)])
            expect.equal(layout.rows.first?.bars.count, 1)
            expect.equal(layout.rows.first?.bars.first?.emphasis, .undecided)
            for column in 10...19 {
                expect.ok(layout.isOccupied(row: 0, column: column),
                          "night at column \(column) must read as occupied")
            }
        },

        TestCase(group: "Timeline",
                 name: "overlapping stays stack into lanes instead of hiding") { expect in
            // The real overlap: Booking.com 11-21 and the Airbnb cancellation
            // penalty 17-19. Both must be on screen.
            let layout = december([
                item(.bookingCom, day(2026, 12, 11), day(2026, 12, 21),
                     .unknownUnavailable, needsReview: true),
                item(.airbnb, day(2026, 12, 17), day(2026, 12, 19), .cancellationBlock),
            ])
            guard let row = layout.rows.first else { return expect.fail("no row") }
            expect.equal(row.bars.count, 2, "neither may be dropped")
            expect.equal(Set(row.bars.map(\.lane)), [0, 1], "they must not share a lane")
            expect.equal(row.laneCount, 2)
            expect.equal(Set(row.bars.map(\.emphasis)), [.undecided, .cancellationPenalty])
        },

        TestCase(group: "Timeline",
                 name: "non-overlapping stays reuse the same lane") { expect in
            let layout = december([
                item(.airbnb, day(2026, 12, 2), day(2026, 12, 5), .confirmedReservation),
                item(.vrbo, day(2026, 12, 10), day(2026, 12, 14), .confirmedReservation),
            ])
            expect.equal(layout.rows.first?.laneCount, 1, "no need to stack")
        },

        TestCase(group: "Timeline",
                 name: "a same-day turnover packs into one lane with no gap and no overlap") { expect in
            // Checkout on the 14th, next check-in the same day. The nights do
            // not overlap, so stacking them would waste a row for nothing —
            // compact packing is what a timeline is for. The join has to be
            // legible, but that is the job of the bar's ends, not of geometry:
            // the two bars must END and BEGIN on consecutive columns with
            // neither a shared column nor a blank one between them.
            //
            // An earlier version of this test asserted two lanes. That was my
            // expectation being wrong rather than the layout: it would have
            // doubled the height of every row with back-to-back bookings.
            let layout = december([
                item(.airbnb, day(2026, 12, 11), day(2026, 12, 14), .confirmedReservation),
                item(.vrbo, day(2026, 12, 14), day(2026, 12, 17), .confirmedReservation),
            ])
            guard let row = layout.rows.first else { return expect.fail("no row") }
            expect.equal(row.bars.count, 2)
            expect.equal(row.bars[0].endColumn, 12, "13 Dec is the last night of the first")
            expect.equal(row.bars[1].startColumn, 13, "14 Dec begins the second")
            expect.equal(row.laneCount, 1, "no wasted vertical space")
            expect.equal(row.bars[1].startColumn - row.bars[0].endColumn, 1,
                         "consecutive: no shared night and no empty column between")
            // And every night from the 11th to the 16th reads as occupied.
            for column in 10...15 {
                expect.ok(layout.isOccupied(row: 0, column: column), "column \(column)")
            }
            expect.ok(!layout.isOccupied(row: 0, column: 16), "17 Dec is free")
        },

        TestCase(group: "Timeline",
                 name: "a stay crossing a month boundary stays ONE bar") { expect in
            // 28 Dec -> 4 Jan. A month grid breaks this in two; a timeline
            // must not.
            let layout = december([item(.vrbo, day(2026, 12, 28), day(2027, 1, 4),
                                        .confirmedReservation)])
            guard let bar = layout.rows.first?.bars.first else { return expect.fail("no bar") }
            expect.equal(layout.rows.first?.bars.count, 1, "one stay, one bar")
            expect.equal(bar.startColumn, 27, "28 Dec")
            expect.equal(bar.endColumn, 30, "clipped at 31 Dec, the window edge")
            expect.ok(bar.continuesAfter, "and marked as continuing past the edge")
            expect.ok(!bar.continuesBefore)
        },

        TestCase(group: "Timeline",
                 name: "a stay starting before the window is clipped, not dropped") { expect in
            let layout = december([item(.airbnb, day(2026, 11, 25), day(2026, 12, 4),
                                        .confirmedReservation)])
            guard let bar = layout.rows.first?.bars.first else { return expect.fail("no bar") }
            expect.equal(bar.startColumn, 0)
            expect.equal(bar.endColumn, 2, "3 Dec is the last occupied night")
            expect.ok(bar.continuesBefore)
            expect.ok(!bar.continuesAfter)
        },

        TestCase(group: "Timeline",
                 name: "a stay entirely outside the window is absent, not clipped to zero") { expect in
            let layout = december([item(.airbnb, day(2027, 3, 1), day(2027, 3, 5),
                                        .confirmedReservation)])
            expect.equal(layout.rows.first?.bars.count, 0)
            expect.equal(layout.rows.first?.laneCount, 1, "the row still has height")
        },

        TestCase(group: "Timeline",
                 name: "multiple properties each get their own row") { expect in
            let layout = december([
                item(.bookingCom, day(2026, 12, 11), day(2026, 12, 21),
                     .unknownUnavailable, needsReview: true, property: 1),
                item(.airbnb, day(2026, 12, 5), day(2026, 12, 9),
                     .confirmedReservation, property: 2),
            ])
            expect.equal(layout.rows.count, 2)
            expect.equal(layout.rows[0].propertyName, "39 G Street")
            expect.equal(layout.rows[0].bars.count, 1)
            expect.equal(layout.rows[1].propertyName, "Test Cottage")
            expect.equal(layout.rows[1].bars.count, 1)
            expect.ok(!layout.isOccupied(row: 1, column: 10),
                      "one property's booking must not shade another's nights")
        },

        TestCase(group: "Timeline",
                 name: "a property with nothing booked still has a row") { expect in
            let layout = december([])
            expect.equal(layout.rows.count, 2)
            for row in layout.rows {
                expect.equal(row.bars.count, 0)
                expect.equal(row.laneCount, 1, "visibly empty, not absent")
            }
        },

        TestCase(group: "Timeline",
                 name: "every kind of unavailability produces a bar") { expect in
            // The safety property, at the geometry level: nothing a platform
            // reports can end up as blank space.
            for kind in BlockKind.allCases {
                for needsReview in [true, false] {
                    let layout = december([item(.airbnb, day(2026, 12, 11), day(2026, 12, 13),
                                                kind, needsReview: needsReview)])
                    expect.equal(layout.rows.first?.bars.count, 1,
                                 "\(kind.rawValue)/review=\(needsReview) vanished")
                    expect.ok(layout.isOccupied(row: 0, column: 10))
                }
            }
        },

        TestCase(group: "Timeline",
                 name: "the window is exactly the nights asked for") { expect in
            let layout = december([])
            expect.equal(layout.nights.count, 31)
            expect.equal(layout.nights.first, day(2026, 12, 1))
            expect.equal(layout.nights.last, day(2026, 12, 31))
        },

        TestCase(group: "Timeline",
                 name: "a long stay stays readable: one bar, clipped at both edges") { expect in
            // The 406-night booking-window edge. It must not be dropped and
            // must not swamp the row with repeated bars.
            let layout = december([item(.bookingCom, day(2026, 4, 1), day(2028, 5, 11),
                                        .platformRestriction)])
            guard let bar = layout.rows.first?.bars.first else { return expect.fail("no bar") }
            expect.equal(layout.rows.first?.bars.count, 1)
            expect.equal(bar.startColumn, 0)
            expect.equal(bar.columnCount, 31, "spans the whole window")
            expect.ok(bar.continuesBefore)
            expect.ok(bar.continuesAfter)
            expect.equal(bar.emphasis, .bookingWindow, "quietest treatment, still drawn")
        },
    ] }
}
