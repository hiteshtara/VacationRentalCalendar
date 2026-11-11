import Foundation
import VRCCore

public enum ClassificationSafeguardTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

    static func store(
        events: [(RentalPlatform, BlockKind, ClassificationSource, Bool, (Int, Int, Int), (Int, Int, Int))]
    ) throws -> (store: RentalStore, propertyID: Int64) {
        let store = try RentalStore.makeInMemory()
        let property = try store.properties.insert(Property(name: "39 G Street"))
        let propertyID = property.id!
        var listingIDs: [RentalPlatform: Int64] = [:]
        for platform in [RentalPlatform.airbnb, .vrbo, .bookingCom] {
            let listing = try store.listings.insert(PlatformListing(
                propertyID: propertyID, platform: platform,
                label: platform.displayName, urlStorage: .database
            ))
            listingIDs[platform] = listing.id
        }
        for (index, spec) in events.enumerated() {
            let (platform, kind, source, needsReview, from, to) = spec
            let key = "evt-\(index)"
            try store.events.upsert(CalendarEvent(
                listingID: listingIDs[platform]!, eventKey: key, uid: key, platform: platform,
                summary: "Blocked",
                checkIn: day(from.0, from.1, from.2), checkOut: day(to.0, to.1, to.2)
            ))
            try store.classifications.save(EventClassification(
                eventKey: key, kind: kind, confidence: .high, source: source,
                needsReview: needsReview, note: "owner note \(index)"
            ))
        }
        return (store, propertyID)
    }

    public static var cases: [TestCase] { [

        // --- 1. The new classification ------------------------------------

        TestCase(group: "Classification safeguards",
                 name: "a booking-window restriction is never exportable") { expect in
            let policy = ExportPolicy()
            let event = CalendarEvent(
                listingID: 1, eventKey: "k", uid: "k", platform: .airbnb,
                summary: "Airbnb (Not available)",
                checkIn: day(2027, 5, 1), checkOut: day(2027, 11, 10)
            )
            // Every combination that might sneak one through.
            for source in ClassificationSource.allCases {
                for approved in [true, false] {
                    let classification = EventClassification(
                        eventKey: "k", kind: .platformRestriction, confidence: .high,
                        source: source, needsReview: false, exportApproved: approved
                    )
                    for destination in [RentalPlatform.vrbo, .bookingCom] {
                        let decision = policy.decide(
                            event: event, classification: classification, destination: destination
                        )
                        expect.ok(!decision.isIncluded,
                                  "\(source.rawValue)/approved=\(approved) must not export")
                    }
                }
            }
            expect.ok(!BlockKind.platformRestriction.describesGenuineUnavailability,
                      "a platform's own limit is not the property's unavailability")
        },

        TestCase(group: "Classification safeguards",
                 name: "the new kind has its own display status and wording") { expect in
            let classification = EventClassification(
                eventKey: "k", kind: .platformRestriction, confidence: .high,
                source: .manual, needsReview: false
            )
            expect.equal(EventDisplayStatus.status(for: classification), .platformRestriction)
            expect.equal(EventDisplayStatus.platformRestriction.label, "Booking window")
            expect.ok(EventDisplayStatus.platformRestriction.isSellableElsewhere,
                      "it must draw hollow — the nights stay sellable")
            expect.equal(
                EventDisplayStatus.platformRestriction.correspondingKind, .platformRestriction
            )
            expect.contains(BlockKind.platformRestriction.displayName, "Booking window")
        },

        TestCase(group: "Classification safeguards",
                 name: "the classifier proposes it for a long horizon, still reviewed") { expect in
            let feed = Fixtures.calendar("-//Airbnb Inc//Hosting Calendar 1.0//EN", """
                BEGIN:VEVENT
                UID:horizon@airbnb.com
                DTSTART;VALUE=DATE:20270501
                DTEND;VALUE=DATE:20271110
                SUMMARY:Airbnb (Not available)
                END:VEVENT
                """)
            let event = try ICalParser.parse(feed).events[0]
            let proposal = BlockClassifier().classify(
                event: event, platform: .airbnb, nights: 193
            )
            expect.equal(proposal.kind, .platformRestriction)
            expect.ok(proposal.needsReview, "named, but still the owner's call")
            expect.contains(proposal.rationale, "booking window")
        },

        // --- 4. Vrbo must not be described as an Airbnb penalty -------------

        TestCase(group: "Classification safeguards",
                 name: "a Vrbo cancellation block is not called an Airbnb penalty") { expect in
            let vrbo = BlockKind.cancellationBlock.guidance(for: .vrbo)
            expect.notContains(vrbo, "Airbnb took", "wrong platform named")
            expect.contains(vrbo, "Vrbo")
            expect.contains(vrbo, "Airbnb", "Airbnb may still appear as a destination")

            let airbnb = BlockKind.cancellationBlock.guidance(for: .airbnb)
            expect.contains(airbnb, "Airbnb took")
            expect.notContains(airbnb, "stay on sale on Airbnb",
                               "a platform is never listed among its own alternatives")

            let booking = BlockKind.cancellationBlock.guidance(for: .bookingCom)
            expect.contains(booking, "Booking.com made")
        },

        TestCase(group: "Classification safeguards",
                 name: "display consequences name the right platform too") { expect in
            let vrbo = EventDisplayStatus.cancellationBlock.consequence(for: .vrbo)
            expect.contains(vrbo, "Vrbo took")
            expect.notContains(vrbo, "Airbnb took")

            let restriction = EventDisplayStatus.platformRestriction.consequence(for: .vrbo)
            expect.contains(restriction, "Vrbo will not take bookings")
        },

        TestCase(group: "Classification safeguards",
                 name: "a platform is never listed among its own alternatives") { expect in
            for platform in [RentalPlatform.airbnb, .vrbo, .bookingCom] {
                let others = BlockKind.otherPlatforms(excluding: platform)
                expect.notContains(others, platform.displayName,
                                   "\(platform.displayName) must not be its own alternative")
            }
        },

        // --- 2 and 3. Flag long periods, never reclassify -------------------

        TestCase(group: "Classification safeguards",
                 name: "long periods are flagged for review without being reclassified") { expect in
            let setup = try store(events: [
                // The two long ones, mirroring the real data.
                (.vrbo, .cancellationBlock, .manual, false, (2027, 4, 1), (2029, 1, 1)),
                (.airbnb, .cancellationBlock, .manual, false, (2027, 5, 1), (2027, 11, 10)),
                // And a short one that must be left entirely alone.
                (.airbnb, .cancellationBlock, .manual, false, (2026, 12, 17), (2026, 12, 19)),
            ])

            let flagged = try LongPeriodReview.flagLongPeriods(in: setup.store)
            expect.equal(flagged.count, 2, "only the long ones")
            expect.equal(Set(flagged.map(\.nights)), Set([641, 193]))

            let all = try setup.store.classifiedEvents()
            for item in all {
                // The decision itself is untouched in every case.
                expect.equal(item.classification.kind, .cancellationBlock,
                             "kind must not change")
                expect.equal(item.classification.source, .manual, "still the owner's decision")
                expect.contains(item.classification.note, "owner note", "the note survives")

                if item.event.nights >= 90 {
                    expect.ok(item.classification.needsReview, "long ones come back for review")
                    expect.contains(item.classification.rationale, "booking window")
                } else {
                    expect.ok(!item.classification.needsReview,
                              "the short one is left alone entirely")
                }
            }
        },

        TestCase(group: "Classification safeguards",
                 name: "the long-period sweep runs once, so a cleared flag stays cleared") { expect in
            let setup = try store(events: [
                (.vrbo, .cancellationBlock, .manual, false, (2027, 4, 1), (2029, 1, 1)),
            ])
            expect.equal(try LongPeriodReview.runOnce(in: setup.store).count, 1)

            // The owner looks at it and confirms their original decision.
            let key = try setup.store.classifiedEvents()[0].event.eventKey
            try setup.store.classifyManually(eventKey: key, kind: .cancellationBlock)
            expect.ok(try setup.store.classifications.find(eventKey: key)?.needsReview == false)

            // A later launch must not drag it back.
            expect.equal(try LongPeriodReview.runOnce(in: setup.store).count, 0)
            expect.ok(try setup.store.classifications.find(eventKey: key)?.needsReview == false,
                      "a decision the owner reconfirmed stays settled")
        },

        TestCase(group: "Classification safeguards",
                 name: "nothing reclassifies the owner's existing decisions") { expect in
            // The real shape of this owner's data: seven manual cancellation
            // blocks. Re-importing, sweeping and generating feeds must leave
            // every one of them exactly as it is.
            let setup = try store(events: [
                (.vrbo, .cancellationBlock, .manual, false, (2026, 11, 1), (2026, 11, 2)),
                (.vrbo, .cancellationBlock, .manual, false, (2026, 11, 1), (2026, 11, 30)),
                (.airbnb, .cancellationBlock, .manual, false, (2026, 11, 7), (2026, 11, 15)),
                (.airbnb, .cancellationBlock, .manual, false, (2026, 12, 17), (2026, 12, 19)),
                (.vrbo, .cancellationBlock, .manual, false, (2027, 4, 1), (2029, 1, 1)),
                (.airbnb, .cancellationBlock, .manual, false, (2027, 4, 17), (2027, 4, 20)),
                (.airbnb, .cancellationBlock, .manual, false, (2027, 5, 1), (2027, 11, 10)),
            ])
            let before = try setup.store.classifications.all()
            expect.equal(before.count, 7)

            _ = try LongPeriodReview.runOnce(in: setup.store)
            _ = try setup.store.outbound.generateFeed(
                propertyID: setup.propertyID, destination: .vrbo
            )
            _ = try setup.store.outbound.generateFeed(
                propertyID: setup.propertyID, destination: .bookingCom
            )

            let after = try setup.store.classifications.all()
            expect.equal(after.count, 7)
            for (key, original) in before {
                guard let updated = after[key] else {
                    expect.fail("classification \(key) disappeared")
                    continue
                }
                expect.equal(updated.kind, original.kind, "kind unchanged")
                expect.equal(updated.source, original.source, "still manual")
                expect.equal(updated.note, original.note, "note unchanged")
            }
            // And none of them can ever be exported.
            let feed = try setup.store.outbound.generateFeed(
                propertyID: setup.propertyID, destination: .vrbo
            )
            expect.equal(feed.included.count, 0)
        },

        // --- 5. Additions require approval ----------------------------------

        TestCase(group: "Classification safeguards",
                 name: "adding blocked dates needs approval, not just removing them") { expect in
            let decision = AvailabilityDecision(
                id: 1, propertyID: 1, destination: .vrbo, action: .block,
                startDay: day(2026, 12, 10), endDay: day(2026, 12, 15),
                status: .approved, publicationUID: "vrc-add", approvedAt: Date()
            )
            let feed = CalendarFeedGenerator().generate(
                destination: .vrbo, propertyID: 1, propertyName: "P",
                sourceEvents: [], decisions: [decision]
            )
            let context = PublicationContext(
                listings: [PlatformListing(id: 1, propertyID: 1, platform: .vrbo, label: "V",
                                           lastSyncAt: Date())],
                recentSyncRuns: [SyncRun(listingID: 1, outcome: .success)],
                decisions: [decision], sourceEvents: []
            )
            let report = FeedPublicationSafety().assess(
                proposed: feed,
                lastKnownGood: FeedSnapshot(
                    propertyID: 1, destination: .vrbo, revision: 1, entries: []
                ),
                context: context
            )
            expect.equal(report.verdict, .requiresAdditionApproval)
            expect.ok(report.verdict.needsApproval)
            expect.contains(report.headline, "off sale")

            // The pipeline holds it until approved.
            let hosting = StubHostingClient()
            let pipeline = PublicationPipeline(hosting: hosting)
            let held = await pipeline.publish(
                feed: feed,
                lastKnownGood: FeedSnapshot(propertyID: 1, destination: .vrbo,
                                            revision: 1, entries: []),
                context: context, key: "k"
            )
            expect.equal(held.stage, .awaitingAdditionApproval)
            expect.ok(!held.succeeded)
            let uploadedWithoutApproval = await hosting.wasInvalidated("k")
            expect.ok(!uploadedWithoutApproval, "nothing may be served without approval")

            let approved = await pipeline.publish(
                feed: feed,
                lastKnownGood: FeedSnapshot(propertyID: 1, destination: .vrbo,
                                            revision: 1, entries: []),
                context: context, key: "k", changeApproved: true
            )
            expect.equal(approved.stage, .platformRefreshPending)
        },

        TestCase(group: "Classification safeguards",
                 name: "an unchanged feed needs no approval at all") { expect in
            let feed = CalendarFeedGenerator().generate(
                destination: .vrbo, propertyID: 1, propertyName: "P",
                sourceEvents: [], decisions: []
            )
            let report = FeedPublicationSafety().assess(
                proposed: feed,
                lastKnownGood: FeedSnapshot(propertyID: 1, destination: .vrbo,
                                            revision: 1, entries: []),
                context: PublicationContext(
                    listings: [], recentSyncRuns: [], decisions: [], sourceEvents: []
                )
            )
            expect.equal(report.verdict, .noChange)
            expect.ok(!report.verdict.needsApproval)
        },

        // --- 6. The safeguards are still in place ---------------------------

        TestCase(group: "Classification safeguards",
                 name: "last-known-good and the outbound gate are untouched") { expect in
            expect.ok(!OutboundSyncGate.isEnabled)
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "P"))
            let snapshot = try store.snapshots.record(FeedSnapshot(
                propertyID: property.id!, destination: .vrbo, revision: 1,
                checksum: "c", entries: [
                    SnapshotEntry(uid: "u", startDay: day(2026, 12, 10),
                                  endDay: day(2026, 12, 15), summary: "Not available"),
                ]
            ))
            try store.snapshots.markLastKnownGood(
                id: snapshot.id!, propertyID: property.id!, destination: .vrbo
            )
            let recovered = try store.snapshots.lastKnownGood(
                propertyID: property.id!, destination: .vrbo
            )
            expect.equal(recovered?.entryCount, 1)
            expect.equal(recovered?.coveredNights, 5)
        },
    ] }
}
