import Foundation
import VRCCore

/// Importing must respect what the owner has taken out of service.
///
/// `FeedRefreshQueue` already re-checks a QUEUED feed when its turn comes, but
/// that only covered requests travelling through the queue. A "Refresh all"
/// pass walked the listing list it captured when the pass began and handed
/// every one of them to `importFeed`, so a property archived mid-pass still had
/// its calendars fetched. The check therefore belongs in `ImportService`, which
/// is the single door every import goes through — the app's per-feed refresh,
/// the queue drain, the bulk pass and the `vrc` CLI all end up here, so none of
/// them can bypass it or forget to ask.
///
/// Two properties matter equally and are asserted separately throughout:
///
/// 1. A refused import is **recorded**, as an explicit skipped run. A silent
///    gap in the history is what made the dead Refresh button so hard to find.
/// 2. A refused import **withdraws nothing**. Skipping happens before any
///    reconciliation, so no observation is tombstoned and no classification is
///    touched. A night left on sale by mistake is recoverable; a night silently
///    withdrawn is lost revenue nobody notices.
public enum ArchivedPropertyImportTests {

    /// A store with two properties, three listings each, all wired to feeds
    /// that return one reservation apiece.
    static func makeTwoProperties() throws -> (
        store: RentalStore,
        propertyA: Int64, propertyB: Int64,
        listings: [Int64],
        fetcher: StubFeedFetcher
    ) {
        let store = try RentalStore(
            database: try Database.inMemory(),
            credentials: InMemoryFeedCredentialStore())
        var ids: [Int64] = []
        var texts: [String: String] = [:]
        var propertyIDs: [Int64] = []

        for name in ["39 G Street", "Test Cottage"] {
            let property = try store.properties.insert(Property(name: name))
            propertyIDs.append(property.id!)
            for platform in [RentalPlatform.airbnb, .vrbo, .bookingCom] {
                let url = "https://example.test/\(name.replacingOccurrences(of: " ", with: ""))"
                    + "-\(platform.rawValue).ics"
                let listing = try store.listings.insert(PlatformListing(
                    propertyID: property.id!, platform: platform,
                    label: "\(platform.displayName) — \(name)",
                    icalURL: url, urlStorage: .database))
                ids.append(listing.id!)
                texts[url] = Fixtures.airbnbConfirmedBooking
            }
        }
        return (store, propertyIDs[0], propertyIDs[1], ids, StubFeedFetcher(texts: texts))
    }

    /// Imports every listing, the way a "Refresh all" pass does.
    static func refreshAll(
        store: RentalStore, fetcher: FeedFetching, ids: [Int64]
    ) async throws -> [Int64: SyncRun] {
        var runs: [Int64: SyncRun] = [:]
        let service = store.makeImportService(fetcher: fetcher)
        for id in ids {
            guard let listing = try store.listings.find(id: id) else { continue }
            runs[id] = await service.importFeed(for: listing).run
        }
        return runs
    }

    public static var cases: [TestCase] { [

        // MARK: - Archived properties

        TestCase(group: "Archived import",
                 name: "an archived property's feed is refused with a recorded skip") { expect in
            let setup = try makeTwoProperties()
            let first = setup.listings[0]
            guard let listing = try setup.store.listings.find(id: first) else {
                return expect.fail("no listing")
            }
            let service = setup.store.makeImportService(fetcher: setup.fetcher)
            expect.equal(await service.importFeed(for: listing).run.outcome, .success,
                         "precondition: it imports while the property is active")

            try setup.store.properties.archive(id: setup.propertyA)
            let report = await service.importFeed(
                for: try setup.store.listings.find(id: first)!)

            expect.equal(report.run.outcome, .skipped)
            expect.contains(report.run.errorMessage ?? "", "archived")
            expect.contains(report.run.summaryLine, "Skipped")
            let recorded = try setup.store.syncRuns.recent(limit: 50)
                .filter { $0.listingID == first }
            expect.equal(recorded.count, 2, "the refusal is in the history, not a gap")
            expect.equal(recorded.first?.outcome, .skipped)
        },

        TestCase(group: "Archived import",
                 name: "a refused archived import withdraws nothing") { expect in
            // The rule that matters most. Archiving a property must not look
            // like an empty feed and quietly tombstone its observations.
            let setup = try makeTwoProperties()
            let first = setup.listings[0]
            let service = setup.store.makeImportService(fetcher: setup.fetcher)
            _ = await service.importFeed(for: try setup.store.listings.find(id: first)!)

            let activeBefore = try setup.store.events.allActive().count
            let classifiedBefore = try setup.store.classifications.all().count
            expect.ok(activeBefore > 0, "precondition: something was observed")

            try setup.store.properties.archive(id: setup.propertyA)
            let report = await service.importFeed(
                for: try setup.store.listings.find(id: first)!)

            expect.equal(report.run.eventsTombstoned, 0, "nothing withdrawn")
            expect.equal(report.run.eventsSeen, 0, "and nothing claimed to be read")
            expect.equal(try setup.store.events.allActive().count, activeBefore,
                         "every observation survives the refusal")
            expect.equal(try setup.store.classifications.all().count, classifiedBefore,
                         "and so does every decision about them")
        },

        TestCase(group: "Archived import",
                 name: "unarchiving lets the feed import again") { expect in
            // The refusal must be a reflection of current state, not a latch.
            let setup = try makeTwoProperties()
            let first = setup.listings[0]
            let service = setup.store.makeImportService(fetcher: setup.fetcher)
            try setup.store.properties.archive(id: setup.propertyA)
            expect.equal(
                await service.importFeed(
                    for: try setup.store.listings.find(id: first)!).run.outcome,
                .skipped)

            try setup.store.properties.unarchive(id: setup.propertyA)
            expect.equal(
                await service.importFeed(
                    for: try setup.store.listings.find(id: first)!).run.outcome,
                .success, "nothing had to be re-entered")
        },

        TestCase(group: "Archived import",
                 name: "the schema makes an orphaned listing impossible") { expect in
            // `ImportService` still refuses a listing whose property cannot be
            // found, because "I could not establish what this belongs to" must
            // not mean "import it anyway". That branch is unreachable through
            // the repository, and this is why: the foreign key refuses an
            // unknown property outright and cascades on delete, so a listing
            // can never outlive its property. Asserted rather than assumed —
            // if the constraint were ever dropped, the defensive branch is
            // what would catch it, and this test says so.
            let setup = try makeTwoProperties()
            var inserted = true
            do {
                _ = try setup.store.listings.insert(PlatformListing(
                    propertyID: 9_999, platform: .vrbo, label: "orphan",
                    icalURL: "https://example.test/orphan.ics", urlStorage: .database))
            } catch {
                inserted = false
            }
            expect.ok(!inserted, "a listing under an unknown property was accepted")

            let before = try setup.store.listings.all().count
            try setup.store.properties.delete(id: setup.propertyB)
            expect.equal(try setup.store.listings.all().count, before - 3,
                         "deleting a property takes its listings with it")
        },

        // MARK: - Requirement: the check cannot be bypassed

        TestCase(group: "Archived import",
                 name: "a property archived while the import was queued is refused") { expect in
            // The queue holds a listing value captured when it was clicked.
            // Importing from that stale value must still consult the database,
            // or a request made before archiving would be honoured after it.
            let setup = try makeTwoProperties()
            let first = setup.listings[0]
            guard let captured = try setup.store.listings.find(id: first) else {
                return expect.fail("no listing")
            }
            // Archived AFTER the value was captured — exactly the race.
            try setup.store.properties.archive(id: setup.propertyA)
            let report = await setup.store.makeImportService(fetcher: setup.fetcher)
                .importFeed(for: captured)
            expect.equal(report.run.outcome, .skipped,
                         "the stale listing value did not get it imported")
            expect.contains(report.run.errorMessage ?? "", "archived")
        },

        // MARK: - Disconnected and unconfigured feeds

        TestCase(group: "Archived import",
                 name: "a disconnected feed is refused, recorded, and withdraws nothing") { expect in
            let setup = try makeTwoProperties()
            let first = setup.listings[0]
            let service = setup.store.makeImportService(fetcher: setup.fetcher)
            _ = await service.importFeed(for: try setup.store.listings.find(id: first)!)
            let activeBefore = try setup.store.events.allActive().count

            try setup.store.listings.setConnectionState(
                listingID: first, to: .disconnectedByOwner,
                detail: "owner disconnected", actor: "test", at: Date())
            let report = await service.importFeed(
                for: try setup.store.listings.find(id: first)!)

            expect.equal(report.run.outcome, .disconnected)
            expect.equal(report.run.eventsTombstoned, 0, "nothing withdrawn")
            expect.equal(try setup.store.events.allActive().count, activeBefore)
            expect.ok(try setup.store.syncRuns.recent(limit: 50)
                        .contains { $0.listingID == first && $0.outcome == .disconnected },
                      "the refusal is recorded")
        },

        TestCase(group: "Archived import",
                 name: "an unconfigured feed is refused, recorded, and withdraws nothing") { expect in
            let setup = try makeTwoProperties()
            let bare = try setup.store.listings.insert(PlatformListing(
                propertyID: setup.propertyA, platform: .vrbo,
                label: "no URL yet", urlStorage: .database))
            let report = await setup.store.makeImportService(fetcher: setup.fetcher)
                .importFeed(for: bare)
            expect.equal(report.run.outcome, .skipped)
            expect.contains(report.run.errorMessage ?? "", "No calendar URL")
            expect.equal(report.run.eventsTombstoned, 0)
        },

        // MARK: - Across several properties

        TestCase(group: "Archived import",
                 name: "Refresh all imports the active property and skips the archived one") { expect in
            let setup = try makeTwoProperties()
            // Everything imports to begin with.
            let firstPass = try await refreshAll(
                store: setup.store, fetcher: setup.fetcher, ids: setup.listings)
            expect.equal(firstPass.values.filter { $0.outcome == .success }.count, 6,
                         "precondition: all six feeds import")
            let activeBefore = try setup.store.events.allActive().count

            // The owner archives Test Cottage.
            try setup.store.properties.archive(id: setup.propertyB)
            let secondPass = try await refreshAll(
                store: setup.store, fetcher: setup.fetcher, ids: setup.listings)

            let archivedIDs = Set(setup.listings.suffix(3))
            for (id, run) in secondPass {
                if archivedIDs.contains(id) {
                    expect.equal(run.outcome, .skipped, "listing \(id) is archived")
                    expect.equal(run.eventsTombstoned, 0)
                } else {
                    expect.equal(run.outcome, .success, "listing \(id) is still active")
                }
            }
            expect.equal(try setup.store.events.allActive().count, activeBefore,
                         "archiving one property withdrew nothing from either")
        },

        TestCase(group: "Archived import",
                 name: "archiving one property leaves the other's feeds untouched") { expect in
            let setup = try makeTwoProperties()
            _ = try await refreshAll(
                store: setup.store, fetcher: setup.fetcher, ids: setup.listings)
            try setup.store.properties.archive(id: setup.propertyA)
            let runs = try await refreshAll(
                store: setup.store, fetcher: setup.fetcher, ids: setup.listings)

            let archivedIDs = Set(setup.listings.prefix(3))
            expect.equal(runs.filter { archivedIDs.contains($0.key) }
                            .values.filter { $0.outcome == .skipped }.count, 3)
            expect.equal(runs.filter { !archivedIDs.contains($0.key) }
                            .values.filter { $0.outcome == .success }.count, 3)
            // And every refusal is in the history for both properties.
            let skipped = try setup.store.syncRuns.recent(limit: 100)
                .filter { $0.outcome == .skipped }
            expect.equal(Set(skipped.map(\.listingID)), archivedIDs,
                         "exactly the archived property's three feeds were skipped")
        },

        TestCase(group: "Archived import",
                 name: "archiving every property withdraws nothing at all") { expect in
            // The worst case for the tombstoning rule: a whole portfolio out
            // of service must not read as "every feed is now empty".
            let setup = try makeTwoProperties()
            _ = try await refreshAll(
                store: setup.store, fetcher: setup.fetcher, ids: setup.listings)
            let activeBefore = try setup.store.events.allActive().count
            let classifiedBefore = try setup.store.classifications.all().count

            try setup.store.properties.archive(id: setup.propertyA)
            try setup.store.properties.archive(id: setup.propertyB)
            let runs = try await refreshAll(
                store: setup.store, fetcher: setup.fetcher, ids: setup.listings)

            expect.equal(runs.values.filter { $0.outcome == .skipped }.count, 6)
            expect.equal(runs.values.reduce(0) { $0 + $1.eventsTombstoned }, 0)
            expect.equal(try setup.store.events.allActive().count, activeBefore,
                         "all observations survive")
            expect.equal(try setup.store.classifications.all().count, classifiedBefore)
        },
    ] }
}
