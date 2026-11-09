import Foundation
import VRCCore

public enum ExportTests {
    static func item(
        key: String, platform: RentalPlatform, kind: BlockKind,
        source: ClassificationSource, needsReview: Bool, approved: Bool = false,
        suppressed: Bool = false, confidence: ClassificationConfidence = .high,
        from: (Int, Int, Int) = (2027, 3, 10), to: (Int, Int, Int) = (2027, 3, 15)
    ) -> ClassifiedEvent {
        ClassifiedEvent(
            event: CalendarEvent(
                listingID: 1, eventKey: key, uid: key, platform: platform,
                summary: kind.displayName,
                checkIn: DayMath.day(from.0, from.1, from.2),
                checkOut: DayMath.day(to.0, to.1, to.2)
            ),
            classification: EventClassification(
                eventKey: key, kind: kind, confidence: confidence, source: source,
                needsReview: needsReview, exportApproved: approved, exportSuppressed: suppressed
            ),
            listingLabel: "\(platform.displayName) listing",
            propertyID: 1, propertyName: "Test Property"
        )
    }

    public static var cases: [TestCase] { [
        TestCase(group: "Export", name: "a confirmed reservation is included") { expect in
            let plan = ExportService().plan(
                propertyID: 1, propertyName: "Test Property",
                events: [item(key: "r1", platform: .airbnb, kind: .confirmedReservation,
                              source: .automatic, needsReview: false)],
                destination: .vrbo
            )
            expect.equal(plan.included.count, 1)
        },

        TestCase(group: "Export", name: "a cancellation block can never be included") { expect in
            // Every trick that might sneak one through, tried at once.
            let events = [
                item(key: "c1", platform: .airbnb, kind: .cancellationBlock,
                     source: .manual, needsReview: false, approved: true),
                item(key: "c2", platform: .airbnb, kind: .cancellationBlock,
                     source: .automatic, needsReview: false, approved: true),
            ]
            let plan = ExportService().plan(
                propertyID: 1, propertyName: "Test Property", events: events, destination: .vrbo
            )
            expect.equal(plan.included.count, 0, "approval must not override the rule")
            expect.equal(plan.excluded.count, 2)
            for excluded in plan.excluded {
                expect.contains(excluded.decision.reason, "never exported")
            }
        },

        TestCase(group: "Export", name: "an unknown block can never be included") { expect in
            let plan = ExportService().plan(
                propertyID: 1, propertyName: "Test Property",
                events: [item(key: "u1", platform: .airbnb, kind: .unknownUnavailable,
                              source: .manual, needsReview: false, approved: true)],
                destination: .vrbo
            )
            expect.equal(plan.included.count, 0)
        },

        TestCase(group: "Export", name: "anything awaiting review is held back") { expect in
            let plan = ExportService().plan(
                propertyID: 1, propertyName: "Test Property",
                events: [item(key: "p1", platform: .airbnb, kind: .confirmedReservation,
                              source: .automatic, needsReview: true)],
                destination: .vrbo
            )
            expect.equal(plan.included.count, 0)
            expect.contains(plan.excluded.first?.decision.reason ?? "", "review")
        },

        TestCase(group: "Export",
                 name: "an owner block needs a manual decision AND approval") { expect in
            let service = ExportService()
            let autoClassified = service.plan(
                propertyID: 1, propertyName: "P",
                events: [item(key: "o1", platform: .airbnb, kind: .ownerBlock,
                              source: .automatic, needsReview: false, approved: true)],
                destination: .vrbo
            )
            expect.equal(autoClassified.included.count, 0, "auto-classified blocks never export")

            let manualUnapproved = service.plan(
                propertyID: 1, propertyName: "P",
                events: [item(key: "o2", platform: .airbnb, kind: .ownerBlock,
                              source: .manual, needsReview: false, approved: false)],
                destination: .vrbo
            )
            expect.equal(manualUnapproved.included.count, 0, "approval is still required")

            let manualApproved = service.plan(
                propertyID: 1, propertyName: "P",
                events: [item(key: "o3", platform: .airbnb, kind: .ownerBlock,
                              source: .manual, needsReview: false, approved: true)],
                destination: .vrbo
            )
            expect.equal(manualApproved.included.count, 1)
        },

        TestCase(group: "Export", name: "the owner can suppress anything by hand") { expect in
            let plan = ExportService().plan(
                propertyID: 1, propertyName: "P",
                events: [item(key: "s1", platform: .airbnb, kind: .confirmedReservation,
                              source: .manual, needsReview: false, suppressed: true)],
                destination: .vrbo
            )
            expect.equal(plan.included.count, 0)
        },

        TestCase(group: "Export",
                 name: "events are not sent back to the platform they came from") { expect in
            let events = [
                item(key: "v1", platform: .vrbo, kind: .confirmedReservation,
                     source: .manual, needsReview: false),
                item(key: "a1", platform: .airbnb, kind: .confirmedReservation,
                     source: .manual, needsReview: false, from: (2027, 4, 1), to: (2027, 4, 5)),
            ]
            let plan = ExportService().plan(
                propertyID: 1, propertyName: "P", events: events, destination: .vrbo
            )
            expect.equal(plan.included.count, 1)
            expect.equal(plan.included.first?.event.platform, .airbnb)
        },

        TestCase(group: "Export", name: "the written .ics carries no guest details") { expect in
            var guesty = item(key: "g1", platform: .airbnb, kind: .confirmedReservation,
                              source: .manual, needsReview: false)
            guesty.event.summary = "Reserved - Dana Pemberton"
            guesty.event.details = "Phone Number (Last 4 Digits): 8891\nEmail: dana@example.com"
            let service = ExportService()
            let plan = service.plan(
                propertyID: 1, propertyName: "P", events: [guesty], destination: .vrbo
            )
            let text = service.makeICS(from: plan)
            expect.contains(text, "SUMMARY:Reserved")
            expect.notContains(text, "Pemberton", "guest name must not leave this Mac")
            expect.notContains(text, "8891", "phone digits must not leave this Mac")
            expect.notContains(text, "dana@example.com")
            expect.notContains(text, guesty.event.uid, "the source UID must not be exposed")
        },

        TestCase(group: "Export", name: "the written .ics is well formed") { expect in
            let plan = ExportService().plan(
                propertyID: 1, propertyName: "P",
                events: [item(key: "w1", platform: .airbnb, kind: .confirmedReservation,
                              source: .manual, needsReview: false)],
                destination: .vrbo
            )
            let text = ExportService().makeICS(from: plan)
            expect.contains(text, "BEGIN:VCALENDAR")
            expect.contains(text, "END:VCALENDAR")
            expect.contains(text, "DTSTART;VALUE=DATE:20270310")
            expect.contains(text, "DTEND;VALUE=DATE:20270315")
            expect.contains(text, "\r\n", "RFC 5545 requires CRLF")
            // Round-trips through our own parser.
            let reparsed = try ICalParser.parse(text)
            expect.equal(reparsed.events.count, 1)
            expect.equal(reparsed.events.first?.resolvedCheckIn, DayMath.day(2027, 3, 10))
        },

        TestCase(group: "Export", name: "long lines are folded at 75 octets") { expect in
            let writer = ICalWriter()
            let long = String(repeating: "a", count: 400)
            let folded = writer.fold("SUMMARY:" + long)
            for line in folded.components(separatedBy: "\r\n") {
                expect.ok(line.utf8.count <= 76, "line of \(line.utf8.count) octets is too long")
            }
            expect.contains(folded, "\r\n ", "continuations start with a space")
        },

        TestCase(group: "Export", name: "text escaping follows RFC 5545") { expect in
            let writer = ICalWriter()
            expect.equal(writer.escape("a,b;c\\d\ne"), "a\\,b\\;c\\\\d\\ne")
        },

        TestCase(group: "Export", name: "the audit names what was held back and why") { expect in
            let service = ExportService()
            let plan = service.plan(
                propertyID: 1, propertyName: "P",
                events: [
                    item(key: "i1", platform: .airbnb, kind: .confirmedReservation,
                         source: .manual, needsReview: false),
                    item(key: "x1", platform: .airbnb, kind: .cancellationBlock,
                         source: .manual, needsReview: false,
                         from: (2027, 6, 1), to: (2027, 6, 8)),
                ],
                destination: .vrbo
            )
            let audit = service.auditText(for: plan)
            expect.contains(audit, "INCLUDED")
            expect.contains(audit, "EXCLUDED")
            expect.contains(audit, "stayed sellable")
            expect.equal(plan.protectedNights, 7)
        },
    ] }
}

// MARK: - Security

public enum SecurityTests {
    public static var cases: [TestCase] { [
        TestCase(group: "Security",
                 name: "a Keychain-backed feed URL is never written to the database") { expect in
            let store = try RentalStore(
                database: Database.inMemory(), credentials: InMemoryFeedCredentialStore()
            )
            let property = try store.properties.insert(Property(name: "P"))
            let listing = try store.listings.insert(PlatformListing(
                propertyID: property.id!, platform: .vrbo, label: "Vrbo — P",
                icalURL: "https://www.vrbo.com/icalendar/SECRETTOKEN.ics?nonTentative",
                urlStorage: .keychain, credentialRef: "vrbo-test"
            ))
            expect.ok(!(try store.listings.databaseLeaksAnyKeychainURL()),
                      "no keychain-backed URL may sit in the database")

            let rows = try store.database.query("SELECT ical_url FROM platform_listings;")
            for row in rows {
                expect.notContains(row.stringValue("ical_url"), "SECRETTOKEN")
            }
            // But it resolves when actually needed.
            expect.contains(try store.listings.resolveURL(for: listing), "SECRETTOKEN")
        },

        TestCase(group: "Security", name: "a redacted URL hides the token") { expect in
            let listing = PlatformListing(
                propertyID: 1, platform: .vrbo, label: "V",
                icalURL: "https://www.vrbo.com/icalendar/SECRETTOKEN.ics?nonTentative"
            )
            expect.notContains(listing.redactedURL, "SECRETTOKEN")
            expect.contains(listing.redactedURL, "vrbo.com")
        },

        TestCase(group: "Security", name: "plain http feeds are refused") { expect in
            let fetcher = URLSessionFeedFetcher()
            do {
                _ = try await fetcher.fetch(urlString: "http://example.test/calendar.ics")
                expect.fail("http should be refused")
            } catch let error as FeedFetchError {
                if case .insecureURL = error {} else { expect.fail("wrong error: \(error)") }
            }
        },

        TestCase(group: "Security", name: "file URLs are refused unless explicitly allowed") { expect in
            do {
                _ = try await URLSessionFeedFetcher().fetch(urlString: "file:///etc/hosts")
                expect.fail("file URLs should be refused by default")
            } catch {
                // expected
            }
        },

        TestCase(group: "Security", name: "outbound synchronisation is hard-disabled") { expect in
            expect.ok(!OutboundSyncGate.isEnabled,
                      "no build may ship with outbound sync enabled before approval")
        },

        TestCase(group: "Security", name: "seed data contains no credentials") { expect in
            for seed in SeedData.all {
                for listing in seed.listings {
                    expect.notContains(listing.credentialRef, "http")
                    expect.ok(!listing.credentialRef.isEmpty, "a Keychain reference is required")
                }
            }
        },
    ] }
}
