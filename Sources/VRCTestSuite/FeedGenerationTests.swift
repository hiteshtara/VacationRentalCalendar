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

        // --- A simulated Booking.com subscriber ----------------------------
        //
        // Everything here is synthetic and in-memory. No live Booking.com
        // decision is created: the owner's instruction is explicit that the
        // generator must not be tested by approving real availability.

        TestCase(group: "Feeds",
                 name: "Booking.com receives ONLY what was approved for Booking.com") { expect in
            let feed = CalendarFeedGenerator().generate(
                destination: .bookingCom, propertyID: 1, propertyName: "39 G Street",
                sourceEvents: [
                    // Must never travel: an Airbnb cancellation penalty.
                    source(key: "cancel", platform: .airbnb, kind: .cancellationBlock,
                           from: (2028, 5, 1), to: (2028, 5, 8)),
                    // Must never travel: an opaque, unclassified block.
                    source(key: "unknown", platform: .airbnb, kind: .unknownUnavailable,
                           needsReview: true, from: (2028, 6, 1), to: (2028, 6, 4)),
                    // Must never travel back out: one of our own published blocks
                    // returning through a platform's export.
                    source(key: "ours", platform: .bookingCom, kind: .ownerBlock,
                           uid: "vrc-deadbeef", from: (2028, 7, 1), to: (2028, 7, 5)),
                ],
                decisions: [
                    // Approved for Booking.com — the only thing that may appear.
                    decision(.bookingCom, .block, status: .approved,
                             from: (2028, 9, 1), to: (2028, 9, 5), id: 1),
                    // Approved, but for VRBO. A Vrbo approval is not a
                    // Booking.com approval and must not leak across.
                    decision(.vrbo, .block, status: .approved,
                             from: (2028, 10, 1), to: (2028, 10, 5), id: 2),
                    // Booking.com, but never approved.
                    decision(.bookingCom, .block, status: .draft,
                             from: (2028, 11, 1), to: (2028, 11, 5), id: 3),
                ],
                scope: .approvedManualBlocksOnly
            )

            expect.equal(feed.included.count, 1, "exactly one entry may be published")
            expect.equal(feed.included.first?.decisionID, 1, "and it is the Booking.com approval")

            let ics = CalendarFeedGenerator().makeICS(feed)
            expect.equal(ics.components(separatedBy: "BEGIN:VEVENT").count - 1, 1,
                         "one VEVENT in the served calendar")
            // Checkout-exclusive: DTEND is the checkout day itself, so the last
            // night sold is the 4th. Off by one here double-books or loses a night.
            expect.contains(ics, "DTSTART;VALUE=DATE:20280901")
            expect.contains(ics, "DTEND;VALUE=DATE:20280905")
            for absent in ["20280501", "20280601", "20280701", "20281001", "20281101"] {
                expect.notContains(ics, absent)
            }
            expect.notContains(ics, "Dana Pemberton")
            expect.notContains(ics, "8891")
            expect.notContains(ics, "ATTENDEE")

            // The fixture the local HTTP subscriber test serves. Written from the
            // generator itself so the consumer check exercises real output rather
            // than a hand-written approximation.
            let fixture = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("vrc-booking-fixture.ics")
            try? ics.write(to: fixture, atomically: true, encoding: .utf8)
        },

        TestCase(group: "Feeds",
                 name: "a Booking.com block keeps its UID across regeneration") { expect in
            // Booking.com must see an update, not a delete plus a create. A
            // changed UID is what makes it see the latter.
            //
            // Note where the guarantee actually comes from: `publicationUID`
            // defaults to a NEWLY generated value for each AvailabilityDecision
            // object, so stability is a property of the decision being STORED
            // and re-read, not of the generator. Building a fresh decision each
            // time would produce a new UID and the test would be asserting
            // nothing — which is exactly what the first draft of it did. Hence
            // one decision, reused. CLAUDE.md makes the same point from the
            // other direction: publication UIDs are migrated verbatim, never
            // regenerated.
            let stored = decision(.bookingCom, .block, status: .approved,
                                  from: (2028, 9, 1), to: (2028, 9, 5), id: 1)
            func build() -> String {
                CalendarFeedGenerator().makeICS(CalendarFeedGenerator().generate(
                    destination: .bookingCom, propertyID: 1, propertyName: "39 G Street",
                    sourceEvents: [], decisions: [stored],
                    scope: .approvedManualBlocksOnly))
            }
            func uids(_ ics: String) -> [String] {
                ics.split(separator: "\r\n").map(String.init).filter { $0.hasPrefix("UID:") }
            }
            let first = uids(build())
            expect.equal(first.count, 1)
            expect.equal(uids(build()), first,
                         "the stored decision yields the same UID every time")
            // And a DIFFERENT decision must not collide with it.
            let other = decision(.bookingCom, .block, status: .approved,
                                 from: (2028, 9, 1), to: (2028, 9, 5), id: 2)
            expect.ok(other.publicationUID != stored.publicationUID,
                      "two decisions never share a publication UID")
        },

        TestCase(group: "Feeds",
                 name: "an empty Booking.com feed is still a valid calendar") { expect in
            // The state this project will actually start in, and the one most
            // likely to be mishandled: nothing approved yet.
            let feed = CalendarFeedGenerator().generate(
                destination: .bookingCom, propertyID: 1, propertyName: "39 G Street",
                sourceEvents: [
                    source(key: "cancel", platform: .airbnb, kind: .cancellationBlock,
                           from: (2028, 5, 1), to: (2028, 5, 8)),
                ],
                decisions: [],
                scope: .approvedManualBlocksOnly)
            expect.equal(feed.included.count, 0)
            let ics = CalendarFeedGenerator().makeICS(feed)
            expect.contains(ics, "BEGIN:VCALENDAR")
            expect.contains(ics, "END:VCALENDAR")
            expect.notContains(ics, "BEGIN:VEVENT")
            // An empty calendar is a statement that nothing is blocked — it is
            // NOT a signal to reopen. That distinction lives in
            // FeedPublicationSafety, which refuses an unexplained shrink.
        },
    ] }
}
