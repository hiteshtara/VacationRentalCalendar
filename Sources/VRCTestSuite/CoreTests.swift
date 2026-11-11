import Foundation
import VRCCore

// MARK: - Migrations

public enum MigrationTests {
    public static var cases: [TestCase] { [
        TestCase(group: "Database", name: "migrations run and reach the latest version") { expect in
            let database = try Database.inMemory()
            let applied = try Migrator.migrate(database)
            expect.equal(applied.count, Migrator.migrations.count, "every migration applied")
            expect.equal(try Migrator.currentVersion(database), Migrator.latestVersion)
        },

        TestCase(group: "Database", name: "migrating twice is a no-op") { expect in
            let database = try Database.inMemory()
            try Migrator.migrate(database)
            let second = try Migrator.migrate(database)
            expect.equal(second.count, 0, "nothing re-applied")
        },

        TestCase(group: "Database", name: "migrations survive reopening the file") { expect in
            let path = Fixtures.temporaryDatabasePath()
            do {
                let database = try Database(path: path)
                try Migrator.migrate(database)
                database.close()
            }
            let reopened = try Database(path: path)
            let applied = try Migrator.migrate(reopened)
            expect.equal(applied.count, 0, "already migrated")
            expect.equal(try Migrator.currentVersion(reopened), Migrator.latestVersion)
        },

        TestCase(group: "Database", name: "a failed transaction rolls back") { expect in
            let store = try RentalStore.makeInMemory()
            let before = try store.properties.count()
            do {
                try store.database.transaction {
                    _ = try store.properties.insert(Property(name: "Doomed"))
                    throw SQLiteError.notOpen
                }
                expect.fail("the transaction should have thrown")
            } catch {
                // expected
            }
            expect.equal(try store.properties.count(), before, "insert rolled back")
        },

        TestCase(group: "Database", name: "deleting a property removes its listings") { expect in
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "Temp"))
            try store.listings.insert(PlatformListing(
                propertyID: property.id!, platform: .airbnb, label: "A", urlStorage: .database
            ))
            expect.equal(try store.listings.count(), 1)
            try store.properties.delete(id: property.id!)
            expect.equal(try store.listings.count(), 0, "cascade removed the listing")
        },
    ] }
}

// MARK: - iCal parsing

public enum ICalParsingTests {
    public static var cases: [TestCase] { [
        TestCase(group: "iCal", name: "parses an all-day event with VALUE=DATE") { expect in
            let result = try ICalParser.parse(Fixtures.airbnbCancellationBlock)
            expect.equal(result.events.count, 1)
            guard let event = result.events.first else { return }
            expect.equal(event.uid, "abb-cancelblock-0002@airbnb.com")
            expect.ok(event.isAllDay, "should be an all-day event")
            expect.equal(event.resolvedCheckIn, DayMath.day(2027, 4, 17))
            expect.equal(event.resolvedCheckOut, DayMath.day(2027, 4, 20))
        },

        TestCase(group: "iCal", name: "unfolds continuation lines and unescapes text") { expect in
            let result = try ICalParser.parse(Fixtures.foldedAndEscaped)
            expect.equal(result.events.count, 1)
            guard let event = result.events.first else { return }
            expect.contains(event.description, "details/HMZZZ9999",
                            "the folded URL should be rejoined")
            expect.contains(event.description, "\n", "the escaped \\n should become a newline")
            expect.contains(result.productID, "Test, Inc.", "escaped comma in PRODID")
        },

        TestCase(group: "iCal", name: "falls back to DURATION when DTEND is missing") { expect in
            let result = try ICalParser.parse(Fixtures.foldedAndEscaped)
            guard let event = result.events.first else { return expect.fail("no event") }
            expect.equal(event.resolvedCheckIn, DayMath.day(2027, 11, 1))
            expect.equal(event.resolvedCheckOut, DayMath.day(2027, 11, 4), "P3D = three nights")
        },

        TestCase(group: "iCal", name: "reads STATUS:CANCELLED") { expect in
            let result = try ICalParser.parse(Fixtures.cancelledEvent)
            guard let event = result.events.first else { return expect.fail("no event") }
            expect.equal(FeedEventStatus.parse(event.status), .cancelled)
        },

        TestCase(group: "iCal", name: "rejects a response that is not a calendar") { expect in
            do {
                _ = try ICalParser.parse("<html><body>Sign in to continue</body></html>")
                expect.fail("an HTML error page should not parse as a calendar")
            } catch {
                // expected: platforms sometimes return HTML with a 200 status
            }
        },

        TestCase(group: "iCal", name: "an event with no UID still imports, with a warning") { expect in
            let text = Fixtures.calendar("-//Test//EN", """
                BEGIN:VEVENT
                DTSTART;VALUE=DATE:20270101
                DTEND;VALUE=DATE:20270105
                SUMMARY:Blocked
                END:VEVENT
                """)
            let result = try ICalParser.parse(text)
            expect.equal(result.events.count, 1)
            expect.ok(result.events.first?.uid.hasPrefix("synthetic-") == true,
                      "a stable identifier should be synthesised")
            expect.ok(!result.warnings.isEmpty, "the owner should be warned about it")
        },

        TestCase(group: "iCal", name: "identical input produces an identical content hash") { expect in
            let a = try ICalParser.parse(Fixtures.vrboBlocks).events
            let b = try ICalParser.parse(Fixtures.vrboBlocks).events
            expect.equal(a.count, b.count)
            for (left, right) in zip(a, b) {
                expect.equal(left.contentHash(), right.contentHash())
            }
        },
    ] }
}

// MARK: - Classifier

public enum ClassifierTests {
    private static func classify(
        _ feed: String, _ platform: RentalPlatform, index: Int = 0
    ) throws -> (ICalEvent, ClassificationProposal) {
        let events = try ICalParser.parse(feed).events
        let event = events[index]
        let nights = max(1, DayMath.daysBetween(
            event.resolvedCheckIn ?? Date(), event.resolvedCheckOut ?? Date()
        ))
        return (event, BlockClassifier().classify(event: event, platform: platform, nights: nights))
    }

    public static var cases: [TestCase] { [
        TestCase(group: "Classifier",
                 name: "an Airbnb booking with a reservation URL is confirmed, high confidence") { expect in
            let (_, proposal) = try classify(Fixtures.airbnbConfirmedBooking, .airbnb)
            expect.equal(proposal.kind, .confirmedReservation)
            expect.equal(proposal.confidence, .high)
            expect.ok(!proposal.needsReview, "strong evidence should not need review")
        },

        TestCase(group: "Classifier",
                 name: "an opaque Airbnb block is unknown and needs review") { expect in
            let (_, proposal) = try classify(Fixtures.airbnbCancellationBlock, .airbnb)
            expect.equal(proposal.kind, .unknownUnavailable)
            expect.ok(proposal.needsReview, "an unexplained block must go to the owner")
            expect.contains(proposal.rationale.lowercased(), "cancellation",
                            "the rationale should name the risk")
        },

        TestCase(group: "Classifier",
                 name: "a Vrbo \"Blocked\" event is unknown, not an owner block") { expect in
            let (_, proposal) = try classify(Fixtures.vrboBlocks, .vrbo)
            expect.equal(proposal.kind, .unknownUnavailable)
            expect.ok(proposal.needsReview)
        },

        TestCase(group: "Classifier",
                 name: "a Vrbo \"Reserved\" event is a confirmed reservation") { expect in
            let (_, proposal) = try classify(Fixtures.vrboReservation, .vrbo)
            expect.equal(proposal.kind, .confirmedReservation)
            expect.equal(proposal.confidence, .high)
        },

        TestCase(group: "Classifier",
                 name: "Booking.com CLOSED proves nothing and needs review") { expect in
            let (_, proposal) = try classify(Fixtures.bookingClosed, .bookingCom)
            expect.equal(proposal.kind, .unknownUnavailable)
            expect.ok(proposal.needsReview)
            expect.contains(proposal.rationale, "Booking.com")
        },

        TestCase(group: "Classifier", name: "maintenance wording is recognised") { expect in
            let (_, proposal) = try classify(Fixtures.maintenance, .other)
            expect.equal(proposal.kind, .maintenanceBlock)
            expect.ok(proposal.needsReview, "medium confidence still needs review")
        },

        TestCase(group: "Classifier", name: "owner wording is recognised") { expect in
            let (_, proposal) = try classify(Fixtures.owner, .other)
            expect.equal(proposal.kind, .ownerBlock)
        },

        TestCase(group: "Classifier",
                 name: "a very long block is flagged as a booking-window artefact") { expect in
            // The third event runs 2027-05-01 to 2027-11-10: 193 nights.
            let (_, proposal) = try classify(Fixtures.airbnbOpaqueBlocks, .airbnb, index: 2)
            expect.equal(proposal.kind, .platformRestriction,
                         "long horizons now get their own classification")
            expect.ok(proposal.needsReview)
            expect.contains(proposal.rationale, "booking window",
                            "the owner should be told why it looks like an artefact")
        },

        TestCase(group: "Classifier",
                 name: "no automatic path produces an exportable block") { expect in
            let policy = ExportPolicy()
            let feeds = [
                (Fixtures.airbnbOpaqueBlocks, RentalPlatform.airbnb),
                (Fixtures.vrboBlocks, .vrbo),
                (Fixtures.bookingClosed, .bookingCom),
                (Fixtures.owner, .other),
                (Fixtures.maintenance, .other),
            ]
            for (feed, platform) in feeds {
                for (index, _) in try ICalParser.parse(feed).events.enumerated() {
                    let (icalEvent, proposal) = try classify(feed, platform, index: index)
                    guard proposal.kind != .confirmedReservation else { continue }
                    let key = EventKey.make(listingID: 1, uid: icalEvent.uid, recurrenceID: nil)
                    let classification = EventClassification(eventKey: key, proposal: proposal)
                    let event = CalendarEvent(
                        listingID: 1, eventKey: key, uid: icalEvent.uid, platform: platform,
                        summary: icalEvent.summary,
                        checkIn: icalEvent.resolvedCheckIn!, checkOut: icalEvent.resolvedCheckOut!
                    )
                    let decision = policy.decide(event: event, classification: classification)
                    expect.ok(
                        !decision.isIncluded,
                        "an auto-classified block must never export: \(platform.displayName) "
                            + "\"\(icalEvent.summary)\""
                    )
                }
            }
        },
    ] }
}
