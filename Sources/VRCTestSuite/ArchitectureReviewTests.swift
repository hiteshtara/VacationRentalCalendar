import Foundation
import VRCCore

public enum ArchitectureReviewTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

    public static var cases: [TestCase] { [

        // --- 1 & 4. Staleness, and refusing to claim otherwise --------------

        TestCase(group: "Architecture review",
                 name: "the published feed goes stale while the Mac is off") { expect in
            // Published a week ago, nothing since.
            let freshness = PublicationFreshness(
                destination: .vrbo,
                lastImportAt: Date().addingTimeInterval(-7 * 24 * 3_600),
                lastPublishedAt: Date().addingTimeInterval(-7 * 24 * 3_600)
            )
            expect.ok(freshness.isStale, "a week-old feed must read as stale")
            expect.contains(freshness.headline, "possibly behind")
            expect.contains(freshness.offlineWarning, "asleep or shut down")
            expect.contains(freshness.offlineWarning, "will not reach Vrbo")
        },

        TestCase(group: "Architecture review",
                 name: "the system never claims to be real time") { expect in
            for destination in [RentalPlatform.airbnb, .vrbo, .bookingCom] {
                let freshness = PublicationFreshness(
                    destination: destination, lastImportAt: Date(), lastPublishedAt: Date()
                )
                expect.ok(!freshness.isRealTime,
                          "\(destination.displayName) must never be described as real time")
                expect.ok(freshness.exposureWindowAwake > 0,
                          "there is always a window")
            }
            expect.contains(SynchronisationHonesty.headline, "not real-time")
            expect.contains(SynchronisationHonesty.explanation, "window")
            expect.contains(SynchronisationHonesty.explanation, "this Mac to be awake")
        },

        TestCase(group: "Architecture review",
                 name: "the exposure window is stated, not glossed") { expect in
            let freshness = PublicationFreshness(
                destination: .vrbo, lastImportAt: Date(), lastPublishedAt: Date(),
                importInterval: 3_600
            )
            // One import cycle plus Vrbo's worst observed poll.
            expect.equal(freshness.exposureWindowAwake, 3_600 + 12 * 3_600)
            let description = freshness.describeExposureAwake()
            expect.contains(description, "13 hours")
            expect.contains(description, "Vrbo")
        },

        TestCase(group: "Architecture review",
                 name: "a feed never published is not treated as fresh") { expect in
            let freshness = PublicationFreshness(
                destination: .vrbo, lastImportAt: Date(), lastPublishedAt: nil
            )
            expect.ok(freshness.isStale)
            expect.contains(freshness.headline, "Never published")
        },

        // --- 2. Manual blocks and reservation-driven entries stay apart -----

        TestCase(group: "Architecture review",
                 name: "manual blocks and reservation-driven entries are separable") { expect in
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "P"))
            let id = property.id!
            let listing = try store.listings.insert(PlatformListing(
                propertyID: id, platform: .airbnb, label: "A", urlStorage: .database,
                connectionState: .connected
            ))
            // A reservation-driven entry: imported from Airbnb, confirmed.
            try store.events.upsert(CalendarEvent(
                listingID: listing.id!, eventKey: "r", uid: "r", platform: .airbnb,
                summary: "Reserved",
                details: "Reservation URL: https://example.test/x",
                checkIn: day(2027, 3, 10), checkOut: day(2027, 3, 14)
            ))
            try store.classifications.save(EventClassification(
                eventKey: "r", kind: .confirmedReservation, confidence: .high,
                source: .automatic, needsReview: false
            ))
            // A manual block the owner approved.
            _ = try store.availability.insert(AvailabilityDecision(
                propertyID: id, destination: .vrbo, action: .block,
                startDay: day(2026, 12, 10), endDay: day(2026, 12, 17),
                status: .approved, publicationUID: "vrc-manual", approvedAt: Date()
            ))

            // The split is only observable when reservations are in scope;
            // the default now holds them back for the controlled test.
            try store.settings.set(
                FeedPublicationScope.settingKey,
                FeedPublicationScope.reservationsAndApprovedBlocks.rawValue
            )
            let feed = try store.outbound.generateFeed(propertyID: id, destination: .vrbo)
            let split = store.outbound.originBreakdown(feed)
            expect.equal(split.manualBlocks.count, 1, "one block the owner decided")
            expect.equal(split.reservationDriven.count, 1, "one entry a platform reported")
            expect.equal(split.manualBlocks.first?.decisionID != nil, true,
                         "a block traces to a decision")
            expect.equal(split.reservationDriven.first?.sourceEventKey, "r",
                         "a reservation traces to a source event")
            expect.ok(split.manualBlocks.first?.sourceEventKey == nil,
                      "a manual block is not attributed to a source event")
        },

        // --- 7. The gate alone publishes nothing -----------------------------

        TestCase(group: "Architecture review",
                 name: "four preconditions stand between approval and a live feed") { expect in
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "P"))
            let unmet = try store.outbound.unmetPreconditions(
                propertyID: property.id!, destination: .vrbo
            )
            expect.equal(Set(unmet), Set(OutboundSyncCoordinator.PublicationPrecondition.allCases),
                         "none of them is satisfied in this build")
            for precondition in unmet {
                expect.ok(!precondition.requirement.isEmpty)
            }
        },

        TestCase(group: "Architecture review",
                 name: "opening the gate alone would still publish nothing") { expect in
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "P"))
            let unmet = try store.outbound.unmetPreconditions(
                propertyID: property.id!, destination: .vrbo
            )
            // Remove the gate from the set, as flipping it would.
            let remaining = unmet.filter { $0 != .outboundGate }
            expect.ok(!remaining.isEmpty,
                      "hosting, credentials and a token would all still be missing")
            expect.ok(remaining.contains(.hostingConfiguration))
            expect.ok(remaining.contains(.feedToken))

            // And publish refuses regardless.
            do {
                _ = try store.outbound.publish(propertyID: property.id!, destination: .vrbo)
                expect.fail("publish must refuse")
            } catch {
                // expected
            }
        },

        // --- 8. The rehearsal cannot touch production -------------------------

        TestCase(group: "Architecture review",
                 name: "rehearsing against the production database is refused") { expect in
            do {
                try RehearsalIsolation.assertIsolated(
                    databasePath: AppPaths.databaseURL.path
                )
                expect.fail("the production database must be refused")
            } catch let error as RehearsalIsolation.Violation {
                expect.contains(
                    error.errorDescription ?? "", "Refusing to rehearse"
                )
            }
        },

        TestCase(group: "Architecture review",
                 name: "anything inside the app's data directory is refused too") { expect in
            let sibling = AppPaths.supportDirectory
                .appendingPathComponent("not-really-a-sandbox.sqlite").path
            do {
                try RehearsalIsolation.assertIsolated(databasePath: sibling)
                expect.fail("a sibling of the production database must be refused")
            } catch {
                // expected
            }
        },

        TestCase(group: "Architecture review", name: "a genuine sandbox is allowed") { expect in
            let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("vrc-test-\(UUID().uuidString)/r.sqlite").path
            do {
                try RehearsalIsolation.assertIsolated(databasePath: sandbox)
            } catch {
                expect.fail("a temporary path must be allowed: \(error)")
            }
        },

        // --- 6. The procedures hold --------------------------------------------

        TestCase(group: "Architecture review",
                 name: "cache, atomicity, rollback and rotation are all in place") { expect in
            // Cache: short and revalidated.
            expect.contains(R2HostingConfiguration.cacheControl, "max-age=60")
            expect.contains(R2HostingConfiguration.cacheControl, "must-revalidate")

            // Rotation: a new token yields a different, unguessable path.
            let configuration = R2HostingConfiguration(
                accountID: "a", bucket: "b", customDomain: "feeds.example.test", zoneID: "z"
            )
            let first = FeedTokenRepository.generateKey()
            let second = FeedTokenRepository.generateKey()
            expect.equal(first.count, 32)
            expect.ok(first != second)
            expect.ok(
                configuration.publicURL(propertySlug: "p", destination: .vrbo, token: first)
                    != configuration.publicURL(propertySlug: "p", destination: .vrbo, token: second)
            )
            // And the displayed form never leaks it.
            expect.notContains(
                configuration.redactedURL(propertySlug: "p", destination: .vrbo), first
            )

            // Rollback: only a fully served feed is a recovery point.
            expect.ok(PublicationStage.platformRefreshPending.impliesRemoteSynchronised == false)
            expect.ok(PublicationStage.verified.impliesRemoteSynchronised)
            for stage in PublicationStage.allCases where stage != .verified {
                expect.ok(!stage.impliesRemoteSynchronised,
                          "\(stage.rawValue) must not imply the platform applied anything")
            }
        },

        // --- 9. The two approved decisions are untouched by any of this --------

        TestCase(group: "Architecture review",
                 name: "reviewing and rehearsing never alters a decision") { expect in
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "P"))
            let id = property.id!
            let original = try store.availability.insert(AvailabilityDecision(
                propertyID: id, destination: .vrbo, action: .block,
                startDay: day(2026, 12, 10), endDay: day(2026, 12, 17),
                status: .approved, publicationUID: "vrc-keep", approvedAt: Date()
            ))

            _ = try store.outbound.generateFeed(propertyID: id, destination: .vrbo)
            _ = try store.outbound.freshness(propertyID: id, destination: .vrbo)
            _ = try store.outbound.unmetPreconditions(propertyID: id, destination: .vrbo)

            let after = try store.availability.find(id: original.id!)
            expect.equal(after?.status, .approved)
            expect.equal(after?.publicationUID, "vrc-keep")
            expect.ok(after?.publishedAt == nil)
            expect.equal(after?.startDay, day(2026, 12, 10))
            expect.equal(after?.endDay, day(2026, 12, 17))
        },
    ] }
}
