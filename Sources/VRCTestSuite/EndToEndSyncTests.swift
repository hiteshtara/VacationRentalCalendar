import Foundation
import VRCCore

/// The whole path, with nothing live in it.
///
///   source import → classification → outbound decision → ICS publication
///   → destination import → verification
///
/// Every property, feed and reservation here is synthetic. The point is not
/// that each component works — they have their own tests — but that the
/// seam between them holds: that what the policy decides is what the writer
/// emits, that what the writer emits is what a destination would import, and
/// that importing it back is what the verifier recognises as ours.
public enum EndToEndSyncTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }
    static let property: Int64 = 99
    static let now = DayMath.day(2026, 11, 11)

    /// `approved` matters for blocks: `ExportPolicy` only exports an owner or
    /// maintenance block the owner classified AND approved for export. That is
    /// the "approved owner blocks" requirement, and it is a second gate beyond
    /// the per-destination policy.
    static func source(
        _ platform: RentalPlatform, _ kind: BlockKind,
        _ ci: Date, _ co: Date, needsReview: Bool = false,
        summary: String = "synthetic", approved: Bool = true
    ) -> ClassifiedEvent {
        let key = "e2e-\(platform.rawValue)-\(kind.rawValue)-\(Int(ci.timeIntervalSince1970))"
        return ClassifiedEvent(
            event: CalendarEvent(
                listingID: 1, eventKey: key, uid: "src-\(key)@example.invalid",
                platform: platform, summary: summary, details: "",
                checkIn: ci, checkOut: co),
            classification: EventClassification(
                eventKey: key, kind: kind,
                confidence: needsReview ? .low : .high,
                source: needsReview ? .automatic : .manual,
                needsReview: needsReview,
                exportApproved: approved),
            listingLabel: platform.displayName,
            propertyID: property, propertyName: "Synthetic Cottage")
    }

    static func freshFeed(_ p: RentalPlatform) -> FeedFreshness {
        FeedFreshness(platform: p, lastSuccess: now.addingTimeInterval(-300),
                      lastOutcome: .success)
    }

    /// Publishes, then imports the published calendar back the way a
    /// destination platform would — parsing our own ICS rather than trusting
    /// the objects we started with. This is the seam that matters.
    static func roundTrip(
        events: [ClassifiedEvent], destination: RentalPlatform, policy: OutboundPolicy
    ) -> (feed: DestinationFeedBuilder.Feed, imported: [ClassifiedEvent]) {
        let feed = DestinationFeedBuilder.build(
            propertyID: property, propertyName: "Synthetic Cottage",
            events: events, destination: destination, policy: policy, now: now)

        // The destination fetches the ICS and parses it — the real parser on
        // the real bytes, not the objects we started from.
        let parsed = (try? ICalParser.parse(feed.ics)) ?? ICalParseResult()
        let imported = parsed.events.compactMap { event -> ClassifiedEvent? in
            guard let start = event.dtStart?.date, let end = event.dtEnd?.date else { return nil }
            return ClassifiedEvent(
                event: CalendarEvent(
                    listingID: 2, eventKey: "dest-\(event.uid)", uid: event.uid,
                    platform: destination,
                    summary: event.summary, details: event.description,
                    checkIn: start, checkOut: end),
                classification: EventClassification(
                    eventKey: "dest-\(event.uid)", kind: .ownerBlock,
                    confidence: .high, source: .automatic, needsReview: false),
                listingLabel: destination.displayName,
                propertyID: property, propertyName: "Synthetic Cottage")
        }
        return (feed, imported)
    }

    static func verify(
        _ reservation: ClassifiedEvent, at destination: RentalPlatform,
        imported: [ClassifiedEvent], policy: OutboundPolicy
    ) -> DeliveryAssessment {
        DeliveryAssessment.assess(
            item: reservation, destination: destination, policy: policy,
            observedAtDestination: imported,
            publishedUID: DestinationFeedBuilder.publicationUID(
                sourceEventKey: reservation.event.eventKey, destination: destination),
            destinationFeed: freshFeed(destination),
            lastPublishFailed: false, now: now)
    }

    public static var cases: [TestCase] { [

        // MARK: - A reservation on each platform protects the other two

        TestCase(group: "End-to-end sync",
                 name: "a Booking.com reservation protects Airbnb and Vrbo") { expect in
            let reservation = source(.bookingCom, .confirmedReservation,
                                     day(2026, 12, 11), day(2026, 12, 21))
            for destination in [RentalPlatform.airbnb, .vrbo] {
                let (feed, imported) = roundTrip(
                    events: [reservation], destination: destination, policy: .default)
                expect.equal(feed.entries.count, 1, "\(destination.displayName) feed")
                expect.equal(imported.count, 1, "destination imported it")
                let result = verify(reservation, at: destination,
                                    imported: imported, policy: .default)
                expect.equal(result.status, .protected, destination.displayName)
                expect.ok(result.datesCovered)
            }
        },

        TestCase(group: "End-to-end sync",
                 name: "an Airbnb reservation protects Vrbo and Booking.com") { expect in
            let reservation = source(.airbnb, .confirmedReservation,
                                     day(2027, 1, 4), day(2027, 1, 12), summary: "Reserved")
            for destination in [RentalPlatform.vrbo, .bookingCom] {
                let (_, imported) = roundTrip(
                    events: [reservation], destination: destination, policy: .default)
                expect.equal(verify(reservation, at: destination,
                                    imported: imported, policy: .default).status,
                             .protected, destination.displayName)
            }
        },

        TestCase(group: "End-to-end sync",
                 name: "a Vrbo reservation protects Airbnb and Booking.com") { expect in
            let reservation = source(.vrbo, .confirmedReservation,
                                     day(2026, 12, 10), day(2026, 12, 17))
            for destination in [RentalPlatform.airbnb, .bookingCom] {
                let (_, imported) = roundTrip(
                    events: [reservation], destination: destination, policy: .default)
                expect.equal(verify(reservation, at: destination,
                                    imported: imported, policy: .default).status,
                             .protected, destination.displayName)
            }
        },

        // MARK: - Owner blocks go where they are selected

        TestCase(group: "End-to-end sync",
                 name: "an owner block reaches only the selected destinations") { expect in
            var policy = OutboundPolicy.default
            policy.ownerBlockDestinations = [.vrbo]
            let block = source(.bookingCom, .ownerBlock,
                               day(2026, 12, 23), day(2026, 12, 27))

            let vrbo = roundTrip(events: [block], destination: .vrbo, policy: policy)
            expect.equal(vrbo.feed.entries.count, 1, "Vrbo was selected")
            expect.equal(verify(block, at: .vrbo, imported: vrbo.imported,
                                policy: policy).status, .protected)

            let airbnb = roundTrip(events: [block], destination: .airbnb, policy: policy)
            expect.equal(airbnb.feed.entries.count, 0, "Airbnb was not selected")
            expect.ok(airbnb.feed.ics.contains("BEGIN:VCALENDAR"),
                      "an empty feed is still a valid calendar")
        },

        TestCase(group: "End-to-end sync",
                 name: "an UNAPPROVED owner block is not published") { expect in
            // Classified by hand but never approved for export. A block the
            // owner has not signed off must not start withdrawing inventory
            // on other platforms.
            let block = source(.bookingCom, .ownerBlock,
                               day(2026, 12, 23), day(2026, 12, 27), approved: false)
            let (feed, imported) = roundTrip(
                events: [block], destination: .vrbo, policy: .default)
            expect.equal(feed.entries.count, 0)
            expect.equal(imported.count, 0)
            expect.ok(feed.excluded.contains { $0.reason.contains("approved") },
                      "and the reason says so: \(feed.excluded.map(\.reason))")
        },

        // MARK: - What must never travel

        TestCase(group: "End-to-end sync",
                 name: "an Airbnb cancellation penalty reaches no destination") { expect in
            let penalty = source(.airbnb, .cancellationBlock,
                                 day(2026, 12, 17), day(2026, 12, 19),
                                 summary: "Airbnb (Not available)")
            for destination in [RentalPlatform.vrbo, .bookingCom] {
                let (feed, imported) = roundTrip(
                    events: [penalty], destination: destination, policy: .everything)
                expect.equal(feed.entries.count, 0,
                             "a penalty leaked into \(destination.displayName)")
                expect.equal(imported.count, 0)
                expect.ok(!feed.ics.contains("Not available"),
                          "and nothing of it is in the published calendar")
            }
        },

        TestCase(group: "End-to-end sync",
                 name: "an unknown unavailable stays home and stays in review") { expect in
            let unknown = source(.bookingCom, .unknownUnavailable,
                                 day(2026, 12, 11), day(2026, 12, 21), needsReview: true,
                                 summary: "CLOSED - Not available")
            for destination in [RentalPlatform.airbnb, .vrbo] {
                let (feed, _) = roundTrip(
                    events: [unknown], destination: destination, policy: .default)
                expect.equal(feed.entries.count, 0)
                let result = verify(unknown, at: destination, imported: [], policy: .default)
                expect.equal(result.status, .needsReview)
            }
        },

        TestCase(group: "End-to-end sync",
                 name: "a booking-window restriction never reaches a destination") { expect in
            let window = source(.bookingCom, .platformRestriction,
                                day(2027, 4, 1), day(2028, 5, 11))
            let (feed, _) = roundTrip(events: [window], destination: .airbnb, policy: .everything)
            expect.equal(feed.entries.count, 0)
        },

        // MARK: - Privacy of what we publish

        TestCase(group: "End-to-end sync",
                 name: "the published calendar carries no guest or source detail") { expect in
            let reservation = source(.bookingCom, .confirmedReservation,
                                     day(2026, 12, 11), day(2026, 12, 21),
                                     summary: "Reserved - Dana Example - BK12345678")
            let (feed, _) = roundTrip(
                events: [reservation], destination: .airbnb, policy: .default)
            for secret in ["Dana", "BK12345678", "Booking.com", "booking_com"] {
                expect.ok(!feed.ics.contains(secret),
                          "\"\(secret)\" leaked into the published calendar")
            }
            expect.contains(feed.ics, "Reserved")
            expect.ok(!feed.ics.contains(reservation.event.uid),
                      "the source UID must not be correlatable")
        },

        // MARK: - Stability and attribution

        TestCase(group: "End-to-end sync",
                 name: "a published UID is identical across republications") { expect in
            // Survives rebuilds and restarts because it is derived, not stored.
            let reservation = source(.vrbo, .confirmedReservation,
                                     day(2026, 12, 11), day(2026, 12, 21))
            let first = roundTrip(events: [reservation], destination: .airbnb, policy: .default)
            let second = roundTrip(events: [reservation], destination: .airbnb, policy: .default)
            expect.equal(first.feed.entries.first?.uid, second.feed.entries.first?.uid)
            expect.equal(
                DestinationFeedBuilder.publicationUID(
                    sourceEventKey: reservation.event.eventKey, destination: .airbnb),
                first.feed.entries.first?.uid,
                "and it is reproducible without the database")
        },

        TestCase(group: "End-to-end sync",
                 name: "an unrelated block at the destination is covered but NOT protected") { expect in
            let reservation = source(.bookingCom, .confirmedReservation,
                                     day(2026, 12, 11), day(2026, 12, 21))
            // The destination has its own block over the same nights, nothing
            // to do with us.
            var unrelated = source(.airbnb, .ownerBlock,
                                   day(2026, 12, 11), day(2026, 12, 21))
            unrelated.event.uid = "someone-elses@airbnb.com"

            let result = verify(reservation, at: .airbnb,
                                imported: [unrelated], policy: .default)
            expect.ok(result.datesCovered, "the nights are busy there")
            expect.equal(result.attribution, .coverageAttributionUnverified)
            expect.ok(result.status != .protected)
            expect.contains(result.explanation, "does not carry the identifier")
        },

        // MARK: - Failure must not reopen anything

        TestCase(group: "End-to-end sync",
                 name: "a failed destination import does not withdraw protection") { expect in
            // The source feed could not be read. That says nothing about
            // whether a guest is still staying, so nothing is withdrawn.
            expect.ok(!OutboundPolicy.mayWithdraw(
                afterImportOutcome: .failure, sourceStillPresent: false))
            let reservation = source(.bookingCom, .confirmedReservation,
                                     day(2026, 12, 11), day(2026, 12, 21))
            let (_, imported) = roundTrip(
                events: [reservation], destination: .airbnb, policy: .default)
            // A later publication attempt fails; the already-delivered block
            // is still standing at the destination.
            let result = DeliveryAssessment.assess(
                item: reservation, destination: .airbnb, policy: .default,
                observedAtDestination: imported,
                publishedUID: DestinationFeedBuilder.publicationUID(
                    sourceEventKey: reservation.event.eventKey, destination: .airbnb),
                destinationFeed: freshFeed(.airbnb),
                lastPublishFailed: true, now: now)
            expect.equal(result.status, .failed,
                         "the publication failure is reported...")
            expect.ok(imported.count == 1,
                      "...and the existing block is untouched")
        },

        // MARK: - The whole portfolio at once

        TestCase(group: "End-to-end sync",
                 name: "a mixed portfolio produces three correct destination feeds") { expect in
            let events = [
                source(.bookingCom, .confirmedReservation,
                       day(2026, 12, 11), day(2026, 12, 21)),
                source(.airbnb, .cancellationBlock,
                       day(2026, 12, 17), day(2026, 12, 19)),
                source(.vrbo, .ownerBlock, day(2026, 12, 23), day(2026, 12, 27)),
                source(.bookingCom, .unknownUnavailable,
                       day(2027, 1, 5), day(2027, 1, 9), needsReview: true),
                source(.airbnb, .platformRestriction,
                       day(2027, 5, 1), day(2027, 11, 12)),
            ]
            let feeds = DestinationFeedBuilder.buildAll(
                propertyID: property, propertyName: "Synthetic Cottage",
                events: events, policy: .default, now: now)
            expect.equal(feeds.count, 3)

            for feed in feeds {
                // No penalty, no window, no undecided — ever.
                for entry in feed.entries {
                    expect.ok(entry.kind != .cancellationBlock, feed.destination.displayName)
                    expect.ok(entry.kind != .platformRestriction)
                    expect.ok(entry.kind != .unknownUnavailable)
                    expect.ok(entry.sourcePlatform != feed.destination,
                              "a platform must not be sent its own event")
                }
            }
            let airbnb = feeds.first { $0.destination == .airbnb }
            expect.equal(airbnb?.entries.count, 2,
                         "the Booking.com reservation and the Vrbo owner block")
            let booking = feeds.first { $0.destination == .bookingCom }
            expect.equal(booking?.entries.count, 1, "only the Vrbo owner block")
        },
    ] }
}
