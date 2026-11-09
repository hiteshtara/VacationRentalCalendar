import Foundation
import VRCCore

public enum FeedGenerationTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

    static func source(
        key: String, platform: RentalPlatform, kind: BlockKind,
        needsReview: Bool = false, uid: String? = nil,
        from: (Int, Int, Int), to: (Int, Int, Int)
    ) -> ClassifiedEvent {
        ClassifiedEvent(
            event: CalendarEvent(
                listingID: 1, eventKey: key, uid: uid ?? key, platform: platform,
                summary: kind == .confirmedReservation ? "Reserved - Dana Pemberton" : "Blocked",
                details: kind == .confirmedReservation
                    ? "Phone Number (Last 4 Digits): 8891" : "",
                checkIn: day(from.0, from.1, from.2), checkOut: day(to.0, to.1, to.2)
            ),
            classification: EventClassification(
                eventKey: key, kind: kind, confidence: .high,
                source: needsReview ? .automatic : .manual, needsReview: needsReview,
                exportApproved: kind != .confirmedReservation
            ),
            listingLabel: "\(platform.displayName)", propertyID: 1, propertyName: "39 G Street"
        )
    }

    static func decision(
        _ destination: RentalPlatform, _ action: AvailabilityAction,
        status: AvailabilityStatus, from: (Int, Int, Int), to: (Int, Int, Int),
        id: Int64 = 1
    ) -> AvailabilityDecision {
        AvailabilityDecision(
            id: id, propertyID: 1, destination: destination, action: action,
            startDay: day(from.0, from.1, from.2), endDay: day(to.0, to.1, to.2),
            status: status, approvedAt: Date()
        )
    }

    static func generate(
        to destination: RentalPlatform,
        events: [ClassifiedEvent] = [],
        decisions: [AvailabilityDecision] = []
    ) -> DestinationFeed {
        CalendarFeedGenerator().generate(
            destination: destination, propertyID: 1, propertyName: "39 G Street",
            sourceEvents: events, decisions: decisions
        )
    }

    public static var cases: [TestCase] { [

        TestCase(group: "Feeds", name: "a destination never receives its own events") { expect in
            let feed = generate(to: .vrbo, events: [
                source(key: "v1", platform: .vrbo, kind: .confirmedReservation,
                       from: (2027, 3, 10), to: (2027, 3, 14)),
                source(key: "a1", platform: .airbnb, kind: .confirmedReservation,
                       from: (2027, 4, 1), to: (2027, 4, 5)),
            ])
            expect.equal(feed.included.count, 1)
            expect.equal(feed.included.first?.platform, .airbnb)
            let ownBack = feed.excluded.first { $0.platform == .vrbo }
            expect.contains(ownBack?.reason ?? "", "Vrbo")
        },

        TestCase(group: "Feeds", name: "unreviewed and unknown source events are excluded") { expect in
            let feed = generate(to: .vrbo, events: [
                source(key: "u1", platform: .airbnb, kind: .unknownUnavailable,
                       needsReview: true, from: (2027, 3, 1), to: (2027, 3, 5)),
                source(key: "u2", platform: .airbnb, kind: .unknownUnavailable,
                       needsReview: false, from: (2027, 4, 1), to: (2027, 4, 5)),
            ])
            expect.equal(feed.included.count, 0)
            expect.equal(feed.excluded.count, 2)
        },

        TestCase(group: "Feeds", name: "a cancellation block never reaches another platform") { expect in
            for destination in [RentalPlatform.vrbo, .bookingCom] {
                let feed = generate(to: destination, events: [
                    source(key: "c1", platform: .airbnb, kind: .cancellationBlock,
                           from: (2027, 4, 17), to: (2027, 4, 20)),
                ])
                expect.equal(feed.included.count, 0, "\(destination.displayName)")
                expect.contains(feed.excluded.first?.reason ?? "", "never exported")
                let ics = CalendarFeedGenerator().makeICS(feed)
                expect.notContains(ics, "20270417", "the dates must not appear at all")
            }
        },

        TestCase(group: "Feeds", name: "an approved block is published, an unapproved one is not") { expect in
            let approved = generate(to: .vrbo, decisions: [
                decision(.vrbo, .block, status: .approved, from: (2026, 12, 10), to: (2026, 12, 15)),
            ])
            expect.equal(approved.included.count, 1)
            expect.equal(approved.includedNights, 5)

            for status in [AvailabilityStatus.draft, .validated, .awaitingApproval, .cancelled,
                           .failed, .unknown] {
                let feed = generate(to: .vrbo, decisions: [
                    decision(.vrbo, .block, status: status,
                             from: (2026, 12, 10), to: (2026, 12, 15)),
                ])
                expect.equal(feed.included.count, 0, "status \(status.rawValue) must not publish")
            }
        },

        TestCase(group: "Feeds", name: "a block for one destination stays out of another's feed") { expect in
            let decisions = [
                decision(.vrbo, .block, status: .approved,
                         from: (2026, 12, 10), to: (2026, 12, 15), id: 1),
            ]
            let vrbo = generate(to: .vrbo, decisions: decisions)
            let airbnb = generate(to: .airbnb, decisions: decisions)
            expect.equal(vrbo.included.count, 1)
            expect.equal(airbnb.included.count, 0, "a Vrbo decision must not affect Airbnb")
        },

        TestCase(group: "Feeds", name: "reopening removes our entry rather than adding one") { expect in
            let feed = generate(to: .vrbo, decisions: [
                decision(.vrbo, .unblock, status: .approved,
                         from: (2026, 12, 10), to: (2026, 12, 15)),
            ])
            expect.equal(feed.included.count, 0, "a reopen publishes nothing")
            expect.contains(feed.excluded.first?.reason ?? "", "withdrawn")
            expect.contains(feed.excluded.first?.reason ?? "", "blocks this app created")
        },

        TestCase(group: "Feeds", name: "our own entries coming back are never republished") { expect in
            // The loop that would otherwise make a block immortal: the owner
            // subscribes Airbnb to our feed, Airbnb's export then contains our
            // block, and we read it back as a source event.
            let generator = CalendarFeedGenerator()
            let ourUID = generator.stableUID(forSourceKey: "original", destination: .airbnb)
            let feed = generate(to: .vrbo, events: [
                source(key: "echo", platform: .airbnb, kind: .ownerBlock,
                       uid: ourUID, from: (2026, 12, 10), to: (2026, 12, 15)),
            ])
            expect.equal(feed.included.count, 0)
            expect.contains(feed.excluded.first?.reason ?? "", "loop")
        },

        TestCase(group: "Feeds", name: "entry identifiers are stable and per destination") { expect in
            let generator = CalendarFeedGenerator()
            let a1 = generator.stableUID(forSourceKey: "evt", destination: .vrbo)
            let a2 = generator.stableUID(forSourceKey: "evt", destination: .vrbo)
            let b = generator.stableUID(forSourceKey: "evt", destination: .bookingCom)
            expect.equal(a1, a2, "regenerating must not look like a new event")
            expect.ok(a1 != b, "two destinations must not be able to correlate feeds")
            expect.notContains(a1, "evt", "the source key must not be exposed")
        },

        TestCase(group: "Feeds", name: "no guest data reaches a generated feed") { expect in
            let feed = generate(to: .vrbo, events: [
                source(key: "r1", platform: .airbnb, kind: .confirmedReservation,
                       from: (2027, 3, 10), to: (2027, 3, 15)),
            ])
            let ics = CalendarFeedGenerator().makeICS(feed)
            expect.equal(feed.included.count, 1)
            expect.contains(ics, "SUMMARY:Reserved")
            expect.notContains(ics, "Pemberton")
            expect.notContains(ics, "8891")
            expect.notContains(ics, "r1")
        },

        TestCase(group: "Feeds", name: "a generated feed re-parses as valid iCalendar") { expect in
            let feed = generate(to: .vrbo, decisions: [
                decision(.vrbo, .block, status: .approved, from: (2026, 12, 10), to: (2026, 12, 15)),
            ])
            let ics = CalendarFeedGenerator().makeICS(feed)
            let parsed = try ICalParser.parse(ics)
            expect.equal(parsed.events.count, 1)
            expect.equal(parsed.events.first?.resolvedCheckIn, day(2026, 12, 10))
            expect.equal(parsed.events.first?.resolvedCheckOut, day(2026, 12, 15),
                         "checkout-exclusive survives the round trip")
        },

        TestCase(group: "Feeds", name: "the audit names every inclusion and exclusion") { expect in
            let generator = CalendarFeedGenerator()
            let feed = generate(to: .vrbo, events: [
                source(key: "c1", platform: .airbnb, kind: .cancellationBlock,
                       from: (2027, 4, 17), to: (2027, 4, 20)),
            ], decisions: [
                decision(.vrbo, .block, status: .approved, from: (2026, 12, 10), to: (2026, 12, 15)),
            ])
            let audit = generator.auditText(feed)
            expect.contains(audit, "INCLUDED")
            expect.contains(audit, "HELD BACK")
            expect.contains(audit, "your block")
            expect.contains(audit, "never exported")
        },

        // --- Publication bookkeeping and the gate --------------------------

        TestCase(group: "Feeds", name: "generating records a publication and its entries") { expect in
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "39 G Street"))
            let id = property.id!
            _ = try store.availability.insert(AvailabilityDecision(
                propertyID: id, destination: .vrbo, action: .block,
                startDay: day(2026, 12, 10), endDay: day(2026, 12, 15),
                status: .approved, approvedAt: Date()
            ))
            let feed = try store.outbound.generateFeed(propertyID: id, destination: .vrbo)
            expect.equal(feed.included.count, 1)
            expect.equal(feed.revision, 1)

            _ = try store.outbound.recordGeneration(feed)
            let publications = try store.database.scalarInt(
                "SELECT COUNT(*) FROM feed_publications;"
            )
            let entries = try store.database.scalarInt(
                "SELECT COUNT(*) FROM published_feed_entries;"
            )
            expect.equal(publications, 1)
            expect.equal(entries, 1)

            // Revisions increment so a regenerated feed is traceable.
            let again = try store.outbound.generateFeed(propertyID: id, destination: .vrbo)
            expect.equal(again.revision, 2)
        },

        TestCase(group: "Feeds", name: "publishing is refused while the gate is shut") { expect in
            expect.ok(!OutboundSyncGate.isEnabled, "this build must not publish")
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "P"))
            do {
                _ = try store.outbound.publish(propertyID: property.id!, destination: .vrbo)
                expect.fail("publish must refuse")
            } catch let error as AvailabilityError {
                if case .outboundDisabled = error {} else { expect.fail("wrong error") }
            }
        },

        TestCase(group: "Feeds", name: "sync status never claims a platform has synchronised") { expect in
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "P"))
            let id = property.id!
            _ = try store.availability.insert(AvailabilityDecision(
                propertyID: id, destination: .vrbo, action: .block,
                startDay: day(2026, 12, 10), endDay: day(2026, 12, 15),
                status: .published, publishedAt: Date()
            ))
            let states = try store.outbound.allStates(propertyID: id)
            let vrbo = states.first { $0.destination == .vrbo }
            expect.ok(vrbo != nil)
            expect.notContains(vrbo?.headline ?? "", "Confirmed")
            expect.contains(AvailabilityStatus.published.displayName, "awaiting platform")
        },

        // --- Verification ----------------------------------------------------

        TestCase(group: "Feeds", name: "verification needs the destination's own evidence") { expect in
            let verifier = SyncVerifier()
            var published = decision(.vrbo, .block, status: .published,
                                     from: (2026, 12, 10), to: (2026, 12, 15))
            published.publishedAt = Date().addingTimeInterval(-24 * 3_600)

            // Nothing on Vrbo yet.
            let absent = verifier.check(
                decision: published, destinationEvents: [],
                strategy: VrboAdapter().verificationStrategy()
            )
            expect.equal(absent.outcome, .nightsStillOpen)
            expect.ok(!absent.supportsVerified)

            // Vrbo now shows the nights blocked.
            let present = verifier.check(
                decision: published,
                destinationEvents: [
                    source(key: "v", platform: .vrbo, kind: .ownerBlock,
                           from: (2026, 12, 10), to: (2026, 12, 15)),
                ],
                strategy: VrboAdapter().verificationStrategy()
            )
            expect.equal(present.outcome, .nightsAppearBlocked)
            expect.ok(present.supportsVerified)
        },

        TestCase(group: "Feeds", name: "partial coverage is not confirmation") { expect in
            var published = decision(.vrbo, .block, status: .published,
                                     from: (2026, 12, 10), to: (2026, 12, 15))
            published.publishedAt = Date().addingTimeInterval(-24 * 3_600)
            let evidence = SyncVerifier().check(
                decision: published,
                destinationEvents: [
                    source(key: "v", platform: .vrbo, kind: .ownerBlock,
                           from: (2026, 12, 10), to: (2026, 12, 12)),
                ],
                strategy: VrboAdapter().verificationStrategy()
            )
            expect.ok(!evidence.supportsVerified, "three of five nights is not confirmation")
        },

        TestCase(group: "Feeds", name: "Booking.com evidence is never conclusive") { expect in
            var published = decision(.bookingCom, .block, status: .published,
                                     from: (2026, 12, 10), to: (2026, 12, 15))
            published.publishedAt = Date().addingTimeInterval(-24 * 3_600)
            let evidence = SyncVerifier().check(
                decision: published,
                destinationEvents: [
                    source(key: "b", platform: .bookingCom, kind: .ownerBlock,
                           from: (2026, 12, 10), to: (2026, 12, 15)),
                ],
                strategy: BookingComAdapter().verificationStrategy()
            )
            expect.equal(evidence.outcome, .nightsAppearBlocked)
            expect.ok(!evidence.isConclusive, "its export cannot prove our feed caused it")
            expect.ok(!evidence.supportsVerified)
        },

        TestCase(group: "Feeds", name: "no adapter claims a write API") { expect in
            for adapter in PlatformAdapters.all {
                expect.ok(!adapter.capability.providesWriteAPI,
                          "\(adapter.platform.displayName) has no host-facing write API")
                expect.ok(adapter.capability.acceptsImportedCalendar,
                          "\(adapter.platform.displayName) must at least accept an iCal import")
                expect.ok(!adapter.importInstructions.isEmpty)
            }
        },
    ] }
}
