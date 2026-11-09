import Foundation
import VRCCore

/// The nine scenarios named in the brief, each exercised end to end through the
/// real database, importer, classifier, conflict detector and export pipeline —
/// no mocks beyond the feed transport.
public enum RequiredScenarioTests {

    private static func importAll(
        _ store: RentalStore, _ fetcher: StubFeedFetcher
    ) async throws -> [ImportReport] {
        let service = store.makeImportService(fetcher: fetcher)
        return await service.importAll(listings: try store.listings.all())
    }

    private static func firstEvent(
        _ store: RentalStore, platform: RentalPlatform, uidContains: String
    ) throws -> ClassifiedEvent? {
        try store.classifiedEvents().first {
            $0.event.platform == platform && $0.event.uid.contains(uidContains)
        }
    }

    public static var cases: [TestCase] { [

        // 1 ------------------------------------------------------------------
        TestCase(group: "Required scenarios",
                 name: "1. an Airbnb confirmed booking blocks those dates in the filtered export",
                 requirement: "6.1") { expect in
            let setup = try Fixtures.makeStore(feeds: [.airbnb: Fixtures.airbnbConfirmedBooking])
            _ = try await importAll(setup.store, setup.fetcher)

            guard let item = try firstEvent(setup.store, platform: .airbnb,
                                            uidContains: "abb-confirmed") else {
                return expect.fail("the booking was not imported")
            }
            expect.equal(item.classification.kind, .confirmedReservation)
            expect.ok(!item.classification.needsReview, "strong evidence needs no review")

            let plan = try setup.store.exportPlan(propertyID: item.propertyID, destination: .vrbo)
            expect.equal(plan.included.count, 1, "the booking must reach the Vrbo feed")
            expect.equal(plan.includedNights, 5)

            let ics = setup.store.exporter.makeICS(from: plan)
            expect.contains(ics, "DTSTART;VALUE=DATE:20270310")
            expect.contains(ics, "DTEND;VALUE=DATE:20270315")
        },

        // 2 ------------------------------------------------------------------
        TestCase(group: "Required scenarios",
                 name: "2. an Airbnb cancellation block is excluded from other platforms' exports",
                 requirement: "6.2") { expect in
            let setup = try Fixtures.makeStore(feeds: [.airbnb: Fixtures.airbnbCancellationBlock])
            _ = try await importAll(setup.store, setup.fetcher)

            guard let item = try firstEvent(setup.store, platform: .airbnb,
                                            uidContains: "abb-cancelblock") else {
                return expect.fail("the block was not imported")
            }

            // Before any human decision it is unknown, and already excluded.
            var plan = try setup.store.exportPlan(propertyID: item.propertyID, destination: .vrbo)
            expect.equal(plan.included.count, 0, "an unreviewed block must never be exported")

            // The owner now identifies it as what it really is.
            try setup.store.classifyManually(
                eventKey: item.event.eventKey, kind: .cancellationBlock,
                note: "Airbnb penalty after I cancelled", approveForExport: true
            )
            plan = try setup.store.exportPlan(propertyID: item.propertyID, destination: .vrbo)
            expect.equal(plan.included.count, 0,
                         "even with approval requested, a cancellation block cannot be exported")
            expect.equal(plan.protectedNights, 3, "three nights stay sellable on Vrbo")

            let bookingPlan = try setup.store.exportPlan(
                propertyID: item.propertyID, destination: .bookingCom
            )
            expect.equal(bookingPlan.included.count, 0, "same for Booking.com")

            let ics = setup.store.exporter.makeICS(from: plan)
            expect.notContains(ics, "20270417", "the blocked dates must not appear at all")
            expect.notContains(ics, "BEGIN:VEVENT", "the feed should hold no events")

            // And the decision was recorded as the owner's, permanently.
            let stored = try setup.store.classifications.find(eventKey: item.event.eventKey)
            expect.equal(stored?.source, .manual)
            expect.ok(stored?.isLocked == true)
            expect.ok(stored?.exportApproved == false,
                      "approval must be refused for a cancellation block")
        },

        // 3 ------------------------------------------------------------------
        TestCase(group: "Required scenarios",
                 name: "3. an unknown Airbnb block stays pending review",
                 requirement: "6.3") { expect in
            let setup = try Fixtures.makeStore(feeds: [.airbnb: Fixtures.airbnbOpaqueBlocks])
            let reports = try await importAll(setup.store, setup.fetcher)

            expect.equal(reports.first?.run.eventsSeen, 3)
            expect.equal(reports.first?.run.eventsNeedingReview, 3,
                         "every opaque Airbnb block needs a decision")

            let queue = try setup.store.needsReview()
            expect.equal(queue.count, 3)
            for item in queue {
                expect.equal(item.classification.kind, .unknownUnavailable)
                expect.equal(item.classification.source, .automatic)
                expect.ok(item.classification.needsReview)
            }

            // Nothing in that state may be exported.
            let plan = try setup.store.exportPlan(
                propertyID: queue[0].propertyID, destination: .vrbo
            )
            expect.equal(plan.included.count, 0)
            expect.equal(plan.protectedNights, 8 + 2 + 193,
                         "all 203 nights are protected from propagation")
        },

        // 4 ------------------------------------------------------------------
        TestCase(group: "Required scenarios",
                 name: "4. a Vrbo reservation appears in the unified calendar",
                 requirement: "6.4") { expect in
            let setup = try Fixtures.makeStore(feeds: [.vrbo: Fixtures.vrboReservation])
            _ = try await importAll(setup.store, setup.fetcher)

            guard let item = try firstEvent(setup.store, platform: .vrbo,
                                            uidContains: "vrbo-res") else {
                return expect.fail("the Vrbo reservation was not imported")
            }
            expect.equal(item.classification.kind, .confirmedReservation)
            expect.equal(item.event.checkIn, DayMath.day(2027, 3, 10))
            expect.equal(item.event.checkOut, DayMath.day(2027, 3, 14))
            expect.equal(item.event.nights, 4)
            expect.equal(item.propertyName, "Test Property")

            // Visible on each of its nights, and not on the check-out day.
            expect.ok(item.event.covers(day: DayMath.day(2027, 3, 10)))
            expect.ok(item.event.covers(day: DayMath.day(2027, 3, 13)))
            expect.ok(!item.event.covers(day: DayMath.day(2027, 3, 14)),
                      "the check-out day is free for the next guest")
        },

        // 5 ------------------------------------------------------------------
        TestCase(group: "Required scenarios",
                 name: "5. a Booking.com reservation appears correctly",
                 requirement: "6.5") { expect in
            let setup = try Fixtures.makeStore(feeds: [.bookingCom: Fixtures.bookingReservation])
            _ = try await importAll(setup.store, setup.fetcher)

            guard let item = try firstEvent(setup.store, platform: .bookingCom,
                                            uidContains: "bdc-res") else {
                return expect.fail("the Booking.com reservation was not imported")
            }
            expect.equal(item.classification.kind, .confirmedReservation)
            expect.equal(item.event.platform, .bookingCom)
            expect.equal(item.event.checkIn, DayMath.day(2027, 6, 1))
            expect.equal(item.event.nights, 4)

            // It exports onward, but without the guest's identity.
            let plan = try setup.store.exportPlan(propertyID: item.propertyID, destination: .airbnb)
            expect.equal(plan.included.count, 1)
            let ics = setup.store.exporter.makeICS(from: plan)
            expect.notContains(ics, "Okafor")
            expect.notContains(ics, "4412887301")
        },

        // 6 ------------------------------------------------------------------
        TestCase(group: "Required scenarios",
                 name: "6. overlapping confirmed reservations raise a warning",
                 requirement: "6.6") { expect in
            let overlapping = Fixtures.calendar("-//HomeAway.com\\, Inc.//EN", """
                BEGIN:VEVENT
                UID:vrbo-overlap-0001
                DTSTART;VALUE=DATE:20270312
                DTEND;VALUE=DATE:20270318
                SUMMARY:Reserved - Overlapping guest
                END:VEVENT
                """)
            let setup = try Fixtures.makeStore(feeds: [
                .airbnb: Fixtures.airbnbConfirmedBooking,
                .vrbo: overlapping,
            ])
            _ = try await importAll(setup.store, setup.fetcher)

            let conflicts = try setup.store.conflicts()
            let doubleBookings = conflicts.filter { $0.severity == .doubleBooking }
            expect.equal(doubleBookings.count, 1, "one double booking expected")

            guard let conflict = doubleBookings.first else { return }
            // Airbnb 10–15 March, Vrbo 12–18 March: the overlap is 12–15.
            expect.equal(conflict.overlapStart, DayMath.day(2027, 3, 12))
            expect.equal(conflict.overlapEnd, DayMath.day(2027, 3, 15))
            expect.equal(conflict.overlapNights, 3)
            let platforms = Set([conflict.sideA.platform, conflict.sideB.platform])
            expect.ok(platforms.contains(.airbnb) && platforms.contains(.vrbo),
                      "both platforms must be named")
            expect.contains(conflict.platformsDescription, "Airbnb")
            expect.contains(conflict.platformsDescription, "Vrbo")
        },

        // 7 ------------------------------------------------------------------
        TestCase(group: "Required scenarios",
                 name: "7. re-importing a feed creates no duplicates",
                 requirement: "6.7") { expect in
            let setup = try Fixtures.makeStore(feeds: [
                .airbnb: Fixtures.airbnbOpaqueBlocks,
                .vrbo: Fixtures.vrboBlocks,
            ])
            let first = try await importAll(setup.store, setup.fetcher)
            let insertedFirst = first.reduce(0) { $0 + $1.run.eventsInserted }
            expect.equal(insertedFirst, 5)
            expect.equal(try setup.store.events.count(), 5)

            // Import the same bytes four more times.
            for _ in 0..<4 {
                let again = try await importAll(setup.store, setup.fetcher)
                expect.equal(again.reduce(0) { $0 + $1.run.eventsInserted }, 0, "nothing new")
                expect.equal(again.reduce(0) { $0 + $1.run.eventsUpdated }, 0, "nothing changed")
                expect.equal(again.reduce(0) { $0 + $1.run.eventsTombstoned }, 0, "nothing removed")
            }
            expect.equal(try setup.store.events.count(), 5, "still exactly five rows")
            expect.equal(try setup.store.classifications.count(), 5)
        },

        // 8 ------------------------------------------------------------------
        TestCase(group: "Required scenarios",
                 name: "8. a changed event updates the existing record",
                 requirement: "6.8") { expect in
            let setup = try Fixtures.makeStore(feeds: [.vrbo: Fixtures.vrboReservation])
            let listing = try setup.store.listings.find(id: setup.listingIDs[.vrbo]!)!
            _ = try await importAll(setup.store, setup.fetcher)

            guard let before = try firstEvent(setup.store, platform: .vrbo,
                                              uidContains: "vrbo-res") else {
                return expect.fail("not imported")
            }
            expect.equal(before.event.checkOut, DayMath.day(2027, 3, 14))
            let rowID = before.event.id

            // The guest extends by two nights; same UID, new dates.
            let amended = Fixtures.calendar("-//HomeAway.com\\, Inc.//EN", """
                BEGIN:VEVENT
                UID:vrbo-res-0001
                DTSTAMP:20261103T100000Z
                DTSTART;VALUE=DATE:20270310
                DTEND;VALUE=DATE:20270316
                SUMMARY:Reserved - Dana P.
                SEQUENCE:1
                END:VEVENT
                """)
            let fetcher = StubFeedFetcher(texts: [listing.icalURL: amended])
            let report = await setup.store.makeImportService(fetcher: fetcher)
                .importFeed(for: listing)

            expect.equal(report.run.eventsInserted, 0, "no new row")
            expect.equal(report.run.eventsUpdated, 1, "the existing row changed")
            expect.equal(try setup.store.events.count(), 1)

            guard let after = try firstEvent(setup.store, platform: .vrbo,
                                             uidContains: "vrbo-res") else { return }
            expect.equal(after.event.checkOut, DayMath.day(2027, 3, 16), "new check-out")
            expect.equal(after.event.nights, 6)
            expect.equal(after.event.id, rowID, "same database row, updated in place")
            expect.equal(after.event.sequence, 1)
        },

        // 9 ------------------------------------------------------------------
        TestCase(group: "Required scenarios",
                 name: "9. reviewed classifications survive a restart and later imports",
                 requirement: "6.9") { expect in
            let path = Fixtures.temporaryDatabasePath()
            var eventKey = ""

            // --- First run: import, then decide. ---
            do {
                let setup = try Fixtures.makeStore(
                    feeds: [.airbnb: Fixtures.airbnbCancellationBlock], databasePath: path
                )
                _ = try await importAll(setup.store, setup.fetcher)
                guard let item = try firstEvent(setup.store, platform: .airbnb,
                                                uidContains: "abb-cancelblock") else {
                    return expect.fail("not imported")
                }
                eventKey = item.event.eventKey
                expect.ok(item.classification.needsReview, "starts out needing review")

                try setup.store.classifyManually(
                    eventKey: eventKey, kind: .cancellationBlock,
                    note: "Host cancellation penalty — keep sellable elsewhere"
                )
                setup.store.database.close()
            }

            // --- Second run: a fresh process would see exactly this. ---
            let reopened = try RentalStore(
                database: try Database(path: path), credentials: InMemoryFeedCredentialStore()
            )
            let restored = try reopened.classifications.find(eventKey: eventKey)
            expect.equal(restored?.kind, .cancellationBlock, "the decision survived the restart")
            expect.equal(restored?.source, .manual)
            expect.ok(restored?.needsReview == false)
            expect.contains(restored?.note ?? "", "Host cancellation penalty")
            expect.equal(try reopened.needsReview().count, 0, "the queue is empty again")

            // --- And a later import must not undo it. ---
            let listing = try reopened.listings.all().first { $0.platform == .airbnb }!
            let fetcher = StubFeedFetcher(
                texts: [try reopened.listings.resolveURL(for: listing):
                            Fixtures.airbnbCancellationBlock]
            )
            let report = await reopened.makeImportService(fetcher: fetcher)
                .importFeed(for: listing)
            expect.equal(report.preservedDecisions, 1, "the import left the decision alone")

            let afterImport = try reopened.classifications.find(eventKey: eventKey)
            expect.equal(afterImport?.kind, .cancellationBlock)
            expect.equal(afterImport?.source, .manual)
            expect.ok(afterImport?.needsReview == false)

            // Still never exportable.
            let plan = try reopened.exportPlan(
                propertyID: try reopened.properties.all().first!.id!, destination: .vrbo
            )
            expect.equal(plan.included.count, 0)
            reopened.database.close()
        },
    ] }
}
