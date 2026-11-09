import Foundation
import VRCCore

public enum PresentationTests {

    static func event(
        key: String, platform: RentalPlatform = .airbnb,
        from: (Int, Int, Int), to: (Int, Int, Int),
        kind: BlockKind = .confirmedReservation,
        needsReview: Bool = false,
        summary: String = "Reserved", details: String = ""
    ) -> ClassifiedEvent {
        ClassifiedEvent(
            event: CalendarEvent(
                listingID: 1, eventKey: key, uid: key, platform: platform,
                summary: summary, details: details,
                checkIn: DayMath.day(from.0, from.1, from.2),
                checkOut: DayMath.day(to.0, to.1, to.2)
            ),
            classification: EventClassification(
                eventKey: key, kind: kind, confidence: .high,
                source: .manual, needsReview: needsReview
            ),
            listingLabel: "\(platform.displayName) listing",
            propertyID: 1, propertyName: "Test Property"
        )
    }

    public static var cases: [TestCase] { [

        // --- Status mapping ------------------------------------------------

        TestCase(group: "Presentation", name: "needs review outranks whatever was guessed") { expect in
            let item = event(key: "a", from: (2027, 3, 1), to: (2027, 3, 4),
                             kind: .maintenanceBlock, needsReview: true)
            expect.equal(item.displayStatus, .needsReview,
                         "an undecided event reads as undecided, not as a maintenance block")
            expect.equal(item.displayStatus.label, "Needs review")
        },

        TestCase(group: "Presentation", name: "every classification maps to a distinct status") { expect in
            let expected: [BlockKind: EventDisplayStatus] = [
                .confirmedReservation: .confirmed,
                .ownerBlock: .ownerBlock,
                .maintenanceBlock: .maintenance,
                .cancellationBlock: .cancellationBlock,
                .unknownUnavailable: .unknown,
            ]
            for (kind, status) in expected {
                let item = event(key: kind.rawValue, from: (2027, 3, 1), to: (2027, 3, 4),
                                 kind: kind, needsReview: false)
                expect.equal(item.displayStatus, status, kind.rawValue)
            }
            // The five named in the brief all have labels and symbols.
            for status in EventDisplayStatus.allCases {
                expect.ok(!status.label.isEmpty, "\(status.rawValue) needs a label")
                expect.ok(!status.symbolName.isEmpty, "\(status.rawValue) needs a symbol")
                expect.ok(!status.consequence.isEmpty, "\(status.rawValue) needs an explanation")
            }
        },

        TestCase(group: "Presentation",
                 name: "the hollow-bar rule matches what is actually exportable") { expect in
            // The visual promise — hollow means still sellable — has to agree
            // with the export gate, or the calendar lies.
            let policy = ExportPolicy()
            for status in EventDisplayStatus.allCases {
                guard let kind = status.correspondingKind else {
                    expect.ok(status.isSellableElsewhere,
                              "\(status.label) has no decided kind, so it must read as sellable")
                    continue
                }
                let classification = EventClassification(
                    eventKey: "k", kind: kind, confidence: .high, source: .manual,
                    needsReview: false, exportApproved: true
                )
                let sample = CalendarEvent(
                    listingID: 1, eventKey: "k", uid: "k", platform: .airbnb, summary: "",
                    checkIn: DayMath.day(2027, 3, 1), checkOut: DayMath.day(2027, 3, 4)
                )
                let exportable = policy.decide(
                    event: sample, classification: classification, destination: .vrbo
                ).isIncluded
                expect.equal(
                    status.isSellableElsewhere, !exportable,
                    "\(status.label): the calendar must not show it hollow if it exports"
                )
            }
        },

        // --- Bar layout ----------------------------------------------------

        TestCase(group: "Presentation", name: "a stay becomes one bar, not one chip per day") { expect in
            // 2027-03-07 is a Sunday.
            let week = DayMath.day(2027, 3, 7)
            let layout = CalendarLayout.layout(
                weekStart: week,
                events: [event(key: "stay", from: (2027, 3, 8), to: (2027, 3, 11))]
            )
            expect.equal(layout.segments.count, 1, "one continuous bar")
            guard let segment = layout.segments.first else { return }
            expect.equal(segment.startColumn, 1, "first night is Monday the 8th")
            expect.equal(segment.endColumn, 3, "last night is Wednesday the 10th")
            expect.equal(segment.columnSpan, 3, "three nights, checkout Thursday the 11th")
            expect.ok(segment.isStart)
            expect.ok(segment.isEnd)
        },

        TestCase(group: "Presentation", name: "a stay crossing a week splits into capped segments") { expect in
            let item = event(key: "long", from: (2027, 3, 10), to: (2027, 3, 17))
            let first = CalendarLayout.layout(weekStart: DayMath.day(2027, 3, 7), events: [item])
            let second = CalendarLayout.layout(weekStart: DayMath.day(2027, 3, 14), events: [item])

            guard let a = first.segments.first, let b = second.segments.first else {
                return expect.fail("expected a segment in each week")
            }
            expect.equal(a.startColumn, 3, "Wednesday")
            expect.equal(a.endColumn, 6, "runs to the end of the week")
            expect.ok(a.isStart, "the stay really begins here")
            expect.ok(!a.isEnd, "but it continues, so the right edge stays open")

            expect.equal(b.startColumn, 0)
            expect.equal(b.endColumn, 2, "last night is Tuesday the 16th")
            expect.ok(!b.isStart, "left edge open — it continued in")
            expect.ok(b.isEnd)
        },

        TestCase(group: "Presentation", name: "overlapping stays get separate lanes") { expect in
            let layout = CalendarLayout.layout(
                weekStart: DayMath.day(2027, 3, 7),
                events: [
                    event(key: "a", from: (2027, 3, 8), to: (2027, 3, 12)),
                    event(key: "b", platform: .vrbo, from: (2027, 3, 9), to: (2027, 3, 13)),
                ]
            )
            expect.equal(layout.segments.count, 2)
            expect.equal(layout.laneCount, 2, "they overlap, so they cannot share a lane")
            let lanes = Set(layout.segments.map(\.lane))
            expect.equal(lanes.count, 2)
        },

        TestCase(group: "Presentation", name: "non-overlapping stays share one lane") { expect in
            let layout = CalendarLayout.layout(
                weekStart: DayMath.day(2027, 3, 7),
                events: [
                    event(key: "a", from: (2027, 3, 8), to: (2027, 3, 10)),
                    event(key: "b", platform: .vrbo, from: (2027, 3, 11), to: (2027, 3, 13)),
                ]
            )
            expect.equal(layout.laneCount, 1, "they do not overlap, so one row is enough")
        },

        TestCase(group: "Presentation", name: "a same-day turnover does not force a second lane") { expect in
            // One guest leaves the 11th, the next arrives the 11th.
            let layout = CalendarLayout.layout(
                weekStart: DayMath.day(2027, 3, 7),
                events: [
                    event(key: "out", from: (2027, 3, 8), to: (2027, 3, 11)),
                    event(key: "in", platform: .vrbo, from: (2027, 3, 11), to: (2027, 3, 13)),
                ]
            )
            expect.equal(layout.laneCount, 1, "checkout day is free for the next arrival")
        },

        TestCase(group: "Presentation", name: "events outside the week are left out") { expect in
            let layout = CalendarLayout.layout(
                weekStart: DayMath.day(2027, 3, 7),
                events: [event(key: "far", from: (2027, 5, 1), to: (2027, 5, 5))]
            )
            expect.equal(layout.segments.count, 0)
        },

        TestCase(group: "Presentation", name: "excess bars are counted, not silently dropped") { expect in
            let events = (0..<7).map { index in
                event(key: "e\(index)", from: (2027, 3, 8), to: (2027, 3, 12))
            }
            let layout = CalendarLayout.layout(
                weekStart: DayMath.day(2027, 3, 7), events: events, maxLanes: 3
            )
            expect.equal(layout.laneCount, 3)
            expect.equal(
                CalendarLayout.overflowCount(
                    weekStart: DayMath.day(2027, 3, 7), events: events, maxLanes: 3
                ),
                4, "the other four must be reported so the view can say +4"
            )
        },

        TestCase(group: "Presentation", name: "layout is stable across repeated calls") { expect in
            let events = [
                event(key: "a", from: (2027, 3, 8), to: (2027, 3, 12)),
                event(key: "b", platform: .vrbo, from: (2027, 3, 9), to: (2027, 3, 13)),
                event(key: "c", platform: .bookingCom, from: (2027, 3, 10), to: (2027, 3, 14)),
            ]
            let first = CalendarLayout.layout(weekStart: DayMath.day(2027, 3, 7), events: events)
            let again = CalendarLayout.layout(
                weekStart: DayMath.day(2027, 3, 7), events: events.reversed()
            )
            expect.equal(first.segments.count, again.segments.count)
            for segment in first.segments {
                let match = again.segments.first { $0.eventKey == segment.eventKey }
                expect.equal(match?.lane, segment.lane, "\(segment.eventKey) must not jump lanes")
            }
        },

        TestCase(group: "Presentation", name: "a month grid is six whole weeks") { expect in
            let days = CalendarLayout.monthGridDays(containing: DayMath.day(2027, 3, 15))
            expect.equal(days.count, 42)
            expect.equal(DayMath.utcCalendar.component(.weekday, from: days[0]), 1, "starts Sunday")
            expect.equal(CalendarLayout.weekStarts(containing: DayMath.day(2027, 3, 15)).count, 6)
        },

        // --- Feed diagnostics ----------------------------------------------

        TestCase(group: "Presentation",
                 name: "an uninformative feed produces a warning naming the platform") { expect in
            let listing = PlatformListing(
                id: 1, propertyID: 1, platform: .airbnb, label: "Airbnb — 39 G Street"
            )
            let events = (0..<4).map { index in
                event(key: "b\(index)", from: (2027, 3, 1 + index), to: (2027, 3, 3 + index),
                      kind: .unknownUnavailable, needsReview: true,
                      summary: "Airbnb (Not available)", details: "")
            }
            let diagnostic = FeedDiagnostics.diagnose(listing: listing, events: events)
            expect.equal(diagnostic.totalEvents, 4)
            expect.equal(diagnostic.identifiableReservations, 0)
            expect.ok(diagnostic.cannotIdentifyReservations)
            guard let warning = diagnostic.warning else {
                return expect.fail("a warning was expected")
            }
            expect.contains(warning, "Airbnb")
            expect.contains(warning, "4 entries")
            expect.contains(warning, "cancellation")
        },

        TestCase(group: "Presentation", name: "an informative feed produces no warning") { expect in
            let listing = PlatformListing(
                id: 1, propertyID: 1, platform: .airbnb, label: "Airbnb"
            )
            let events = [
                event(key: "r", from: (2027, 3, 10), to: (2027, 3, 15),
                      summary: "Reserved",
                      details: "Reservation URL: https://www.airbnb.com/hosting/reservations/details/X"),
                event(key: "b", from: (2027, 4, 1), to: (2027, 4, 3),
                      kind: .unknownUnavailable, needsReview: true,
                      summary: "Airbnb (Not available)"),
            ]
            let diagnostic = FeedDiagnostics.diagnose(listing: listing, events: events)
            expect.equal(diagnostic.identifiableReservations, 1)
            expect.ok(!diagnostic.cannotIdentifyReservations)
            expect.ok(diagnostic.warning == nil, "no warning when bookings are identifiable")
        },

        TestCase(group: "Presentation",
                 name: "Booking.com CLOSED entries count as unidentifiable") { expect in
            let listing = PlatformListing(
                id: 1, propertyID: 1, platform: .bookingCom, label: "Booking.com"
            )
            let events = [
                event(key: "c", platform: .bookingCom, from: (2027, 7, 1), to: (2027, 7, 5),
                      kind: .unknownUnavailable, needsReview: true,
                      summary: "CLOSED - Not available"),
            ]
            let diagnostic = FeedDiagnostics.diagnose(listing: listing, events: events)
            expect.ok(diagnostic.cannotIdentifyReservations)
            expect.contains(diagnostic.warning ?? "", "identically")
        },

        TestCase(group: "Presentation", name: "nights awaiting a decision are counted") { expect in
            let listing = PlatformListing(id: 1, propertyID: 1, platform: .vrbo, label: "Vrbo")
            let events = [
                event(key: "a", platform: .vrbo, from: (2026, 11, 1), to: (2026, 11, 30),
                      kind: .unknownUnavailable, needsReview: true, summary: "Blocked"),
                event(key: "b", platform: .vrbo, from: (2026, 12, 1), to: (2026, 12, 3),
                      kind: .unknownUnavailable, needsReview: true, summary: "Blocked"),
            ]
            let diagnostic = FeedDiagnostics.diagnose(listing: listing, events: events)
            expect.equal(diagnostic.awaitingDecision, 2)
            expect.equal(diagnostic.nightsAwaitingDecision, 31)
        },
    ] }
}
