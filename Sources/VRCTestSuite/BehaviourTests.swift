import Foundation
import VRCCore

// MARK: - Import reconciliation

public enum ImportTests {
    public static var cases: [TestCase] { [
        TestCase(group: "Import", name: "a feed import stores events and classifications") { expect in
            let setup = try Fixtures.makeStore(feeds: [.vrbo: Fixtures.vrboBlocks])
            let service = setup.store.makeImportService(fetcher: setup.fetcher)
            let listing = try setup.store.listings.find(id: setup.listingIDs[.vrbo]!)!
            let report = await service.importFeed(for: listing)

            expect.equal(report.run.outcome, .success)
            expect.equal(report.run.eventsSeen, 2)
            expect.equal(report.run.eventsInserted, 2)
            expect.equal(try setup.store.events.count(), 2)
            expect.equal(try setup.store.classifications.count(), 2)
        },

        TestCase(group: "Import", name: "a missing URL is skipped, not failed") { expect in
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "P"))
            let listing = try store.listings.insert(PlatformListing(
                propertyID: property.id!, platform: .airbnb, label: "A", urlStorage: .database
            ))
            let service = store.makeImportService(fetcher: StubFeedFetcher(texts: [:]))
            let report = await service.importFeed(for: listing)
            expect.equal(report.run.outcome, .skipped)
        },

        TestCase(group: "Import", name: "an HTTP failure is recorded without losing data") { expect in
            let setup = try Fixtures.makeStore(feeds: [.vrbo: Fixtures.vrboBlocks])
            let listing = try setup.store.listings.find(id: setup.listingIDs[.vrbo]!)!
            _ = await setup.store.makeImportService(fetcher: setup.fetcher)
                .importFeed(for: listing)
            expect.equal(try setup.store.events.count(), 2)

            let failing = StubFeedFetcher(responses: [listing.icalURL: .failure(.httpError(503))])
            let report = await setup.store.makeImportService(fetcher: failing)
                .importFeed(for: listing)
            expect.equal(report.run.outcome, .failure)
            expect.equal(try setup.store.events.count(), 2, "existing events must survive")
        },

        TestCase(group: "Import", name: "STATUS:CANCELLED tombstones the event") { expect in
            let setup = try Fixtures.makeStore(feeds: [.other: Fixtures.cancelledEvent])
            let listing = try setup.store.listings.find(id: setup.listingIDs[.other]!)!
            _ = await setup.store.makeImportService(fetcher: setup.fetcher).importFeed(for: listing)
            expect.equal(try setup.store.events.count(includeTombstoned: true), 1)
            expect.equal(try setup.store.events.allActive().count, 0, "cancelled is not active")
        },

        TestCase(group: "Import",
                 name: "an event removed from the feed is tombstoned, not deleted") { expect in
            let setup = try Fixtures.makeStore(feeds: [.vrbo: Fixtures.vrboBlocks])
            let listing = try setup.store.listings.find(id: setup.listingIDs[.vrbo]!)!
            _ = await setup.store.makeImportService(fetcher: setup.fetcher).importFeed(for: listing)
            expect.equal(try setup.store.events.allActive().count, 2)

            // Second import serves only the first of the two events.
            let shrunk = Fixtures.calendar("-//HomeAway.com\\, Inc.//EN", """
                BEGIN:VEVENT
                UID:78d35b3e-5c68-443d-afa3-642519c52f7e
                DTSTART;VALUE=DATE:20261101
                DTEND;VALUE=DATE:20261130
                SUMMARY:Blocked
                END:VEVENT
                """)
            let fetcher = StubFeedFetcher(texts: [listing.icalURL: shrunk])
            let report = await setup.store.makeImportService(fetcher: fetcher)
                .importFeed(for: listing)
            expect.equal(report.run.eventsTombstoned, 1)
            expect.equal(try setup.store.events.allActive().count, 1)
            expect.equal(try setup.store.events.count(includeTombstoned: true), 2,
                         "history is kept")
        },

        TestCase(group: "Import", name: "a duplicate UID inside one feed counts once") { expect in
            let doubled = Fixtures.calendar("-//Test//EN", """
                BEGIN:VEVENT
                UID:dupe-0001
                DTSTART;VALUE=DATE:20270201
                DTEND;VALUE=DATE:20270204
                SUMMARY:Blocked
                END:VEVENT
                BEGIN:VEVENT
                UID:dupe-0001
                DTSTART;VALUE=DATE:20270201
                DTEND;VALUE=DATE:20270204
                SUMMARY:Blocked
                END:VEVENT
                """)
            let setup = try Fixtures.makeStore(feeds: [.other: doubled])
            let listing = try setup.store.listings.find(id: setup.listingIDs[.other]!)!
            let report = await setup.store.makeImportService(fetcher: setup.fetcher)
                .importFeed(for: listing)
            expect.equal(report.run.eventsSeen, 1)
            expect.equal(try setup.store.events.count(), 1)
        },
    ] }
}

// MARK: - Conflicts

public enum ConflictTests {
    /// Builds a classified event without going through a feed.
    static func event(
        key: String, platform: RentalPlatform, kind: BlockKind,
        from: (Int, Int, Int), to: (Int, Int, Int), propertyID: Int64 = 1,
        listingID: Int64 = 1
    ) -> ClassifiedEvent {
        ClassifiedEvent(
            event: CalendarEvent(
                listingID: listingID, eventKey: key, uid: key, platform: platform,
                summary: kind.displayName,
                checkIn: DayMath.day(from.0, from.1, from.2),
                checkOut: DayMath.day(to.0, to.1, to.2)
            ),
            classification: EventClassification(
                eventKey: key, kind: kind, confidence: .high, source: .manual, needsReview: false
            ),
            listingLabel: "\(platform.displayName) listing",
            propertyID: propertyID,
            propertyName: "Test Property"
        )
    }

    public static var cases: [TestCase] { [
        TestCase(group: "Conflicts",
                 name: "two confirmed reservations overlapping is a double booking") { expect in
            let conflicts = ConflictDetector().detect(in: [
                event(key: "a", platform: .airbnb, kind: .confirmedReservation,
                      from: (2027, 5, 10), to: (2027, 5, 15), listingID: 1),
                event(key: "b", platform: .vrbo, kind: .confirmedReservation,
                      from: (2027, 5, 13), to: (2027, 5, 18), listingID: 2),
            ])
            expect.equal(conflicts.count, 1)
            expect.equal(conflicts.first?.severity, .doubleBooking)
            expect.equal(conflicts.first?.overlapStart, DayMath.day(2027, 5, 13))
            expect.equal(conflicts.first?.overlapEnd, DayMath.day(2027, 5, 15))
            expect.equal(conflicts.first?.overlapNights, 2)
        },

        TestCase(group: "Conflicts",
                 name: "a same-day turnover is not a conflict") { expect in
            let conflicts = ConflictDetector().detect(in: [
                event(key: "a", platform: .airbnb, kind: .confirmedReservation,
                      from: (2027, 5, 10), to: (2027, 5, 14), listingID: 1),
                event(key: "b", platform: .vrbo, kind: .confirmedReservation,
                      from: (2027, 5, 14), to: (2027, 5, 18), listingID: 2),
            ])
            expect.equal(conflicts.count, 0, "check-out day equals check-in day: normal turnover")
        },

        TestCase(group: "Conflicts",
                 name: "overlapping blocks are reported separately, not as double bookings") { expect in
            let conflicts = ConflictDetector().detect(in: [
                event(key: "a", platform: .vrbo, kind: .ownerBlock,
                      from: (2026, 11, 1), to: (2026, 11, 30), listingID: 1),
                event(key: "b", platform: .vrbo, kind: .ownerBlock,
                      from: (2026, 11, 1), to: (2026, 11, 2), listingID: 2),
            ])
            expect.equal(conflicts.count, 1)
            expect.equal(conflicts.first?.severity, .overlappingBlocks)
            expect.ok(ConflictDetector().doubleBookings(in: []).isEmpty)
        },

        TestCase(group: "Conflicts",
                 name: "different properties never conflict with each other") { expect in
            let conflicts = ConflictDetector().detect(in: [
                event(key: "a", platform: .airbnb, kind: .confirmedReservation,
                      from: (2027, 5, 10), to: (2027, 5, 15), propertyID: 1, listingID: 1),
                event(key: "b", platform: .vrbo, kind: .confirmedReservation,
                      from: (2027, 5, 10), to: (2027, 5, 15), propertyID: 2, listingID: 2),
            ])
            expect.equal(conflicts.count, 0)
        },

        TestCase(group: "Conflicts", name: "a conflict id is stable whichever way round") { expect in
            let a = event(key: "aaa", platform: .airbnb, kind: .confirmedReservation,
                          from: (2027, 5, 10), to: (2027, 5, 15), listingID: 1)
            let b = event(key: "bbb", platform: .vrbo, kind: .confirmedReservation,
                          from: (2027, 5, 11), to: (2027, 5, 16), listingID: 2)
            let forwards = ConflictDetector().detect(in: [a, b])
            let backwards = ConflictDetector().detect(in: [b, a])
            expect.equal(forwards.first?.id, backwards.first?.id,
                         "acknowledgement must survive a reordering")
        },

        TestCase(group: "Conflicts", name: "acknowledgement persists") { expect in
            let store = try RentalStore.makeInMemory()
            try store.conflictAcks.acknowledge(conflictID: "abc|def")
            expect.ok(try store.conflictAcks.acknowledgedIDs().contains("abc|def"))
            try store.conflictAcks.unacknowledge(conflictID: "abc|def")
            expect.ok(!(try store.conflictAcks.acknowledgedIDs().contains("abc|def")))
        },
    ] }
}
