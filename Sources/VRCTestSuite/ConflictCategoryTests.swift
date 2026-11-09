import Foundation
import VRCCore

public enum ConflictCategoryTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

    /// `evidenced` controls whether the platform supplied booking details, which
    /// is what separates a verified reservation from the owner's own label.
    static func event(
        key: String, platform: RentalPlatform, kind: BlockKind,
        needsReview: Bool = false, evidenced: Bool = false,
        from: (Int, Int, Int), to: (Int, Int, Int), listingID: Int64 = 1
    ) -> ClassifiedEvent {
        ClassifiedEvent(
            event: CalendarEvent(
                listingID: listingID, eventKey: key, uid: key, platform: platform,
                summary: evidenced ? "Reserved" : "Blocked",
                details: evidenced
                    ? "Reservation URL: https://example.test/r\nPhone Number (Last 4 Digits): 1234"
                    : "",
                checkIn: day(from.0, from.1, from.2), checkOut: day(to.0, to.1, to.2)
            ),
            classification: EventClassification(
                eventKey: key, kind: kind, confidence: .high,
                source: .manual, needsReview: needsReview
            ),
            listingLabel: platform.displayName, propertyID: 1, propertyName: "39 G Street"
        )
    }

    static func listing(
        _ platform: RentalPlatform, id: Int64, syncedHoursAgo: Double? = 1,
        state: FeedConnectionState = .connected
    ) -> PlatformListing {
        PlatformListing(
            id: id, propertyID: 1, platform: platform, label: platform.displayName,
            lastSyncAt: syncedHoursAgo.map { Date().addingTimeInterval(-$0 * 3_600) },
            connectionState: state
        )
    }

    public static var cases: [TestCase] { [

        // --- Category 1: real booking conflicts ---------------------------

        TestCase(group: "Conflict categories",
                 name: "two platform-verified reservations are a booking conflict") { expect in
            let findings = ConflictAnalyzer().analyse(events: [
                event(key: "a", platform: .airbnb, kind: .confirmedReservation,
                      evidenced: true, from: (2027, 5, 10), to: (2027, 5, 15), listingID: 1),
                event(key: "b", platform: .vrbo, kind: .confirmedReservation,
                      evidenced: true, from: (2027, 5, 13), to: (2027, 5, 18), listingID: 2),
            ])
            expect.equal(findings.count, 1)
            guard let finding = findings.first else { return }
            expect.equal(finding.category, .bookingConflict)
            expect.ok(finding.category.isUrgent)
            expect.equal(finding.nights, 2)
            expect.equal(finding.verificationA, .platformEvidenced)
            expect.equal(finding.verificationB, .platformEvidenced)
        },

        TestCase(group: "Conflict categories",
                 name: "an owner-asserted reservation is a possible conflict, not a confirmed one") { expect in
            let findings = ConflictAnalyzer().analyse(events: [
                event(key: "a", platform: .airbnb, kind: .confirmedReservation,
                      evidenced: true, from: (2027, 5, 10), to: (2027, 5, 15), listingID: 1),
                // Classified by the owner; the feed said only "Blocked".
                event(key: "b", platform: .vrbo, kind: .confirmedReservation,
                      evidenced: false, from: (2027, 5, 13), to: (2027, 5, 18), listingID: 2),
            ])
            expect.equal(findings.count, 1)
            guard let finding = findings.first else { return }
            expect.equal(finding.category, .unverifiedBookingConflict,
                         "the app must not overstate what it knows")
            expect.ok(!finding.category.isUrgent)
            expect.contains(finding.detail, "classified as booked by you")
            expect.contains(finding.detail, "Vrbo")
        },

        // --- Category 2: block overlaps are never double bookings ----------

        TestCase(group: "Conflict categories",
                 name: "overlapping blocks are a calendar overlap, never a booking conflict") { expect in
            // The owner's real data: seven cancellation blocks, four overlaps.
            let findings = ConflictAnalyzer().analyse(events: [
                event(key: "v1", platform: .vrbo, kind: .cancellationBlock,
                      from: (2026, 11, 1), to: (2026, 11, 2), listingID: 1),
                event(key: "v2", platform: .vrbo, kind: .cancellationBlock,
                      from: (2026, 11, 1), to: (2026, 11, 30), listingID: 1),
                event(key: "a1", platform: .airbnb, kind: .cancellationBlock,
                      from: (2026, 11, 7), to: (2026, 11, 15), listingID: 2),
            ])
            expect.ok(!findings.isEmpty)
            for finding in findings {
                expect.equal(finding.category, .calendarOverlap, "blocks are not double bookings")
                expect.ok(!finding.category.isUrgent)
                expect.contains(finding.detail, "do not mean anyone is double booked")
            }
            expect.equal(
                findings.filter { $0.category == .bookingConflict }.count, 0,
                "not one of them may be reported as a booking conflict"
            )
        },

        TestCase(group: "Conflict categories",
                 name: "booking-window restrictions overlapping are informational") { expect in
            let findings = ConflictAnalyzer().analyse(events: [
                event(key: "a", platform: .airbnb, kind: .platformRestriction,
                      from: (2027, 5, 1), to: (2027, 11, 10), listingID: 1),
                event(key: "b", platform: .vrbo, kind: .platformRestriction,
                      from: (2027, 4, 1), to: (2029, 1, 1), listingID: 2),
            ])
            expect.equal(findings.count, 1)
            expect.equal(findings.first?.category, .calendarOverlap)
        },

        TestCase(group: "Conflict categories",
                 name: "an undecided event never becomes a booking conflict") { expect in
            let findings = ConflictAnalyzer().analyse(events: [
                event(key: "a", platform: .airbnb, kind: .confirmedReservation,
                      needsReview: true, evidenced: true,
                      from: (2027, 5, 10), to: (2027, 5, 15), listingID: 1),
                event(key: "b", platform: .vrbo, kind: .confirmedReservation,
                      evidenced: true, from: (2027, 5, 13), to: (2027, 5, 18), listingID: 2),
            ])
            expect.equal(findings.first?.category, .calendarOverlap,
                         "an unreviewed event is not an established reservation")
        },

        TestCase(group: "Conflict categories", name: "a same-day turnover is not a finding") { expect in
            let findings = ConflictAnalyzer().analyse(events: [
                event(key: "a", platform: .airbnb, kind: .confirmedReservation,
                      evidenced: true, from: (2027, 5, 10), to: (2027, 5, 14), listingID: 1),
                event(key: "b", platform: .vrbo, kind: .confirmedReservation,
                      evidenced: true, from: (2027, 5, 14), to: (2027, 5, 18), listingID: 2),
            ])
            expect.equal(findings.count, 0)
        },

        TestCase(group: "Conflict categories",
                 name: "categories are ordered with booking conflicts first") { expect in
            let findings = ConflictAnalyzer().analyse(events: [
                event(key: "x", platform: .airbnb, kind: .ownerBlock,
                      from: (2027, 1, 1), to: (2027, 1, 10), listingID: 1),
                event(key: "y", platform: .vrbo, kind: .ownerBlock,
                      from: (2027, 1, 5), to: (2027, 1, 12), listingID: 2),
                event(key: "a", platform: .airbnb, kind: .confirmedReservation,
                      evidenced: true, from: (2027, 5, 10), to: (2027, 5, 15), listingID: 1),
                event(key: "b", platform: .vrbo, kind: .confirmedReservation,
                      evidenced: true, from: (2027, 5, 13), to: (2027, 5, 18), listingID: 2),
            ])
            expect.equal(findings.first?.category, .bookingConflict,
                         "the urgent one must come first even though it is later in the year")
            expect.equal(findings.last?.category, .calendarOverlap)
        },

        TestCase(group: "Conflict categories",
                 name: "acknowledgements recorded under the old model still apply") { expect in
            let a = event(key: "aaa", platform: .airbnb, kind: .ownerBlock,
                          from: (2027, 1, 1), to: (2027, 1, 10), listingID: 1)
            let b = event(key: "bbb", platform: .vrbo, kind: .ownerBlock,
                          from: (2027, 1, 5), to: (2027, 1, 12), listingID: 2)
            // The identifier the previous ConflictDetector produced.
            let legacy = "aaa|bbb"
            let findings = ConflictAnalyzer().analyse(
                events: [a, b], acknowledgedIDs: [legacy]
            )
            expect.ok(findings.first?.acknowledged == true,
                      "acknowledgement history must survive the new categories")
        },

        // --- Category 3: availability differences ---------------------------

        TestCase(group: "Conflict categories",
                 name: "an unreadable platform reads as unknown, never as available") { expect in
            let overview = AvailabilityOverview()
            let availability = overview.day(
                day(2027, 6, 1), propertyID: 1,
                events: [],
                listings: [
                    listing(.airbnb, id: 1, syncedHoursAgo: 1),
                    listing(.vrbo, id: 2, syncedHoursAgo: nil),
                    listing(.bookingCom, id: 3, state: .revoked),
                ]
            )
            expect.equal(availability.status(for: .airbnb), .available)
            expect.equal(availability.status(for: .vrbo), .unknown,
                         "never imported — not knowable")
            expect.equal(availability.status(for: .bookingCom), .unknown,
                         "disconnected — not knowable")
            expect.ok(!PlatformDayStatus.unknown.isSellable,
                      "not knowing is not the same as being free")
            expect.ok(availability.hasUnknown)
        },

        TestCase(group: "Conflict categories",
                 name: "a stale feed cannot assert a night is available") { expect in
            let availability = AvailabilityOverview().day(
                day(2027, 6, 1), propertyID: 1, events: [],
                listings: [listing(.airbnb, id: 1, syncedHoursAgo: 72)]
            )
            expect.equal(availability.status(for: .airbnb), .unknown)
        },

        TestCase(group: "Conflict categories",
                 name: "availability distinguishes all five states per platform") { expect in
            let availability = AvailabilityOverview().day(
                day(2027, 6, 1), propertyID: 1,
                events: [
                    event(key: "a", platform: .airbnb, kind: .confirmedReservation,
                          evidenced: true, from: (2027, 6, 1), to: (2027, 6, 5), listingID: 1),
                    event(key: "b", platform: .vrbo, kind: .ownerBlock,
                          from: (2027, 6, 1), to: (2027, 6, 5), listingID: 2),
                    event(key: "c", platform: .bookingCom, kind: .platformRestriction,
                          from: (2027, 6, 1), to: (2027, 6, 5), listingID: 3),
                ],
                listings: [
                    listing(.airbnb, id: 1), listing(.vrbo, id: 2), listing(.bookingCom, id: 3),
                ]
            )
            expect.equal(availability.status(for: .airbnb), .confirmedBooked)
            expect.equal(availability.status(for: .vrbo), .ownerBlocked)
            expect.equal(availability.status(for: .bookingCom), .platformRestricted)
            expect.ok(availability.isDiscrepant, "the platforms disagree about this night")
            expect.equal(availability.headline, .confirmedBooked,
                         "a booking is the most important thing about the night")
        },

        TestCase(group: "Conflict categories",
                 name: "an undecided block reads as uncertain, not as blocked") { expect in
            let availability = AvailabilityOverview().day(
                day(2027, 6, 1), propertyID: 1,
                events: [
                    event(key: "a", platform: .airbnb, kind: .unknownUnavailable,
                          needsReview: true, from: (2027, 6, 1), to: (2027, 6, 5), listingID: 1),
                ],
                listings: [listing(.airbnb, id: 1)]
            )
            expect.equal(availability.status(for: .airbnb), .uncertain)
            expect.ok(!availability.status(for: .airbnb).isSellable)
            expect.contains(PlatformDayStatus.uncertain.explanation, "not treated as sellable")
        },

        TestCase(group: "Conflict categories",
                 name: "an owner-asserted booking is marked as not confirmed") { expect in
            let availability = AvailabilityOverview().day(
                day(2027, 6, 1), propertyID: 1,
                events: [
                    event(key: "a", platform: .vrbo, kind: .confirmedReservation,
                          evidenced: false, from: (2027, 6, 1), to: (2027, 6, 5), listingID: 1),
                ],
                listings: [listing(.vrbo, id: 1)]
            )
            expect.equal(availability.status(for: .vrbo), .bookedUnverified)
            expect.contains(PlatformDayStatus.bookedUnverified.label, "not confirmed")
        },

        TestCase(group: "Conflict categories",
                 name: "differences list the dates worth looking at") { expect in
            let differences = AvailabilityOverview().differences(
                from: day(2027, 6, 1), days: 5, propertyID: 1,
                events: [
                    event(key: "a", platform: .airbnb, kind: .confirmedReservation,
                          evidenced: true, from: (2027, 6, 1), to: (2027, 6, 3), listingID: 1),
                ],
                listings: [
                    listing(.airbnb, id: 1),
                    listing(.bookingCom, id: 2, state: .revoked),
                ]
            )
            expect.equal(differences.count, 5, "every day has an unknown platform")
            expect.ok(differences.allSatisfy(\.hasUnknown))
            expect.contains(differences[0].summary, "unknown")
            // Only one platform is visible, so there is nothing to disagree
            // with — the day is worth showing because of the gap, not a clash.
            expect.ok(!differences[0].platformsDisagree)
            expect.equal(differences[0].knownPlatforms, [.airbnb])
            expect.equal(differences[0].unknownPlatforms, [.bookingCom])
        },

        TestCase(group: "Conflict categories",
                 name: "two visible platforms that differ do count as a disagreement") { expect in
            let differences = AvailabilityOverview().differences(
                from: day(2027, 6, 1), days: 1, propertyID: 1,
                events: [
                    event(key: "a", platform: .airbnb, kind: .confirmedReservation,
                          evidenced: true, from: (2027, 6, 1), to: (2027, 6, 3), listingID: 1),
                ],
                listings: [listing(.airbnb, id: 1), listing(.vrbo, id: 2)]
            )
            expect.equal(differences.count, 1)
            expect.ok(differences[0].platformsDisagree,
                      "booked on Airbnb, open on Vrbo")
            expect.ok(!differences[0].hasUnknown)
            expect.equal(Set(differences[0].knownPlatforms), Set([.airbnb, .vrbo]))
        },

        TestCase(group: "Conflict categories",
                 name: "a fully readable, fully open day is not a difference") { expect in
            let differences = AvailabilityOverview().differences(
                from: day(2027, 6, 1), days: 3, propertyID: 1, events: [],
                listings: [listing(.airbnb, id: 1), listing(.vrbo, id: 2)]
            )
            expect.equal(differences.count, 0)
        },
    ] }
}
