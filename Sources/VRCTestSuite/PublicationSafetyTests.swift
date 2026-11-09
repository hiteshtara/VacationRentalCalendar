import Foundation
import VRCCore

public enum PublicationSafetyTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

    /// A feed carrying one approved block.
    static func feed(
        destination: RentalPlatform = .vrbo,
        decisions: [AvailabilityDecision] = [],
        sourceEvents: [ClassifiedEvent] = []
    ) -> DestinationFeed {
        CalendarFeedGenerator().generate(
            destination: destination, propertyID: 1, propertyName: "39 G Street",
            sourceEvents: sourceEvents, decisions: decisions
        )
    }

    static func blockDecision(
        id: Int64 = 1, uid: String = "vrc-block-1",
        status: AvailabilityStatus = .approved,
        action: AvailabilityAction = .block,
        from: (Int, Int, Int) = (2026, 12, 10), to: (Int, Int, Int) = (2026, 12, 15),
        destination: RentalPlatform = .vrbo
    ) -> AvailabilityDecision {
        AvailabilityDecision(
            id: id, propertyID: 1, destination: destination, action: action,
            startDay: day(from.0, from.1, from.2), endDay: day(to.0, to.1, to.2),
            status: status, publicationUID: uid, approvedAt: Date()
        )
    }

    static func snapshot(
        entries: [SnapshotEntry], revision: Int = 1, destination: RentalPlatform = .vrbo
    ) -> FeedSnapshot {
        FeedSnapshot(
            id: 1, propertyID: 1, destination: destination, revision: revision,
            checksum: "abc", entries: entries, isLastKnownGood: true
        )
    }

    static let publishedBlock = SnapshotEntry(
        uid: "vrc-block-1", startDay: day(2026, 12, 10), endDay: day(2026, 12, 15),
        summary: "Not available"
    )

    static func healthyContext(
        decisions: [AvailabilityDecision] = [], sourceEvents: [ClassifiedEvent] = []
    ) -> PublicationContext {
        PublicationContext(
            listings: [
                PlatformListing(id: 1, propertyID: 1, platform: .airbnb, label: "A",
                                lastSyncAt: Date()),
                PlatformListing(id: 2, propertyID: 1, platform: .vrbo, label: "V",
                                lastSyncAt: Date()),
            ],
            recentSyncRuns: [
                SyncRun(listingID: 1, outcome: .success),
                SyncRun(listingID: 2, outcome: .success),
            ],
            decisions: decisions,
            sourceEvents: sourceEvents
        )
    }

    static func event(
        key: String, platform: RentalPlatform, kind: BlockKind, needsReview: Bool,
        from: (Int, Int, Int), to: (Int, Int, Int)
    ) -> ClassifiedEvent {
        ClassifiedEvent(
            event: CalendarEvent(
                listingID: 1, eventKey: key, uid: key, platform: platform, summary: "x",
                checkIn: day(from.0, from.1, from.2), checkOut: day(to.0, to.1, to.2)
            ),
            classification: EventClassification(
                eventKey: key, kind: kind, confidence: .high,
                source: .manual, needsReview: needsReview
            ),
            propertyID: 1, propertyName: "39 G Street"
        )
    }

    public static var cases: [TestCase] { [

        // --- 0. The approval chain stays intact --------------------------

        TestCase(group: "Publication safety",
                 name: "the approval chain keeps APPROVED distinct from PUBLISHED") { expect in
            expect.ok(AvailabilityStatus.awaitingApproval.allowedTransitions.contains(.approved),
                      "awaiting approval must lead to approved")
            expect.ok(AvailabilityStatus.approved.allowedTransitions.contains(.published),
                      "approved must lead to published")
            expect.ok(!AvailabilityStatus.awaitingApproval.allowedTransitions.contains(.published),
                      "approval must not be skippable")
            expect.ok(AvailabilityStatus.approved.contributesToFeed,
                      "approved work belongs in a generated feed")
            expect.ok(!AvailabilityStatus.approved.isTerminal)
            expect.ok(AvailabilityStatus.approved.displayName != AvailabilityStatus.published.displayName,
                      "the two states must read differently")
        },

        // --- 1. Accidental empty-feed publication ------------------------

        TestCase(group: "Publication safety",
                 name: "1. an empty feed caused by nothing explicable is refused") { expect in
            // The block has vanished from the proposal, and nothing explains it.
            let proposed = feed(decisions: [])
            let report = FeedPublicationSafety().assess(
                proposed: proposed,
                lastKnownGood: snapshot(entries: [publishedBlock]),
                context: healthyContext()
            )
            expect.ok(report.diff.wouldEmptyFeed)
            expect.equal(report.diff.removedNights, 5)
            expect.equal(report.verdict, .refused)
            expect.ok(report.causes.contains { $0 == .unexplained })
            expect.contains(report.headline, "back on sale")
        },

        TestCase(group: "Publication safety",
                 name: "1b. an empty first publication is not a reduction") { expect in
            let report = FeedPublicationSafety().assess(
                proposed: feed(decisions: []), lastKnownGood: nil, context: healthyContext()
            )
            expect.equal(report.verdict, .safe)
            expect.ok(report.diff.isFirstPublication)
            expect.ok(!report.diff.wouldEmptyFeed, "nothing was published before")
        },

        // --- 2. Failed imports --------------------------------------------

        TestCase(group: "Publication safety",
                 name: "2. a failed import never shrinks a feed") { expect in
            var context = healthyContext()
            context.recentSyncRuns = [
                SyncRun(listingID: 1, outcome: .failure, errorMessage: "HTTP 503"),
                SyncRun(listingID: 2, outcome: .success),
            ]
            let report = FeedPublicationSafety().assess(
                proposed: feed(decisions: []),
                lastKnownGood: snapshot(entries: [publishedBlock]),
                context: context
            )
            expect.equal(report.verdict, .refused)
            expect.ok(report.causes.contains { if case .importFailure = $0 { return true }; return false })
            expect.contains(report.reasons.joined(separator: " "), "503")
            expect.contains(report.reasons.joined(separator: " "), "last good feed")
        },

        TestCase(group: "Publication safety",
                 name: "2b. a failed import does not block a feed that only grows") { expect in
            var context = healthyContext(decisions: [blockDecision()])
            context.recentSyncRuns = [
                SyncRun(listingID: 1, outcome: .failure, errorMessage: "HTTP 503"),
            ]
            let report = FeedPublicationSafety().assess(
                proposed: feed(decisions: [blockDecision()]),
                lastKnownGood: snapshot(entries: []),
                context: context
            )
            expect.equal(report.verdict, .safe, "adding a block cannot release a booked night")
            expect.ok(!report.causes.isEmpty, "but the problem is still reported")
        },

        // --- 3. Stale source feeds -----------------------------------------

        TestCase(group: "Publication safety",
                 name: "3. a stale inbound calendar refuses any removal") { expect in
            var context = healthyContext()
            context.listings = [
                PlatformListing(id: 1, propertyID: 1, platform: .airbnb, label: "A",
                                lastSyncAt: Date().addingTimeInterval(-30 * 3_600)),
            ]
            let report = FeedPublicationSafety().assess(
                proposed: feed(decisions: []),
                lastKnownGood: snapshot(entries: [publishedBlock]),
                context: context
            )
            expect.equal(report.verdict, .refused)
            expect.ok(report.causes.contains { if case .staleInboundFeed = $0 { return true }; return false })
            expect.contains(report.reasons.joined(separator: " "), "booked night")
        },

        TestCase(group: "Publication safety",
                 name: "3b. a never-imported calendar refuses any removal") { expect in
            var context = healthyContext()
            context.listings = [
                PlatformListing(id: 1, propertyID: 1, platform: .bookingCom, label: "B",
                                lastSyncAt: nil),
            ]
            let report = FeedPublicationSafety().assess(
                proposed: feed(decisions: []),
                lastKnownGood: snapshot(entries: [publishedBlock]),
                context: context
            )
            expect.equal(report.verdict, .refused)
            expect.ok(report.causes.contains { if case .missingInboundFeed = $0 { return true }; return false })
        },

        // --- 9. Intentional reopening after explicit approval ---------------

        TestCase(group: "Publication safety",
                 name: "9. an approved reopen is allowed, but still needs removal approval") { expect in
            let reopen = blockDecision(
                id: 7, uid: "vrc-block-1", status: .approved, action: .unblock
            )
            let report = FeedPublicationSafety().assess(
                proposed: feed(decisions: [reopen]),
                lastKnownGood: snapshot(entries: [publishedBlock]),
                context: healthyContext(decisions: [reopen])
            )
            expect.equal(report.verdict, .requiresRemovalApproval,
                         "explained, but removals are never automatic")
            expect.ok(report.causes.contains { if case .intentionalReopen = $0 { return true }; return false })
            expect.contains(report.headline, "back on sale")

            // Without approval the pipeline stops; with it, it proceeds.
            let hosting = StubHostingClient()
            let pipeline = PublicationPipeline(hosting: hosting)
            let held = await pipeline.publish(
                feed: feed(decisions: [reopen]),
                lastKnownGood: snapshot(entries: [publishedBlock]),
                context: healthyContext(decisions: [reopen]), key: "k"
            )
            expect.equal(held.stage, .awaitingRemovalApproval)

            let proceeded = await pipeline.publish(
                feed: feed(decisions: [reopen]),
                lastKnownGood: snapshot(entries: [publishedBlock]),
                context: healthyContext(decisions: [reopen]), key: "k",
                removalApproved: true
            )
            expect.equal(proceeded.stage, .platformRefreshPending)
            expect.ok(!proceeded.isRemoteSynchronised,
                      "publishing is still not proof the platform applied it")
        },

        // --- Removals are checked against what occupies the nights ----------

        TestCase(group: "Publication safety",
                 name: "4. a removal over an undecided event is called out") { expect in
            let reopen = blockDecision(
                id: 7, uid: "vrc-block-1", status: .approved, action: .unblock
            )
            let undecided = event(
                key: "u1", platform: .airbnb, kind: .unknownUnavailable, needsReview: true,
                from: (2026, 12, 11), to: (2026, 12, 13)
            )
            let report = FeedPublicationSafety().assess(
                proposed: feed(decisions: [reopen]),
                lastKnownGood: snapshot(entries: [publishedBlock]),
                context: healthyContext(decisions: [reopen], sourceEvents: [undecided])
            )
            expect.ok(!report.reservationWarnings.isEmpty)
            expect.contains(report.reservationWarnings.joined(separator: " "), "double booking")
        },

        TestCase(group: "Publication safety",
                 name: "4b. a removal over a confirmed reservation is explained, not hidden") { expect in
            let reopen = blockDecision(
                id: 7, uid: "vrc-block-1", status: .approved, action: .unblock
            )
            let booked = event(
                key: "r1", platform: .airbnb, kind: .confirmedReservation, needsReview: false,
                from: (2026, 12, 11), to: (2026, 12, 14)
            )
            let report = FeedPublicationSafety().assess(
                proposed: feed(decisions: [reopen]),
                lastKnownGood: snapshot(entries: [publishedBlock]),
                context: healthyContext(decisions: [reopen], sourceEvents: [booked])
            )
            expect.contains(report.reservationWarnings.joined(separator: " "),
                            "does not cancel it")
        },

        // --- 4. Failed upload -----------------------------------------------

        TestCase(group: "Publication safety",
                 name: "4c. a failed upload leaves the previous feed serving") { expect in
            let hosting = StubHostingClient(failUpload: "network unreachable")
            let attempt = await PublicationPipeline(hosting: hosting).publish(
                feed: feed(decisions: [blockDecision()]),
                lastKnownGood: snapshot(entries: [], revision: 4),
                context: healthyContext(decisions: [blockDecision()]), key: "k"
            )
            expect.equal(attempt.stage, .failed)
            expect.contains(attempt.detail, "Upload failed")
            expect.equal(attempt.rolledBackTo, 4, "the last good revision is named")
            expect.ok(!attempt.succeeded)
            expect.ok(!attempt.isRemoteSynchronised)
        },

        // --- 5. Failed cache invalidation ------------------------------------

        TestCase(group: "Publication safety",
                 name: "5. a failed cache purge stops at uploaded, not success") { expect in
            let hosting = StubHostingClient(failInvalidation: "purge API returned 500")
            let attempt = await PublicationPipeline(hosting: hosting).publish(
                feed: feed(decisions: [blockDecision()]),
                lastKnownGood: snapshot(entries: []),
                context: healthyContext(decisions: [blockDecision()]), key: "k"
            )
            expect.equal(attempt.stage, .uploaded,
                         "uploaded but not live is its own state")
            expect.ok(!attempt.succeeded, "it must not count as published")
            expect.ok(!attempt.isRemoteSynchronised)
            expect.contains(attempt.detail, "previous feed")
            expect.contains(PublicationStage.uploaded.explanation, "stale availability")
        },

        TestCase(group: "Publication safety",
                 name: "5b. only VERIFIED claims the platform is synchronised") { expect in
            for stage in PublicationStage.allCases {
                expect.equal(
                    stage.impliesRemoteSynchronised, stage == .verified,
                    "\(stage.rawValue) must not imply the platform applied anything"
                )
            }
            expect.contains(PublicationStage.platformRefreshPending.displayName,
                            "awaiting platform confirmation")
        },

        // --- 6. Partial publication across platforms --------------------------

        TestCase(group: "Publication safety",
                 name: "6. one platform failing does not roll back another") { expect in
            let hosting = StubHostingClient()
            let pipeline = PublicationPipeline(hosting: hosting)
            let vrboDecision = blockDecision(id: 1, uid: "vrc-v", destination: .vrbo)
            let bookingDecision = blockDecision(id: 2, uid: "vrc-b", destination: .bookingCom)

            let feeds = [
                feed(destination: .vrbo, decisions: [vrboDecision]),
                feed(destination: .bookingCom, decisions: [bookingDecision]),
            ]
            // Booking.com has a previously published block that would vanish.
            let snapshots: [RentalPlatform: FeedSnapshot] = [
                .bookingCom: snapshot(
                    entries: [SnapshotEntry(uid: "vrc-old", startDay: day(2027, 1, 1),
                                            endDay: day(2027, 1, 5), summary: "Not available")],
                    destination: .bookingCom
                ),
            ]
            let attempts = await pipeline.publishAll(
                feeds: feeds, snapshots: snapshots,
                context: healthyContext(decisions: [vrboDecision, bookingDecision]),
                keys: [.vrbo: "kv", .bookingCom: "kb"]
            )
            expect.equal(attempts.count, 2)
            let vrbo = attempts.first { $0.destination == .vrbo }
            let booking = attempts.first { $0.destination == .bookingCom }
            expect.equal(vrbo?.stage, .platformRefreshPending, "Vrbo proceeds on its own merits")
            expect.equal(booking?.stage, .failed,
                         "Booking.com is refused: it would remove a published block for no "
                             + "explicable reason")
            expect.ok(vrbo?.succeeded == true)
            expect.ok(booking?.succeeded == false)
            expect.equal(booking?.rolledBackTo, 1, "its last good revision stays in place")
            let uploadedVrbo = await hosting.wasInvalidated("kv")
            let uploadedBooking = await hosting.wasInvalidated("kb")
            expect.ok(uploadedVrbo, "Vrbo really was published")
            expect.ok(!uploadedBooking, "Booking.com really was not")
        },

        // --- 7. Token rotation --------------------------------------------------

        TestCase(group: "Publication safety", name: "7. rotating a feed token issues a new key") { expect in
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "39 G Street"))
            let id = property.id!

            let first = try store.feedTokens.rotate(propertyID: id, destination: .vrbo)
            expect.equal(first.version, 1)
            let firstKey = try store.feedTokens.key(propertyID: id, destination: .vrbo)
            expect.ok(firstKey != nil)
            expect.equal(firstKey?.count, 32, "128 bits of hex")

            let second = try store.feedTokens.rotate(propertyID: id, destination: .vrbo)
            expect.equal(second.version, 2)
            let secondKey = try store.feedTokens.key(propertyID: id, destination: .vrbo)
            expect.ok(secondKey != firstKey, "rotation must produce a different key")

            // The old version is retired, and only one is active.
            let current = try store.feedTokens.current(propertyID: id, destination: .vrbo)
            expect.equal(current?.version, 2)
            expect.ok(current?.isActive == true)
        },

        TestCase(group: "Publication safety", name: "7b. no key material reaches the database") { expect in
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "P"))
            let id = property.id!
            _ = try store.feedTokens.rotate(propertyID: id, destination: .vrbo)
            let key = try store.feedTokens.key(propertyID: id, destination: .vrbo) ?? ""
            expect.ok(!key.isEmpty)

            expect.ok(!(try store.feedTokens.databaseContainsAnyKeyMaterial()))
            // Brute check: the secret must not appear anywhere in the table.
            let rows = try store.database.query("SELECT * FROM feed_tokens;")
            for row in rows {
                for value in row.values.values {
                    if case .text(let text) = value {
                        expect.notContains(text, key, "a key must never be stored in SQLite")
                    }
                }
            }
        },

        // --- 8. Recovery from last known good --------------------------------

        TestCase(group: "Publication safety",
                 name: "8. the last known good feed is kept and recoverable") { expect in
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "P"))
            let id = property.id!

            let good = try store.snapshots.record(FeedSnapshot(
                propertyID: id, destination: .vrbo, revision: 1,
                checksum: "c1", entries: [publishedBlock],
                payload: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"
            ))
            try store.snapshots.markLastKnownGood(
                id: good.id!, propertyID: id, destination: .vrbo
            )

            // A later, worse revision is recorded but never marked good.
            _ = try store.snapshots.record(FeedSnapshot(
                propertyID: id, destination: .vrbo, revision: 2,
                checksum: "c2", entries: []
            ))

            let recovered = try store.snapshots.lastKnownGood(propertyID: id, destination: .vrbo)
            expect.equal(recovered?.revision, 1, "recovery returns the good one, not the latest")
            expect.equal(recovered?.entryCount, 1)
            expect.equal(recovered?.coveredNights, 5)
            expect.contains(recovered?.payload ?? "", "BEGIN:VCALENDAR")
            expect.equal(recovered?.entries.first?.uid, publishedBlock.uid,
                         "entries survive the round trip")

            expect.equal(try store.snapshots.history(propertyID: id, destination: .vrbo).count, 2)
        },

        TestCase(group: "Publication safety",
                 name: "8b. a diff names exactly what would change") { expect in
            let diff = FeedDiff.between(
                previous: snapshot(entries: [publishedBlock]),
                proposed: feed(decisions: [
                    blockDecision(id: 2, uid: "vrc-new", from: (2027, 1, 1), to: (2027, 1, 4)),
                ])
            )
            expect.equal(diff.removed.count, 1)
            expect.equal(diff.added.count, 1)
            expect.equal(diff.removedNights, 5)
            expect.equal(diff.addedNights, 3)
            expect.ok(diff.removesPublishedDates)
            let described = diff.describe().joined(separator: "\n")
            expect.contains(described, "REMOVE")
            expect.contains(described, "back on sale")
            expect.contains(described, "ADD")
        },

        // --- The existing seven records are untouched -------------------------

        TestCase(group: "Publication safety",
                 name: "publication safety never writes to imported events") { expect in
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "P"))
            let listing = try store.listings.insert(PlatformListing(
                propertyID: property.id!, platform: .airbnb, label: "A", urlStorage: .database
            ))
            try store.events.upsert(CalendarEvent(
                listingID: listing.id!, eventKey: "k", uid: "k", platform: .airbnb,
                summary: "Airbnb (Not available)",
                checkIn: day(2026, 12, 10), checkOut: day(2026, 12, 15)
            ))
            try store.classifications.save(EventClassification(
                eventKey: "k", kind: .cancellationBlock, confidence: .high,
                source: .manual, needsReview: false
            ))
            let before = try store.events.all(includeTombstoned: true)
                .map { "\($0.eventKey)|\($0.checkIn)|\($0.summary)" }

            _ = FeedPublicationSafety().assess(
                proposed: feed(decisions: []),
                lastKnownGood: snapshot(entries: [publishedBlock]),
                context: healthyContext()
            )
            _ = try store.outbound.generateFeed(propertyID: property.id!, destination: .vrbo)

            let after = try store.events.all(includeTombstoned: true)
                .map { "\($0.eventKey)|\($0.checkIn)|\($0.summary)" }
            expect.equal(after, before)
            expect.equal(
                try store.classifications.find(eventKey: "k")?.kind, .cancellationBlock
            )
        },
    ] }
}
