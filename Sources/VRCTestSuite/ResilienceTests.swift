import Foundation
import VRCCore

/// What happens when things go temporarily wrong, and what must not.
///
/// The governing rule is in CLAUDE.md: **a failed, empty or truncated feed
/// withdraws nothing.** Every scenario here is a way the app can fail
/// transiently, and in each one the test asserts both that it recovers on its
/// own and that no night was lost while it was broken.
///
/// These are not hypothetical. On 2026-11-10 a four-second Keychain deadline
/// expired under build load, the timeout was classified as a dead credential,
/// three working feeds went silent for an hour, and a real Airbnb reservation
/// went unimported. Recovery required editing the database by hand.
public enum ResilienceTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

    /// A store on a shared database, so a "restart" can rebuild it.
    static func make(
        credentials: FeedCredentialStore, database: Database
    ) throws -> (store: RentalStore, listingID: Int64) {
        let store = try RentalStore(database: database, credentials: credentials)
        if let existing = try store.listings.all().first { return (store, existing.id!) }
        let property = try store.properties.insert(Property(name: "39 G Street"))
        let listing = try store.listings.insert(PlatformListing(
            propertyID: property.id!, platform: .airbnb, label: "Airbnb",
            urlStorage: .keychain, credentialRef: "airbnb-v6"))
        try store.listings.setConnectionState(listingID: listing.id!, to: .connected, actor: "test")
        return (store, listing.id!)
    }

    static func feed(_ url: String) -> StubFeedFetcher {
        StubFeedFetcher(texts: [url: Fixtures.airbnbConfirmedBooking])
    }

    public static var cases: [TestCase] { [

        // --- Restart ----------------------------------------------------------

        TestCase(group: "Resilience",
                 name: "a restart does not lose access or observations") { expect in
            let database = try Database.inMemory()
            let credentials = InMemoryFeedCredentialStore()
            try credentials.save(url: "https://a.test/f.ics", reference: "airbnb-v6")

            let first = try make(credentials: credentials, database: database)
            _ = await first.store.makeImportService(fetcher: feed("https://a.test/f.ics"))
                .importFeed(for: try first.store.listings.find(id: first.listingID)!)
            let before = try first.store.events.allActive().count
            expect.ok(before > 0, "precondition: something was imported")

            // "Restart": a brand new store over the same database.
            let second = try make(credentials: credentials, database: database)
            expect.equal(try second.store.events.allActive().count, before,
                         "observations survive a restart")
            expect.equal(try second.store.listings.find(id: second.listingID)?.connectionState,
                         .connected)
            expect.equal(try second.store.unreadableCredentials().count, 0)
        },

        // --- Sleep and wake ---------------------------------------------------

        TestCase(group: "Resilience",
                 name: "a wake-from-sleep timeout recovers without intervention") { expect in
            // The first Keychain call after a long idle period can be slow.
            // One failure must not be permanent — and must not need a human.
            let database = try Database.inMemory()
            let backing = InMemoryFeedCredentialStore()
            try backing.save(url: "https://a.test/f.ics", reference: "airbnb-v6")
            let flaky = FlakyFeedCredentialStore(wrapping: backing, failingFirst: 1)

            let setup = try make(credentials: flaky, database: database)
            let fetcher = feed("https://a.test/f.ics")

            _ = await setup.store.makeImportService(fetcher: fetcher)
                .importFeed(for: try setup.store.listings.find(id: setup.listingID)!)
            expect.equal(try setup.store.listings.find(id: setup.listingID)?.connectionState,
                         .failing, "a timeout is transient, not a dead credential")

            // The very next refresh, with nobody touching anything.
            let report = await setup.store.makeImportService(fetcher: fetcher)
                .importFeed(for: try setup.store.listings.find(id: setup.listingID)!)
            expect.equal(report.run.outcome, .success)
            expect.equal(try setup.store.listings.find(id: setup.listingID)?.connectionState,
                         .connected)
        },

        TestCase(group: "Resilience",
                 name: "repeated transient failures still never latch") { expect in
            // Five in a row. The feed must still be willing to try a sixth
            // time: there is no failure count at which a timeout becomes
            // evidence about the credential.
            let backing = InMemoryFeedCredentialStore()
            try backing.save(url: "https://a.test/f.ics", reference: "airbnb-v6")
            let flaky = FlakyFeedCredentialStore(wrapping: backing, failingFirst: 5)
            let setup = try make(credentials: flaky, database: try Database.inMemory())
            let fetcher = feed("https://a.test/f.ics")

            for _ in 0..<5 {
                _ = await setup.store.makeImportService(fetcher: fetcher)
                    .importFeed(for: try setup.store.listings.find(id: setup.listingID)!)
            }
            let listing = try setup.store.listings.find(id: setup.listingID)!
            expect.ok(listing.connectionState.shouldAttemptImport,
                      "after five timeouts it must still be retryable")

            let report = await setup.store.makeImportService(fetcher: fetcher)
                .importFeed(for: listing)
            expect.equal(report.run.outcome, .success, "and the sixth attempt works")
        },

        // --- Network ----------------------------------------------------------

        TestCase(group: "Resilience",
                 name: "a network interruption withdraws nothing") { expect in
            // The rule this project exists for. A feed that fails to load must
            // never be read as "those nights are free now".
            let database = try Database.inMemory()
            let credentials = InMemoryFeedCredentialStore()
            try credentials.save(url: "https://a.test/f.ics", reference: "airbnb-v6")
            let setup = try make(credentials: credentials, database: database)

            _ = await setup.store.makeImportService(fetcher: feed("https://a.test/f.ics"))
                .importFeed(for: try setup.store.listings.find(id: setup.listingID)!)
            let before = try setup.store.events.allActive().count
            expect.ok(before > 0)

            // Now the network is gone.
            let offline = StubFeedFetcher(responses: [
                "https://a.test/f.ics": .failure(.transport("offline")),
            ])
            let report = await setup.store.makeImportService(fetcher: offline)
                .importFeed(for: try setup.store.listings.find(id: setup.listingID)!)

            expect.ok(report.run.outcome != .success)
            expect.equal(try setup.store.events.allActive().count, before,
                         "a failed fetch removes nothing")
            expect.equal(report.run.eventsTombstoned, 0, "and tombstones nothing")
            expect.ok(try setup.store.listings.find(id: setup.listingID)!
                        .connectionState.shouldAttemptImport,
                      "a network failure stays retryable")
        },

        TestCase(group: "Resilience",
                 name: "an empty feed after a good one withdraws nothing") { expect in
            // A truncated or empty response is indistinguishable from "the
            // platform cancelled everything", so it is never believed.
            let database = try Database.inMemory()
            let credentials = InMemoryFeedCredentialStore()
            try credentials.save(url: "https://a.test/f.ics", reference: "airbnb-v6")
            let setup = try make(credentials: credentials, database: database)

            _ = await setup.store.makeImportService(fetcher: feed("https://a.test/f.ics"))
                .importFeed(for: try setup.store.listings.find(id: setup.listingID)!)
            let before = try setup.store.events.allActive().count

            let empty = StubFeedFetcher(texts: [
                "https://a.test/f.ics": "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n",
            ])
            _ = await setup.store.makeImportService(fetcher: empty)
                .importFeed(for: try setup.store.listings.find(id: setup.listingID)!)

            expect.equal(try setup.store.events.allActive().count, before,
                         "an empty calendar is not a withdrawal")
        },

        // --- Recovery ---------------------------------------------------------

        TestCase(group: "Resilience",
                 name: "recovery restores the connection and imports no duplicates") { expect in
            let database = try Database.inMemory()
            let credentials = InMemoryFeedCredentialStore()
            try credentials.save(url: "https://a.test/f.ics", reference: "airbnb-v6")
            let setup = try make(credentials: credentials, database: database)
            let fetcher = feed("https://a.test/f.ics")

            _ = await setup.store.makeImportService(fetcher: fetcher)
                .importFeed(for: try setup.store.listings.find(id: setup.listingID)!)
            let settled = try setup.store.events.allActive().count

            let offline = StubFeedFetcher(responses: [
                "https://a.test/f.ics": .failure(.transport("offline")),
            ])
            _ = await setup.store.makeImportService(fetcher: offline)
                .importFeed(for: try setup.store.listings.find(id: setup.listingID)!)

            let report = await setup.store.makeImportService(fetcher: fetcher)
                .importFeed(for: try setup.store.listings.find(id: setup.listingID)!)
            expect.equal(report.run.outcome, .success)
            expect.equal(report.run.eventsInserted, 0, "recovery must not duplicate")
            expect.equal(try setup.store.events.allActive().count, settled)
            expect.equal(try setup.store.listings.find(id: setup.listingID)?.connectionState,
                         .connected)
        },
    ] }
}
