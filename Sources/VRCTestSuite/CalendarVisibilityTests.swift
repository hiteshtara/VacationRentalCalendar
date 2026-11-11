import Foundation
import VRCCore

/// The calendar must never imply a night is free when a platform says it is not.
///
/// The defect, 2026-11-11: a confirmed Booking.com reservation for 11–21
/// December 2026 imported correctly, was linked to the right property, and
/// appeared in Needs Review — and the month view drew **nothing** for those
/// dates. Blank is indistinguishable from available on a calendar, so the one
/// thing the application exists to prevent was the thing its main view
/// implied was safe.
///
/// The cause was `calendarEvents`, which hid `.needsReview` and `.unknown`
/// unless a toggle was on, and the toggle defaulted off. `EventDisplayStatus`
/// maps anything with `needsReview` to `.needsReview` **before** looking at
/// the kind, so an undecided reservation and an undecided booking-window edge
/// were hidden by the same rule.
///
/// The rule this establishes: **a filter may change emphasis; it may never
/// remove unavailability.** Every event here is synthetic.
public enum CalendarVisibilityTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

    static func item(
        _ platform: RentalPlatform,
        _ ci: Date, _ co: Date,
        _ kind: BlockKind,
        needsReview: Bool = false,
        summary: String = "CLOSED - Not available",
        property: Int64 = 1
    ) -> ClassifiedEvent {
        ClassifiedEvent(
            event: CalendarEvent(
                listingID: 1,
                eventKey: "k-\(platform.rawValue)-\(ci.timeIntervalSince1970)-\(kind.rawValue)",
                uid: "u-\(ci.timeIntervalSince1970)-\(kind.rawValue)",
                platform: platform, summary: summary, details: "",
                checkIn: ci, checkOut: co),
            classification: EventClassification(
                eventKey: "k-\(platform.rawValue)-\(ci.timeIntervalSince1970)-\(kind.rawValue)",
                kind: kind, confidence: needsReview ? .low : .high,
                source: .automatic, needsReview: needsReview),
            listingLabel: "\(platform.displayName) — 39 G Street",
            propertyID: property, propertyName: "39 G Street")
    }

    /// The real reservation, as imported by run 348. Checkout-exclusive: it
    /// occupies the nights of 11–20 December and releases on the 21st.
    static var decemberReservation: ClassifiedEvent {
        item(.bookingCom, day(2026, 12, 11), day(2026, 12, 21),
             .unknownUnavailable, needsReview: true)
    }

    /// The Airbnb cancellation penalty that must stay visible, stay distinct,
    /// and never be propagated.
    static var cancellationPenalty: ClassifiedEvent {
        item(.airbnb, day(2026, 12, 17), day(2026, 12, 19),
             .cancellationBlock, summary: "Airbnb (Not available)")
    }

    public static var cases: [TestCase] { [

        // MARK: - 1. Nothing unavailable is ever hidden

        TestCase(group: "Calendar visibility",
                 name: "the December reservation is drawn under DEFAULT settings") { expect in
            // The exact regression. Default settings, nothing toggled.
            let drawn = CalendarVisibility.visible(
                [decemberReservation], reduceClutter: CalendarVisibility.defaultReduceClutter)
            expect.equal(drawn.count, 1, "a reservation the platform reports was hidden")
            expect.equal(drawn.first?.event.platform, .bookingCom)
        },

        TestCase(group: "Calendar visibility",
                 name: "no classification and no review state can remove an event") { expect in
            // Every combination, both filter settings. The filter is allowed
            // to reorder or de-emphasise; it is never allowed to drop.
            var checked = 0
            for kind in BlockKind.allCases {
                for needsReview in [true, false] {
                    for reduceClutter in [true, false] {
                        let one = item(.airbnb, day(2026, 12, 11), day(2026, 12, 21),
                                       kind, needsReview: needsReview)
                        let drawn = CalendarVisibility.visible(
                            [one], reduceClutter: reduceClutter)
                        expect.equal(drawn.count, 1,
                                     "\(kind.rawValue) review=\(needsReview) clutter=\(reduceClutter)")
                        checked += 1
                    }
                }
            }
            expect.ok(checked >= 20, "covered \(checked) combinations")
        },

        TestCase(group: "Calendar visibility",
                 name: "reducing clutter changes emphasis, never membership") { expect in
            let items = [decemberReservation, cancellationPenalty,
                         item(.vrbo, day(2027, 4, 1), day(2029, 1, 1), .platformRestriction)]
            let loud = CalendarVisibility.visible(items, reduceClutter: false)
            let quiet = CalendarVisibility.visible(items, reduceClutter: true)
            expect.equal(loud.count, quiet.count)
            expect.equal(Set(loud.map(\.id)), Set(quiet.map(\.id)))
        },

        // MARK: - 2. Undecided dates look like nothing else

        TestCase(group: "Calendar visibility",
                 name: "an undecided unavailable night is visually distinct, never blank") { expect in
            let emphasis = CalendarVisibility.emphasis(for: decemberReservation)
            expect.equal(emphasis, .undecided)
            expect.ok(emphasis != .reservation, "it must not look like a confirmed booking")
            expect.ok(emphasis.isDrawn, "and it must not be blank")
            expect.ok(emphasis.impliesUnavailable,
                      "the calendar must say these nights are not free")
        },

        TestCase(group: "Calendar visibility",
                 name: "every emphasis an unavailable event can take is drawn") { expect in
            for kind in BlockKind.allCases {
                for needsReview in [true, false] {
                    let e = CalendarVisibility.emphasis(
                        for: item(.airbnb, day(2026, 12, 11), day(2026, 12, 12),
                                  kind, needsReview: needsReview))
                    expect.ok(e.isDrawn, "\(kind.rawValue)/\(needsReview) would render blank")
                }
            }
        },

        TestCase(group: "Calendar visibility",
                 name: "a cancellation penalty stays visible and keeps its own emphasis") { expect in
            let emphasis = CalendarVisibility.emphasis(for: cancellationPenalty)
            expect.equal(emphasis, .cancellationPenalty)
            expect.ok(emphasis.isDrawn)
            expect.ok(emphasis != .reservation, "never shown as a booking")
            expect.ok(emphasis != .undecided, "and never merged with undecided blocks")
            expect.ok(!cancellationPenalty.classification.kind.describesGenuineUnavailability,
                      "still never exported")
        },

        TestCase(group: "Calendar visibility",
                 name: "the badge names the platform and the nights") { expect in
            let badge = CalendarVisibility.badge(for: decemberReservation)
            expect.contains(badge, "Booking.com")
            expect.contains(badge, "11")
            expect.contains(badge, "20", "the last OCCUPIED night, not the checkout day")
            expect.ok(!badge.contains("21"), "checkout-exclusive: got \(badge)")
        },

        // MARK: - 3. Safety-first default

        TestCase(group: "Calendar visibility",
                 name: "the default shows everything") { expect in
            expect.ok(!CalendarVisibility.defaultReduceClutter,
                      "the default must not be the setting that hides risk")
            let items = [decemberReservation, cancellationPenalty]
            expect.equal(
                CalendarVisibility.visible(
                    items, reduceClutter: CalendarVisibility.defaultReduceClutter).count,
                items.count)
        },

        // MARK: - Overlap, cross-month, conflicting classifications

        TestCase(group: "Calendar visibility",
                 name: "overlapping events from different platforms are all drawn") { expect in
            // Booking.com 11-21 and the Airbnb penalty 17-19 overlap. Both
            // must survive, because the overlap is the conflict worth seeing.
            let drawn = CalendarVisibility.visible(
                [decemberReservation, cancellationPenalty], reduceClutter: true)
            expect.equal(drawn.count, 2)
            expect.equal(Set(drawn.map { $0.classification.kind }),
                         [.unknownUnavailable, .cancellationBlock])
        },

        TestCase(group: "Calendar visibility",
                 name: "conflicting classifications on the same nights both remain") { expect in
            // One platform calls it a reservation, another an owner block.
            // Collapsing them would hide exactly the disagreement a person
            // needs to resolve.
            let a = item(.bookingCom, day(2026, 12, 11), day(2026, 12, 21), .confirmedReservation)
            let b = item(.vrbo, day(2026, 12, 11), day(2026, 12, 21), .ownerBlock)
            let drawn = CalendarVisibility.visible([a, b], reduceClutter: true)
            expect.equal(drawn.count, 2)
            expect.equal(CalendarVisibility.emphasis(for: a), .reservation)
            expect.equal(CalendarVisibility.emphasis(for: b), .block)
        },

        TestCase(group: "Calendar visibility",
                 name: "a range spanning months is drawn in every month it covers") { expect in
            // 28 Dec 2026 to 4 Jan 2027. Checkout-exclusive, so it occupies
            // 28-31 December and 1-3 January and releases on the 4th.
            let crossing = item(.vrbo, day(2026, 12, 28), day(2027, 1, 4), .unknownUnavailable,
                                needsReview: true)
            for date in [day(2026, 12, 28), day(2026, 12, 31),
                         day(2027, 1, 1), day(2027, 1, 3)] {
                expect.ok(crossing.event.covers(day: date), "must cover \(date)")
            }
            expect.ok(!crossing.event.covers(day: day(2027, 1, 4)),
                      "checkout day is released")
            expect.ok(!crossing.event.covers(day: day(2026, 12, 27)))
            expect.equal(CalendarVisibility.visible([crossing], reduceClutter: true).count, 1)
        },

        TestCase(group: "Calendar visibility",
                 name: "checkout-exclusive: the reservation frees the 21st") { expect in
            let r = decemberReservation
            expect.ok(r.event.covers(day: day(2026, 12, 11)), "first night occupied")
            expect.ok(r.event.covers(day: day(2026, 12, 20)), "last night occupied")
            expect.ok(!r.event.covers(day: day(2026, 12, 21)), "checkout day is sellable")
            expect.equal(r.event.nights, 10)
        },
    ] + reviewSummaryCases }

    // MARK: - 4. A counter that means something

    static var reviewSummaryCases: [TestCase] { [

        TestCase(group: "Review summary",
                 name: "a 10-night reservation is not buried in a 400-night total") { expect in
            // The live numbers: two long-horizon booking-window edges of 406
            // and 195 nights swamped a real 10-night reservation, and the
            // warning read "436 nights awaiting decisions" — true, and useless.
            let summary = ReviewSummary.make(from: [
                decemberReservation,
                item(.bookingCom, day(2027, 4, 1), day(2028, 5, 11),
                     .cancellationBlock, needsReview: true),
                item(.airbnb, day(2027, 5, 1), day(2027, 11, 12),
                     .cancellationBlock, needsReview: true),
            ])
            expect.equal(summary.actionable.count, 1, "the reservation is on its own")
            expect.equal(summary.actionableNights, 10)
            expect.equal(summary.longHorizon.count, 2)
            expect.contains(summary.headline, "10")
            expect.ok(!summary.headline.hasPrefix("601"),
                      "the headline must not lead with the swamped total")
        },

        TestCase(group: "Review summary",
                 name: "overlapping ranges count distinct nights, not a sum") { expect in
            // 11-21 and 17-19 overlap. The union is 10 nights, not 12.
            let summary = ReviewSummary.make(from: [
                decemberReservation,
                item(.airbnb, day(2026, 12, 17), day(2026, 12, 19),
                     .unknownUnavailable, needsReview: true),
            ])
            expect.equal(summary.actionableNights, 10, "overlap must not be double counted")
        },

        TestCase(group: "Review summary",
                 name: "adjacent ranges are not merged into one night fewer") { expect in
            // 11-14 and 14-17: checkout-exclusive, so they abut and cover 6.
            let summary = ReviewSummary.make(from: [
                item(.vrbo, day(2026, 12, 11), day(2026, 12, 14), .unknownUnavailable,
                     needsReview: true),
                item(.vrbo, day(2026, 12, 14), day(2026, 12, 17), .unknownUnavailable,
                     needsReview: true),
            ])
            expect.equal(summary.actionableNights, 6)
        },

        TestCase(group: "Review summary",
                 name: "nothing is discarded — every record is still reachable") { expect in
            let all = [decemberReservation,
                       item(.bookingCom, day(2027, 4, 1), day(2028, 5, 11),
                            .cancellationBlock, needsReview: true)]
            let summary = ReviewSummary.make(from: all)
            expect.equal(summary.actionable.count + summary.longHorizon.count, all.count)
            expect.equal(Set((summary.actionable + summary.longHorizon).map(\.id)),
                         Set(all.map(\.id)), "a record vanished from the summary")
        },

        TestCase(group: "Review summary",
                 name: "an empty review list reads as settled, not as zero nights") { expect in
            let summary = ReviewSummary.make(from: [])
            expect.equal(summary.actionable.count, 0)
            expect.equal(summary.actionableNights, 0)
            expect.ok(!summary.headline.isEmpty)
        },
    ] }
}
