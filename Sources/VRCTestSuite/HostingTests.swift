import Foundation
import VRCCore

public enum HostingTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

    static let configuration = R2HostingConfiguration(
        accountID: "acct123", bucket: "vrc-feeds",
        customDomain: "feeds.example.test", zoneID: "zone123"
    )

    /// A store with one property, three fresh listings and two approved Vrbo
    /// blocks — the shape of the December test.
    static func decemberStore() throws -> (store: RentalStore, propertyID: Int64) {
        let store = try RentalStore.makeInMemory()
        let property = try store.properties.insert(Property(name: "39 G Street"))
        let id = property.id!
        for platform in [RentalPlatform.airbnb, .vrbo, .bookingCom] {
            let listing = try store.listings.insert(PlatformListing(
                propertyID: id, platform: platform, label: platform.displayName,
                icalURL: "https://example.test/\(platform.rawValue).ics",
                urlStorage: .database, connectionState: .connected
            ))
            try store.listings.recordSync(listingID: listing.id!, at: Date(), summary: "ok")
        }
        for (index, range) in [((2026, 12, 10), (2026, 12, 17)),
                               ((2026, 12, 19), (2026, 12, 20))].enumerated() {
            _ = try store.availability.insert(AvailabilityDecision(
                propertyID: id, destination: .vrbo, action: .block,
                startDay: day(range.0.0, range.0.1, range.0.2),
                endDay: day(range.1.0, range.1.1, range.1.2),
                status: .approved, publicationUID: "vrc-dec-\(index)", approvedAt: Date()
            ))
        }
        return (store, id)
    }

    static func sandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vrc-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    public static var cases: [TestCase] { [

        // --- URL and key structure ----------------------------------------

        TestCase(group: "Hosting", name: "the feed URL is unguessable and per destination") { expect in
            let token = FeedTokenRepository.generateKey()
            expect.equal(token.count, 32, "128 bits of hex")

            let vrbo = configuration.key(propertySlug: "39-g-street", destination: .vrbo, token: token)
            let airbnb = configuration.key(propertySlug: "39-g-street", destination: .airbnb, token: token)
            expect.ok(vrbo != airbnb, "each destination has its own path")
            expect.contains(vrbo, "/vrbo/")
            expect.ok(vrbo.hasSuffix(".ics"))

            let url = configuration.publicURL(
                propertySlug: "39-g-street", destination: .vrbo, token: token
            )
            expect.ok(url.hasPrefix("https://"), "https only")
            expect.contains(url, "feeds.example.test")
            expect.notContains(url, "r2.dev", "the development subdomain is never used")

            // What the interface shows must not contain the token.
            let redacted = configuration.redactedURL(propertySlug: "39-g-street", destination: .vrbo)
            expect.notContains(redacted, token, "the token must never be displayed")
            expect.contains(redacted, "<32-hex-token>")
        },

        TestCase(group: "Hosting", name: "rotating the token changes the URL") { expect in
            let first = FeedTokenRepository.generateKey()
            let second = FeedTokenRepository.generateKey()
            expect.ok(first != second)
            expect.ok(
                configuration.publicURL(propertySlug: "p", destination: .vrbo, token: first)
                    != configuration.publicURL(propertySlug: "p", destination: .vrbo, token: second),
                "revocation works by making the old path a 404"
            )
        },

        TestCase(group: "Hosting", name: "caching is short and revalidated") { expect in
            expect.contains(R2HostingConfiguration.cacheControl, "max-age=60")
            expect.contains(R2HostingConfiguration.cacheControl, "must-revalidate")
        },

        // --- The pipeline, end to end against a local directory -------------

        TestCase(group: "Hosting",
                 name: "an approved feed reaches the served copy with 2 entries, 8 nights") { expect in
            let setup = try decemberStore()
            let root = try sandbox()
            defer { try? FileManager.default.removeItem(at: root) }
            let hosting = try LocalDirectoryHostingClient(root: root)
            let key = "feeds/39-g-street/vrbo/token.ics"

            let attempt = try await setup.store.outbound.runPipeline(
                propertyID: setup.propertyID, destination: .vrbo,
                hosting: hosting, key: key, changeApproved: true
            )
            expect.equal(attempt.stage, .platformRefreshPending)
            expect.ok(attempt.succeeded)
            expect.ok(!attempt.isRemoteSynchronised, "published is not synchronised")

            let served = await hosting.servedBody(key: key) ?? ""
            let parsed = try ICalParser.parse(served)
            expect.equal(parsed.events.count, 2, "exactly two entries")
            let nights = parsed.events.reduce(0) { total, event in
                total + DayMath.daysBetween(
                    event.resolvedCheckIn ?? Date(), event.resolvedCheckOut ?? Date()
                )
            }
            expect.equal(nights, 8, "exactly eight nights")
            expect.notContains(served, "Pemberton")
            expect.contains(served, "DTEND;VALUE=DATE:20261217", "checkout-exclusive survives")
        },

        TestCase(group: "Hosting",
                 name: "December 17 and 18 never appear in the served feed") { expect in
            let setup = try decemberStore()
            let root = try sandbox()
            defer { try? FileManager.default.removeItem(at: root) }
            let hosting = try LocalDirectoryHostingClient(root: root)
            let key = "k.ics"
            _ = try await setup.store.outbound.runPipeline(
                propertyID: setup.propertyID, destination: .vrbo,
                hosting: hosting, key: key, changeApproved: true
            )
            let served = await hosting.servedBody(key: key) ?? ""
            let parsed = try ICalParser.parse(served)
            for protectedNight in [day(2026, 12, 17), day(2026, 12, 18)] {
                let covered = parsed.events.contains { event in
                    guard let start = event.resolvedCheckIn,
                          let end = event.resolvedCheckOut else { return false }
                    return protectedNight >= start && protectedNight < end
                }
                expect.ok(!covered,
                          "\(DayMath.mediumString(protectedNight)) must stay on sale")
            }
        },

        TestCase(group: "Hosting", name: "nothing is served until the change is approved") { expect in
            let setup = try decemberStore()
            let root = try sandbox()
            defer { try? FileManager.default.removeItem(at: root) }
            let hosting = try LocalDirectoryHostingClient(root: root)
            let key = "k.ics"
            let attempt = try await setup.store.outbound.runPipeline(
                propertyID: setup.propertyID, destination: .vrbo,
                hosting: hosting, key: key, changeApproved: false
            )
            expect.equal(attempt.stage, .awaitingAdditionApproval)
            let served = await hosting.servedBody(key: key)
            expect.ok(served == nil, "nothing may be served without approval")
            let uploads = await hosting.uploadCount
            expect.equal(uploads, 0, "and nothing may even be uploaded")
        },

        // --- Failure and recovery --------------------------------------------

        TestCase(group: "Hosting", name: "a failed upload leaves the served feed intact") { expect in
            let setup = try decemberStore()
            let root = try sandbox()
            defer { try? FileManager.default.removeItem(at: root) }
            let hosting = try LocalDirectoryHostingClient(root: root)
            let key = "k.ics"
            _ = try await setup.store.outbound.runPipeline(
                propertyID: setup.propertyID, destination: .vrbo,
                hosting: hosting, key: key, changeApproved: true
            )
            let before = await hosting.servedBody(key: key)

            await hosting.setFailUpload("network down")
            let attempt = try await setup.store.outbound.runPipeline(
                propertyID: setup.propertyID, destination: .vrbo,
                hosting: hosting, key: key, changeApproved: true
            )
            expect.equal(attempt.stage, .failed)
            expect.contains(attempt.detail, "Upload failed")
            let after = await hosting.servedBody(key: key)
            expect.equal(after, before, "the previous feed keeps serving")
        },

        TestCase(group: "Hosting",
                 name: "a failed purge stops at uploaded and is not success") { expect in
            let setup = try decemberStore()
            let root = try sandbox()
            defer { try? FileManager.default.removeItem(at: root) }
            let hosting = try LocalDirectoryHostingClient(root: root)
            let key = "k.ics"
            await hosting.setFailInvalidation("purge 500")
            let attempt = try await setup.store.outbound.runPipeline(
                propertyID: setup.propertyID, destination: .vrbo,
                hosting: hosting, key: key, changeApproved: true
            )
            expect.equal(attempt.stage, .uploaded)
            expect.ok(!attempt.succeeded)
            // Origin has the new bytes; the served copy does not. That is the
            // state the stage exists to describe.
            let origin = await hosting.originBody(key: key)
            let served = await hosting.servedBody(key: key)
            expect.ok(origin != nil, "the object was written")
            expect.ok(served == nil, "but nobody is being served it")
        },

        TestCase(group: "Hosting",
                 name: "a half-published feed is never recorded as last known good") { expect in
            let setup = try decemberStore()
            let root = try sandbox()
            defer { try? FileManager.default.removeItem(at: root) }
            let hosting = try LocalDirectoryHostingClient(root: root)
            await hosting.setFailInvalidation("purge 500")
            _ = try await setup.store.outbound.runPipeline(
                propertyID: setup.propertyID, destination: .vrbo,
                hosting: hosting, key: "k.ics", changeApproved: true
            )
            let good = try setup.store.snapshots.lastKnownGood(
                propertyID: setup.propertyID, destination: .vrbo
            )
            expect.ok(good == nil,
                      "bytes nobody was served must never become the recovery point")
        },

        TestCase(group: "Hosting", name: "rollback restores the last known good feed") { expect in
            let setup = try decemberStore()
            let root = try sandbox()
            defer { try? FileManager.default.removeItem(at: root) }
            let hosting = try LocalDirectoryHostingClient(root: root)
            let key = "k.ics"

            _ = try await setup.store.outbound.runPipeline(
                propertyID: setup.propertyID, destination: .vrbo,
                hosting: hosting, key: key, changeApproved: true
            )
            let good = try setup.store.snapshots.lastKnownGood(
                propertyID: setup.propertyID, destination: .vrbo
            )
            expect.ok(good != nil, "a fully published feed is recorded as good")
            expect.equal(good?.entryCount, 2)

            // Something overwrites the served copy with rubbish.
            try await hosting.upload(key: key, body: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n",
                                     cacheControl: "x")
            try await hosting.invalidateCache(key: key)
            expect.equal((try ICalParser.parse(await hosting.servedBody(key: key) ?? "")).events.count, 0)

            let restored = try await setup.store.outbound.rollback(
                propertyID: setup.propertyID, destination: .vrbo, hosting: hosting, key: key
            )
            expect.equal(restored?.entryCount, 2)
            let recovered = try ICalParser.parse(await hosting.servedBody(key: key) ?? "")
            expect.equal(recovered.events.count, 2, "the good feed is serving again")
        },

        TestCase(group: "Hosting", name: "failures are reported with their reason") { expect in
            let setup = try decemberStore()
            let root = try sandbox()
            defer { try? FileManager.default.removeItem(at: root) }
            let hosting = try LocalDirectoryHostingClient(root: root)
            await hosting.setFailUpload("network down")
            _ = try await setup.store.outbound.runPipeline(
                propertyID: setup.propertyID, destination: .vrbo,
                hosting: hosting, key: "k.ics", changeApproved: true
            )
            let history = try setup.store.outbound.publicationHistory(
                propertyID: setup.propertyID, destination: .vrbo
            )
            expect.ok(!history.isEmpty)
            expect.equal(history.first?.stage, "failed")
            expect.contains(history.first?.detail ?? "", "network down")
        },

        // --- The gate --------------------------------------------------------

        TestCase(group: "Hosting", name: "the real publish entry point still refuses") { expect in
            expect.ok(!OutboundSyncGate.isEnabled)
            let setup = try decemberStore()
            do {
                _ = try setup.store.outbound.publish(
                    propertyID: setup.propertyID, destination: .vrbo
                )
                expect.fail("publish must refuse while the gate is shut")
            } catch let error as AvailabilityError {
                if case .outboundDisabled = error {} else { expect.fail("wrong error") }
            }
        },
    ] }
}
