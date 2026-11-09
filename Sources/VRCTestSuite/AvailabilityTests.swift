import Foundation
import VRCCore

public enum AvailabilityTests {

    // MARK: Helpers

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

    /// A store with one property, three listings all freshly synced, and the
    /// given source events already classified.
    static func makeStore(
        events: [(RentalPlatform, BlockKind, Bool, (Int, Int, Int), (Int, Int, Int))] = [],
        syncedAt: Date? = Date()
    ) throws -> (store: RentalStore, propertyID: Int64) {
        let store = try RentalStore.makeInMemory()
        let property = try store.properties.insert(
            Property(name: "39 G Street", address: "South Boston")
        )
        let propertyID = property.id!

        var listingIDs: [RentalPlatform: Int64] = [:]
        for platform in [RentalPlatform.airbnb, .vrbo, .bookingCom] {
            let listing = try store.listings.insert(PlatformListing(
                propertyID: propertyID, platform: platform,
                label: "\(platform.displayName) — 39 G Street",
                icalURL: "https://example.test/\(platform.rawValue).ics",
                urlStorage: .database
            ))
            listingIDs[platform] = listing.id
            if let syncedAt {
                try store.listings.recordSync(
                    listingID: listing.id!, at: syncedAt, summary: "ok"
                )
            }
        }

        for (index, spec) in events.enumerated() {
            let (platform, kind, needsReview, from, to) = spec
            let key = "evt-\(index)-\(platform.rawValue)"
            try store.events.upsert(CalendarEvent(
                listingID: listingIDs[platform]!, eventKey: key, uid: key, platform: platform,
                summary: kind == .confirmedReservation ? "Reserved" : "Blocked",
                checkIn: day(from.0, from.1, from.2), checkOut: day(to.0, to.1, to.2)
            ))
            try store.classifications.save(EventClassification(
                eventKey: key, kind: kind, confidence: .high,
                source: needsReview ? .automatic : .manual, needsReview: needsReview
            ))
        }
        return (store, propertyID)
    }

    static func plan(
        _ propertyID: Int64, _ actions: [RentalPlatform: AvailabilityAction],
        from: (Int, Int, Int) = (2026, 12, 10), to: (Int, Int, Int) = (2026, 12, 15)
    ) -> AvailabilityPlan {
        AvailabilityPlan(
            propertyID: propertyID,
            startDay: day(from.0, from.1, from.2),
            endDay: day(to.0, to.1, to.2),
            reason: "Test",
            actions: actions
        )
    }

    public static var cases: [TestCase] { [

        // --- Checkout-exclusive intervals --------------------------------

        TestCase(group: "Availability",
                 name: "blocking 10-15 December blocks five nights, not six") { expect in
            let decision = AvailabilityDecision(
                propertyID: 1, destination: .vrbo, action: .block,
                startDay: day(2026, 12, 10), endDay: day(2026, 12, 15)
            )
            expect.equal(decision.nights, 5)
            expect.ok(decision.covers(day: day(2026, 12, 10)), "the 10th is blocked")
            expect.ok(decision.covers(day: day(2026, 12, 14)), "the 14th is blocked")
            expect.ok(!decision.covers(day: day(2026, 12, 15)),
                      "the 15th stays free for an arrival")
            expect.contains(decision.nightsDescription, "5 nights")
        },

        // --- Independent per-platform decisions --------------------------

        TestCase(group: "Availability",
                 name: "a Vrbo decision does not touch Airbnb") { expect in
            let setup = try makeStore()
            let submitted = try setup.store.availabilityManager.submit(
                plan(setup.propertyID, [
                    .airbnb: .leaveUnchanged,
                    .vrbo: .block,
                    .bookingCom: .block,
                ])
            )
            expect.equal(submitted.count, 3, "one decision per platform touched")

            let airbnb = submitted.first { $0.destination == .airbnb }
            expect.equal(airbnb?.action, .leaveUnchanged)

            let vrbo = submitted.first { $0.destination == .vrbo }
            expect.equal(vrbo?.action, .block)
            expect.equal(vrbo?.status, .awaitingApproval)

            // Approving Vrbo changes nothing about Airbnb.
            _ = try setup.store.availabilityManager.approve(decisionID: vrbo!.id!)
            let airbnbAfter = try setup.store.availability.find(id: airbnb!.id!)
            expect.equal(airbnbAfter?.action, .leaveUnchanged)
            expect.ok(airbnbAfter?.approvedAt == nil, "Airbnb was never approved for anything")
        },

        // --- R7: never reopen a booked night ------------------------------

        TestCase(group: "Availability",
                 name: "R7 refuses reopening a night held by a confirmed reservation") { expect in
            let setup = try makeStore(events: [
                (.vrbo, .confirmedReservation, false, (2026, 12, 12), (2026, 12, 16)),
            ])
            let preview = try setup.store.availabilityManager.preview(
                plan(setup.propertyID, [.vrbo: .unblock])
            )
            guard let line = preview.lines.first else { return expect.fail("no preview line") }
            expect.ok(!line.canProceed, "reopening must be refused outright")
            expect.equal(line.validation.blocking.first?.rule, .neverReopenConfirmedReservation)
            expect.contains(line.validation.headline, "confirmed reservation")

            // And submitting it records the refusal rather than proceeding.
            let submitted = try setup.store.availabilityManager.submit(
                plan(setup.propertyID, [.vrbo: .unblock])
            )
            expect.equal(submitted.first?.status, .failed)
        },

        // --- R6: never remove someone else's block ------------------------

        TestCase(group: "Availability",
                 name: "R6 refuses removing a block this app did not create") { expect in
            let setup = try makeStore(events: [
                (.vrbo, .ownerBlock, false, (2026, 12, 10), (2026, 12, 15)),
            ])
            let preview = try setup.store.availabilityManager.preview(
                plan(setup.propertyID, [.vrbo: .unblock])
            )
            guard let line = preview.lines.first else { return expect.fail("no line") }
            expect.ok(!line.canProceed)
            expect.equal(line.validation.blocking.first?.rule, .neverOverridePlatformRestriction)
            expect.contains(line.validation.headline, "nothing of ours to remove")
        },

        // --- Conflict checks ----------------------------------------------

        TestCase(group: "Availability", name: "a stale feed forces a review") { expect in
            let old = Date().addingTimeInterval(-48 * 3_600)
            let setup = try makeStore(syncedAt: old)
            let preview = try setup.store.availabilityManager.preview(
                plan(setup.propertyID, [.vrbo: .block])
            )
            guard let line = preview.lines.first else { return expect.fail("no line") }
            expect.ok(line.canProceed, "stale is a warning, not a refusal")
            expect.ok(line.validation.needsReview)
            expect.contains(
                line.validation.needingReview.map(\.message).joined(separator: " "),
                "six hours"
            )
        },

        TestCase(group: "Availability", name: "a never-imported feed forces a review") { expect in
            let setup = try makeStore(syncedAt: nil)
            let preview = try setup.store.availabilityManager.preview(
                plan(setup.propertyID, [.vrbo: .block])
            )
            expect.ok(preview.needsReviewAnywhere)
            expect.contains(
                preview.lines[0].validation.needingReview.map(\.message).joined(separator: " "),
                "never been imported"
            )
        },

        TestCase(group: "Availability", name: "overlapping undecided events are surfaced") { expect in
            let setup = try makeStore(events: [
                (.airbnb, .unknownUnavailable, true, (2026, 12, 11), (2026, 12, 13)),
            ])
            let preview = try setup.store.availabilityManager.preview(
                plan(setup.propertyID, [.vrbo: .block])
            )
            let messages = preview.lines[0].validation.violations.map(\.message).joined(separator: " ")
            expect.contains(messages, "undecided")
        },

        TestCase(group: "Availability", name: "a pending change over the same nights is flagged") { expect in
            let setup = try makeStore()
            _ = try setup.store.availabilityManager.submit(
                plan(setup.propertyID, [.vrbo: .block])
            )
            let preview = try setup.store.availabilityManager.preview(
                plan(setup.propertyID, [.vrbo: .block])
            )
            expect.ok(preview.needsReviewAnywhere)
            expect.contains(
                preview.lines[0].validation.needingReview.map(\.message).joined(separator: " "),
                "still waiting"
            )
        },

        TestCase(group: "Availability",
                 name: "blocking another platform over an Airbnb cancellation block warns") { expect in
            let setup = try makeStore(events: [
                (.airbnb, .cancellationBlock, false, (2026, 12, 10), (2026, 12, 15)),
            ])
            let preview = try setup.store.availabilityManager.preview(
                plan(setup.propertyID, [.vrbo: .block])
            )
            let review = preview.lines[0].validation.needingReview
            expect.ok(review.contains { $0.rule == .neverPropagateCancellationBlock },
                      "the owner must be told what those nights actually are")
            expect.contains(review.map(\.message).joined(separator: " "), "still sellable")
        },

        // --- State machine ------------------------------------------------

        TestCase(group: "Availability", name: "a decision cannot skip from draft to published") { expect in
            let setup = try makeStore()
            let submitted = try setup.store.availabilityManager.submit(
                plan(setup.propertyID, [.vrbo: .block])
            )
            guard let decision = submitted.first, let id = decision.id else {
                return expect.fail("nothing submitted")
            }
            expect.equal(decision.status, .awaitingApproval)
            do {
                _ = try setup.store.availabilityManager.markPublished(decisionID: id)
                expect.fail("publishing an unapproved decision must fail")
            } catch {
                // expected — and it is refused for two reasons at once
            }
        },

        TestCase(group: "Availability", name: "approval is recorded, publication is not") { expect in
            let setup = try makeStore()
            let submitted = try setup.store.availabilityManager.submit(
                plan(setup.propertyID, [.vrbo: .block])
            )
            let id = submitted[0].id!
            let approved = try setup.store.availabilityManager.approve(
                decisionID: id, actor: "owner"
            )
            expect.equal(approved.status, .approved)
            expect.ok(approved.approvedAt != nil)
            expect.equal(approved.approvedBy, "owner")
            expect.ok(approved.publishedAt == nil, "approval is not publication")

            do {
                _ = try setup.store.availabilityManager.markPublished(decisionID: id)
                expect.fail("the outbound gate must refuse publication")
            } catch let error as AvailabilityError {
                if case .outboundDisabled = error {} else {
                    expect.fail("wrong error: \(error)")
                }
            }
        },

        TestCase(group: "Availability", name: "cancelling leaves the history intact") { expect in
            let setup = try makeStore()
            let submitted = try setup.store.availabilityManager.submit(
                plan(setup.propertyID, [.vrbo: .block])
            )
            let id = submitted[0].id!
            let cancelled = try setup.store.availabilityManager.cancel(decisionID: id)
            expect.equal(cancelled.status, .cancelled)
            expect.ok(cancelled.cancelledAt != nil)

            let history = try setup.store.auditLog.entries(forDecision: id)
            expect.ok(history.count >= 4, "created, validated, awaiting, cancelled")
            expect.ok(history.contains { $0.toStatus == .cancelled })
            expect.ok(history.contains { $0.event == "created" })
            // The decision row survives — cancellation is not deletion.
            expect.ok(try setup.store.availability.find(id: id) != nil)
        },

        TestCase(group: "Availability", name: "cancel pending clears everything open") { expect in
            let setup = try makeStore()
            _ = try setup.store.availabilityManager.submit(
                plan(setup.propertyID, [.vrbo: .block, .bookingCom: .block])
            )
            let cleared = try setup.store.availabilityManager.cancelPending(
                propertyID: setup.propertyID
            )
            expect.equal(cleared, 2)
            expect.equal(try setup.store.availability.pending().count, 0)
        },

        TestCase(group: "Availability", name: "every status transition is audited") { expect in
            let setup = try makeStore()
            let submitted = try setup.store.availabilityManager.submit(
                plan(setup.propertyID, [.vrbo: .block])
            )
            let id = submitted[0].id!
            _ = try setup.store.availabilityManager.approve(decisionID: id)
            let history = try setup.store.auditLog.entries(forDecision: id)
            let transitions = history.compactMap(\.toStatus)
            expect.ok(transitions.contains(.draft))
            expect.ok(transitions.contains(.validated))
            expect.ok(transitions.contains(.awaitingApproval))
            expect.ok(transitions.contains(.approved))
            for entry in history { expect.ok(!entry.line.isEmpty) }
        },

        // --- R9: source events are never edited ----------------------------

        TestCase(group: "Availability",
                 name: "R9 an availability decision never touches imported events") { expect in
            let setup = try makeStore(events: [
                (.vrbo, .ownerBlock, false, (2026, 12, 20), (2026, 12, 24)),
            ])
            let before = try setup.store.events.all(includeTombstoned: true)
            let beforeHash = before.map { "\($0.eventKey)\($0.checkIn)\($0.checkOut)\($0.summary)" }

            let submitted = try setup.store.availabilityManager.submit(
                plan(setup.propertyID, [.vrbo: .block])
            )
            _ = try setup.store.availabilityManager.approve(decisionID: submitted[0].id!)

            let after = try setup.store.events.all(includeTombstoned: true)
            let afterHash = after.map { "\($0.eventKey)\($0.checkIn)\($0.checkOut)\($0.summary)" }
            expect.equal(afterHash, beforeHash, "imported events must be untouched")
            expect.equal(after.count, before.count)
        },

        // --- R5: material change returns for review ------------------------

        TestCase(group: "Availability",
                 name: "R5 a materially changed event returns for review, decision kept") { expect in
            let original = CalendarEvent(
                listingID: 1, eventKey: "k", uid: "k", platform: .airbnb, summary: "Blocked",
                checkIn: day(2027, 3, 10), checkOut: day(2027, 3, 15)
            )
            var moved = original
            moved.checkIn = day(2027, 3, 12)
            moved.checkOut = day(2027, 3, 20)

            let assessment = MaterialChange.assess(
                previous: original, updated: moved, platform: .airbnb
            )
            expect.ok(assessment.isMaterial)
            expect.contains(assessment.explanation, "dates moved")

            let decided = EventClassification(
                eventKey: "k", kind: .ownerBlock, confidence: .high, source: .manual,
                needsReview: false, exportApproved: true
            )
            let flagged = MaterialChange.flagForReReview(decided, assessment: assessment)
            expect.equal(flagged.kind, .ownerBlock, "the decision itself is kept")
            expect.equal(flagged.source, .manual, "and it is still yours")
            expect.ok(flagged.needsReview, "but it comes back for review")
            expect.ok(!flagged.exportApproved, "and the old approval no longer applies")
            expect.contains(flagged.rationale, "until you confirm")
        },

        TestCase(group: "Availability", name: "an unchanged re-import is not material") { expect in
            let event = CalendarEvent(
                listingID: 1, eventKey: "k", uid: "k", platform: .vrbo, summary: "Blocked",
                checkIn: day(2027, 3, 10), checkOut: day(2027, 3, 15)
            )
            let assessment = MaterialChange.assess(
                previous: event, updated: event, platform: .vrbo
            )
            expect.ok(!assessment.isMaterial)
            expect.equal(assessment.reasons.count, 0)
        },

        TestCase(group: "Availability",
                 name: "gaining booking evidence counts as material") { expect in
            var before = CalendarEvent(
                listingID: 1, eventKey: "k", uid: "k", platform: .airbnb,
                summary: "Airbnb (Not available)", details: "",
                checkIn: day(2027, 3, 10), checkOut: day(2027, 3, 15)
            )
            before.details = ""
            var after = before
            after.details = "Reservation URL: https://www.airbnb.com/hosting/reservations/details/X"
            let assessment = MaterialChange.assess(
                previous: before, updated: after, platform: .airbnb
            )
            expect.ok(assessment.isMaterial)
            expect.contains(assessment.explanation, "booking details")
        },

        // --- Preview ---------------------------------------------------------

        TestCase(group: "Availability", name: "preview writes nothing") { expect in
            let setup = try makeStore()
            let before = try setup.store.availability.count()
            _ = try setup.store.availabilityManager.preview(
                plan(setup.propertyID, [.vrbo: .block, .airbnb: .leaveUnchanged])
            )
            expect.equal(try setup.store.availability.count(), before,
                         "a preview must not create decisions")
            expect.equal(try setup.store.auditLog.count(), 0, "nor audit entries")
        },

        TestCase(group: "Availability", name: "preview spells the nights out") { expect in
            let setup = try makeStore()
            let preview = try setup.store.availabilityManager.preview(
                plan(setup.propertyID, [.vrbo: .block])
            )
            expect.equal(preview.nights, 5)
            expect.contains(preview.nightsDescription, "Dec 14, 2026")
            expect.contains(preview.nightsDescription, "free for an arrival")
        },
    ] }
}
