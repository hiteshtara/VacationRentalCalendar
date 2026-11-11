import Foundation
import VRCCore

/// Three properties, independent connections, and nothing leaking between them.
///
/// Most of the isolation this needs is already real: `platform_listings`
/// carries `property_id`, events hang off a listing, and `ConflictDetector`
/// groups by property before comparing anything. These tests pin that down so
/// a portfolio cannot silently regress into a single-property app — and cover
/// the three places where it was NOT real:
///
/// * `properties.time_zone` has existed since migration 10 and was never in
///   the model, so a property's nights could not actually be counted in its
///   own zone;
/// * there was no way to archive a property without deleting its history;
/// * credential references were derived from the platform and the listing
///   LABEL alone, so two properties whose listings are both called "Airbnb"
///   would resolve to one Keychain item and share a feed URL.
public enum MultiPropertyTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

    struct Portfolio {
        var store: RentalStore
        var ids: [String: Int64] = [:]
        var listings: [String: Int64] = [:]
    }

    /// Three properties, each with its own Airbnb and Vrbo listing, and each
    /// with one blocked week over the SAME dates — the arrangement that would
    /// expose cross-property bleeding if it existed.
    static func portfolio() throws -> Portfolio {
        let store = try RentalStore.makeInMemory()
        var p = Portfolio(store: store)
        for name in ["39 G Street", "Harbour Cottage", "Mill House"] {
            let property = try store.properties.insert(
                Property(name: name, address: "\(name), Boston"))
            p.ids[name] = property.id!
            for platform in [RentalPlatform.airbnb, .vrbo] {
                let listing = try store.listings.insert(PlatformListing(
                    propertyID: property.id!, platform: platform,
                    // Identical labels across properties on purpose: this is
                    // what collided in the credential store.
                    label: platform.displayName,
                    icalURL: "https://example.test/\(name)-\(platform.rawValue).ics",
                    urlStorage: .database))
                p.listings["\(name)/\(platform.rawValue)"] = listing.id!
                let key = "evt-\(name)-\(platform.rawValue)"
                try store.events.upsert(CalendarEvent(
                    listingID: listing.id!, eventKey: key, uid: key, platform: platform,
                    summary: "Blocked",
                    checkIn: day(2027, 7, 1), checkOut: day(2027, 7, 8)))
                try store.classifications.save(EventClassification(
                    eventKey: key, kind: .ownerBlock, confidence: .high,
                    source: .manual, needsReview: false))
            }
        }
        return p
    }

    public static var cases: [TestCase] { [

        // --- Isolation --------------------------------------------------------

        TestCase(group: "Multi-property",
                 name: "each property sees only its own observations") { expect in
            let p = try portfolio()
            let all = try p.store.classifiedEvents()
            expect.equal(all.count, 6, "three properties, two listings each")
            for (name, id) in p.ids {
                let mine = all.filter { $0.propertyID == id }
                expect.equal(mine.count, 2, "\(name) owns exactly its own two")
                expect.ok(mine.allSatisfy { $0.propertyName == name })
            }
        },

        TestCase(group: "Multi-property",
                 name: "identical dates on different properties are not a conflict") { expect in
            // All three are blocked 1–8 July. If the detector compared events
            // globally, this would report six-way double bookings and the
            // portfolio would be unusable from the first day.
            let p = try portfolio()
            let conflicts = try p.store.conflicts()
            expect.ok(conflicts.allSatisfy { conflict in
                p.ids.values.contains(conflict.propertyID)
            }, "every conflict belongs to a real property")
            for id in p.ids.values {
                let mine = conflicts.filter { $0.propertyID == id }
                expect.equal(mine.count, 1,
                             "only the Airbnb/Vrbo overlap WITHIN the property counts")
            }
            expect.equal(conflicts.count, 3, "three properties, one internal overlap each")
        },

        TestCase(group: "Multi-property",
                 name: "an availability decision never reaches another property's feed") { expect in
            let p = try portfolio()
            let mine = p.ids["39 G Street"]!
            let other = p.ids["Mill House"]!
            let submitted = try p.store.availabilityManager.submit(AvailabilityPlan(
                propertyID: mine, startDay: day(2027, 9, 1), endDay: day(2027, 9, 5),
                reason: "Test", actions: [.vrbo: .block]))
            _ = try p.store.availabilityManager.approve(decisionID: submitted[0].id!)

            let ours = try p.store.outbound.generateFeed(propertyID: mine, destination: .vrbo)
            let theirs = try p.store.outbound.generateFeed(propertyID: other, destination: .vrbo)
            expect.ok(ours.entries.contains { $0.startDay == day(2027, 9, 1) },
                      "it belongs to the property that made it")
            expect.ok(!theirs.entries.contains { $0.startDay == day(2027, 9, 1) },
                      "and must not appear anywhere else")
        },

        TestCase(group: "Multi-property",
                 name: "a revoked feed on one property leaves the others importable") { expect in
            let p = try portfolio()
            let dead = p.listings["Harbour Cottage/airbnb"]!
            try p.store.listings.setConnectionState(
                listingID: dead, to: .revoked, detail: "Invalid Token", actor: "test")

            for (key, id) in p.listings where id != dead {
                let listing = try p.store.listings.find(id: id)!
                expect.ok(listing.connectionState.shouldAttemptImport,
                          "\(key) must be unaffected")
            }
        },

        TestCase(group: "Multi-property",
                 name: "the review queue can be narrowed to one property") { expect in
            let p = try portfolio()
            let key = "evt-Mill House-airbnb"
            try p.store.classifications.save(EventClassification(
                eventKey: key, kind: .unknownUnavailable, confidence: .low,
                source: .automatic, needsReview: true))

            let queue = try p.store.needsReview()
            expect.equal(queue.count, 1)
            expect.equal(queue.first?.propertyID, p.ids["Mill House"])
            for (name, id) in p.ids where name != "Mill House" {
                expect.equal(queue.filter { $0.propertyID == id }.count, 0,
                             "\(name) has nothing awaiting review")
            }
        },

        // --- Credential isolation ---------------------------------------------

        TestCase(group: "Multi-property",
                 name: "identically-labelled listings never share a credential reference") { expect in
            // The real hazard. Two properties each with a listing called
            // "Airbnb" resolved to `airbnb-airbnb` for both, so one Keychain
            // item would back two feeds — and revoking one would break the
            // other, across properties.
            let p = try portfolio()
            var seen: Set<String> = []
            for (key, id) in p.listings {
                let listing = try p.store.listings.find(id: id)!
                let reference = ListingRepository.credentialReference(
                    platform: listing.platform, listingLabel: listing.label,
                    propertyID: listing.propertyID)
                expect.ok(!seen.contains(reference),
                          "\(key) collided on reference \(reference)")
                seen.insert(reference)
            }
            expect.equal(seen.count, 6)
        },

        // --- Property management ----------------------------------------------

        TestCase(group: "Multi-property",
                 name: "a property's time zone round-trips") { expect in
            // The column has existed since migration 10 and was never read or
            // written, so "count this property's nights in its own zone" was
            // not actually possible.
            let store = try RentalStore.makeInMemory()
            let saved = try store.properties.insert(
                Property(name: "Harbour Cottage", timeZone: "America/New_York"))
            expect.equal(try store.properties.find(id: saved.id!)?.timeZone,
                         "America/New_York")

            var edited = try store.properties.find(id: saved.id!)!
            edited.timeZone = "Europe/London"
            try store.properties.update(edited)
            expect.equal(try store.properties.find(id: saved.id!)?.timeZone, "Europe/London")
        },

        TestCase(group: "Multi-property",
                 name: "archiving keeps every record and only hides the property") { expect in
            // Archiving must never be deletion. The whole value of the history
            // is that it explains what happened to nights that are now past.
            let p = try portfolio()
            let id = p.ids["Mill House"]!
            try p.store.properties.archive(id: id, at: Date())

            let active = try p.store.properties.active()
            expect.equal(active.count, 2, "it drops out of the portfolio")
            expect.ok(!active.contains { $0.id == id })

            expect.ok(try p.store.properties.find(id: id) != nil, "the row survives")
            expect.ok(try p.store.properties.find(id: id)?.archivedAt != nil)
            expect.equal(try p.store.properties.all().count, 3, "all() still sees it")
            expect.equal(try p.store.classifiedEvents().filter { $0.propertyID == id }.count, 2,
                         "its observations are untouched")
        },

        TestCase(group: "Multi-property",
                 name: "archiving is reversible") { expect in
            let p = try portfolio()
            let id = p.ids["Mill House"]!
            try p.store.properties.archive(id: id, at: Date())
            try p.store.properties.unarchive(id: id)
            expect.equal(try p.store.properties.active().count, 3)
            expect.ok(try p.store.properties.find(id: id)?.archivedAt == nil)
        },

        // --- Migration --------------------------------------------------------

        TestCase(group: "Multi-property",
                 name: "the migration is repeatable and preserves existing rows") { expect in
            // Running the migrator twice must be a no-op, and an existing
            // property must survive with a sane default rather than a NULL.
            let path = Fixtures.temporaryDatabasePath()
            defer { try? FileManager.default.removeItem(atPath: path) }

            let first = try RentalStore(
                database: try Database(path: path), credentials: InMemoryFeedCredentialStore())
            let saved = try first.properties.insert(Property(name: "39 G Street"))

            let second = try RentalStore(
                database: try Database(path: path), credentials: InMemoryFeedCredentialStore())
            let reloaded = try second.properties.find(id: saved.id!)
            expect.equal(reloaded?.name, "39 G Street", "the row survives a second migration")
            expect.ok(reloaded?.archivedAt == nil, "and is active, not archived")
            expect.ok(!(reloaded?.timeZone ?? "").isEmpty, "with a usable time zone")
        },
    ] }
}
