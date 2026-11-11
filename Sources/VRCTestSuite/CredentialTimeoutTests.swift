import Foundation
import VRCCore

/// A slow Keychain is not a broken one.
///
/// On 2026-11-10 three working feeds went silent for an hour and a real
/// Airbnb reservation — 4 to 12 January, eight nights — was not imported.
/// Nothing was wrong with the credentials: `vrc doctor` read all three
/// moments later. The machine was busy, a Keychain read exceeded
/// `DeadlineFeedCredentialStore`'s four-second limit, and `ImportService`
/// treated *any* failure to resolve a URL as `credentialUnreadable`.
///
/// That state is deliberately never retried, because a credential whose
/// access list names a build that no longer exists will never become readable
/// and hammering it only produces noise. A **timeout is the opposite**: it
/// says nothing about the credential, only about this moment.
///
/// Conflating the two means any heavy load can permanently disconnect every
/// calendar, silently, until someone re-enters URLs that were never wrong.
public enum CredentialTimeoutTests {

    static func store(_ credentials: FeedCredentialStore) throws -> (RentalStore, Int64) {
        let store = try RentalStore(database: Database.inMemory(), credentials: credentials)
        let property = try store.properties.insert(Property(name: "39 G Street"))
        let listing = try store.listings.insert(PlatformListing(
            propertyID: property.id!, platform: .airbnb, label: "Airbnb",
            urlStorage: .keychain, credentialRef: "airbnb-v6"))
        try store.listings.setConnectionState(
            listingID: listing.id!, to: .connected, actor: "test")
        return (store, listing.id!)
    }

    public static var cases: [TestCase] { [

        TestCase(group: "Credential timeout",
                 name: "a timeout leaves the feed retryable, not written off") { expect in
            let (store, listingID) = try self.store(TimingOutFeedCredentialStore())
            let listing = try store.listings.find(id: listingID)!

            _ = await store.makeImportService(fetcher: StubFeedFetcher(texts: [:]))
                .importFeed(for: listing)

            let after = try store.listings.find(id: listingID)!
            expect.equal(after.connectionState, .failing,
                         "a slow Keychain says nothing about the credential")
            expect.ok(after.connectionState.shouldAttemptImport,
                      "and the next refresh must try again")
        },

        TestCase(group: "Credential timeout",
                 name: "a genuine access failure is still written off") { expect in
            // The distinction the fix rests on. An access list naming a build
            // that no longer exists will never become readable, and retrying
            // it forever is what the latch is for.
            let (store, listingID) = try self.store(
                UnreadableFeedCredentialStore(presentReferences: ["airbnb-v6"]))
            let listing = try store.listings.find(id: listingID)!

            _ = await store.makeImportService(fetcher: StubFeedFetcher(texts: [:]))
                .importFeed(for: listing)

            let after = try store.listings.find(id: listingID)!
            expect.equal(after.connectionState, .credentialUnreadable)
            expect.ok(!after.connectionState.shouldAttemptImport)
        },

        TestCase(group: "Credential timeout",
                 name: "a timed-out feed recovers on its own once the machine is free") { expect in
            // The property that actually matters: no human intervention. The
            // incident required a manual database edit to clear the latch.
            let credentials = InMemoryFeedCredentialStore()
            let (store, listingID) = try self.store(TimingOutFeedCredentialStore())
            var listing = try store.listings.find(id: listingID)!

            _ = await store.makeImportService(fetcher: StubFeedFetcher(texts: [:]))
                .importFeed(for: listing)
            expect.equal(try store.listings.find(id: listingID)?.connectionState, .failing)

            // Same listing, a store that now answers.
            try credentials.save(url: "https://a.test/f.ics", reference: "airbnb-v6")
            let recovered = try RentalStore(database: store.database, credentials: credentials)
            listing = try recovered.listings.find(id: listingID)!
            expect.ok(listing.connectionState.shouldAttemptImport,
                      "it must be willing to try without anyone editing a database")

            let report = await recovered.makeImportService(
                fetcher: StubFeedFetcher(texts: ["https://a.test/f.ics": Fixtures.airbnbConfirmedBooking]))
                .importFeed(for: listing)
            expect.equal(report.run.outcome, .success)
            expect.equal(try recovered.listings.find(id: listingID)?.connectionState, .connected)
        },

        TestCase(group: "Credential timeout",
                 name: "the deadline is long enough to survive a busy machine") { expect in
            // Four seconds was not. The limit exists so an abandoned
            // authorisation prompt cannot freeze the app forever, and a bound
            // an order of magnitude larger still achieves that while no longer
            // tripping on ordinary load.
            expect.ok(DeadlineFeedCredentialStore.defaultTimeout >= 15,
                      "got \(DeadlineFeedCredentialStore.defaultTimeout)s")
            expect.ok(DeadlineFeedCredentialStore.defaultTimeout <= 60,
                      "still bounded — a frozen app is the thing being prevented")
        },
    ] }
}
