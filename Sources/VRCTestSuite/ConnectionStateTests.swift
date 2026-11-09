import Foundation
import VRCCore

public enum ConnectionStateTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

    static func storeWithListing(
        state: FeedConnectionState = .connected, url: String = "https://example.test/f.ics"
    ) throws -> (store: RentalStore, listingID: Int64, propertyID: Int64) {
        let store = try RentalStore.makeInMemory()
        let property = try store.properties.insert(Property(name: "Southie Beach House"))
        let listing = try store.listings.insert(PlatformListing(
            propertyID: property.id!, platform: .bookingCom,
            label: "Booking.com — Southie Beach House (17482435)",
            icalURL: url, urlStorage: .database, connectionState: state
        ))
        return (store, listing.id!, property.id!)
    }

    public static var cases: [TestCase] { [

        // --- 1. Revocation is recognised, not mistaken for a network fault ---

        TestCase(group: "Connection state",
                 name: "Booking.com's Invalid Token reads as revoked, not as a failure") { expect in
            // The exact response the live endpoint returned.
            let body = #"{"detail":"Invalid Token","instance":"/v1/export","status":400,"title":"Bad Request"}"#
            expect.ok(URLSessionFeedFetcher.indicatesRevocation(status: 400, body: body))
            expect.equal(URLSessionFeedFetcher.summarise(body), "Invalid Token")
        },

        TestCase(group: "Connection state",
                 name: "unambiguous rejections are revocations, server trouble is not") { expect in
            for status in [401, 403, 410] {
                expect.ok(URLSessionFeedFetcher.indicatesRevocation(status: status, body: ""),
                          "HTTP \(status) is a rejection of the credential")
            }
            for status in [500, 502, 503, 504, 429] {
                expect.ok(!URLSessionFeedFetcher.indicatesRevocation(status: status, body: ""),
                          "HTTP \(status) may be temporary and must stay retryable")
            }
            // A bare 400 with nothing to go on is treated as transient.
            expect.ok(!URLSessionFeedFetcher.indicatesRevocation(status: 400, body: "oops"))
            expect.ok(URLSessionFeedFetcher.indicatesRevocation(
                status: 404, body: "calendar not found"
            ))
        },

        TestCase(group: "Connection state",
                 name: "a rejected credential marks the feed revoked and stops retrying") { expect in
            let setup = try storeWithListing()
            let listing = try setup.store.listings.find(id: setup.listingID)!
            let fetcher = StubFeedFetcher(responses: [
                listing.icalURL: .failure(
                    .credentialRejected(status: 400, detail: "Invalid Token")
                ),
            ])

            let report = await setup.store.makeImportService(fetcher: fetcher)
                .importFeed(for: listing)
            expect.equal(report.run.outcome, .disconnected,
                         "not a failure — a settled disconnection")

            let after = try setup.store.listings.find(id: setup.listingID)
            expect.equal(after?.connectionState, .revoked)
            expect.ok(after?.isImportable == false, "it must not be retried")
            expect.contains(after?.connectionDetail ?? "", "no longer accepts")

            // A second attempt does not even reach the network.
            let emptyFetcher = StubFeedFetcher(texts: [:])
            let second = await setup.store.makeImportService(fetcher: emptyFetcher)
                .importFeed(for: after!)
            expect.equal(second.run.outcome, .disconnected)
            expect.contains(second.run.errorMessage ?? "", "no longer accepts")
        },

        TestCase(group: "Connection state",
                 name: "a server error stays retryable") { expect in
            let setup = try storeWithListing()
            let listing = try setup.store.listings.find(id: setup.listingID)!
            let fetcher = StubFeedFetcher(responses: [
                listing.icalURL: .failure(.httpError(503)),
            ])
            let report = await setup.store.makeImportService(fetcher: fetcher)
                .importFeed(for: listing)
            expect.equal(report.run.outcome, .failure)

            let after = try setup.store.listings.find(id: setup.listingID)
            expect.equal(after?.connectionState, .failing)
            expect.ok(after?.isImportable == true, "a transient failure keeps being retried")
        },

        TestCase(group: "Connection state",
                 name: "a working import restores the connection") { expect in
            let setup = try storeWithListing(state: .failing)
            let listing = try setup.store.listings.find(id: setup.listingID)!
            let fetcher = StubFeedFetcher(texts: [listing.icalURL: Fixtures.bookingReservation])
            let report = await setup.store.makeImportService(fetcher: fetcher)
                .importFeed(for: listing)
            expect.equal(report.run.outcome, .success)
            expect.equal(
                try setup.store.listings.find(id: setup.listingID)?.connectionState, .connected
            )
        },

        // --- 2. Configuration history is preserved --------------------------

        TestCase(group: "Connection state",
                 name: "connection history survives a revocation") { expect in
            let setup = try storeWithListing()
            try setup.store.listings.setConnectionState(
                listingID: setup.listingID, to: .connected, detail: "first import"
            )
            try setup.store.listings.setConnectionState(
                listingID: setup.listingID, to: .revoked,
                detail: "Invalid Token", httpStatus: 400, actor: "import"
            )

            let history = try setup.store.listings.connectionHistory(listingID: setup.listingID)
            expect.ok(history.count >= 2)
            expect.equal(history.first?.toState, .revoked)
            expect.equal(history.first?.httpStatus, 400)
            expect.contains(history.first?.line ?? "", "400")

            // The listing itself, its label and its credential reference remain.
            let listing = try setup.store.listings.find(id: setup.listingID)
            expect.contains(listing?.label ?? "", "17482435")
            expect.ok(listing != nil, "the configuration is kept, not deleted")
            expect.equal(try setup.store.listings.disconnected().count, 1)
        },

        // --- The safeguard that matters ------------------------------------

        TestCase(group: "Connection state",
                 name: "a disconnected feed never authorises reopening dates") { expect in
            let published = SnapshotEntry(
                uid: "vrc-block-1", startDay: day(2026, 12, 10), endDay: day(2026, 12, 15),
                summary: "Not available"
            )
            // The owner approved a reopen — ordinarily a deliberate cause that
            // would be allowed through with approval.
            let reopen = AvailabilityDecision(
                id: 1, propertyID: 1, destination: .vrbo, action: .unblock,
                startDay: day(2026, 12, 10), endDay: day(2026, 12, 15),
                status: .approved, publicationUID: "vrc-block-1", approvedAt: Date()
            )
            let proposed = CalendarFeedGenerator().generate(
                destination: .vrbo, propertyID: 1, propertyName: "P",
                sourceEvents: [], decisions: [reopen]
            )
            // ...but Booking.com is disconnected, so the picture is incomplete.
            let context = PublicationContext(
                listings: [
                    PlatformListing(id: 1, propertyID: 1, platform: .vrbo, label: "V",
                                    lastSyncAt: Date(), connectionState: .connected),
                    PlatformListing(id: 2, propertyID: 1, platform: .bookingCom, label: "B",
                                    lastSyncAt: Date(), connectionState: .revoked),
                ],
                recentSyncRuns: [SyncRun(listingID: 1, outcome: .success)],
                decisions: [reopen], sourceEvents: []
            )
            let report = FeedPublicationSafety().assess(
                proposed: proposed,
                lastKnownGood: FeedSnapshot(
                    propertyID: 1, destination: .vrbo, revision: 1, entries: [published]
                ),
                context: context
            )

            expect.equal(report.verdict, .refused,
                         "a disconnection must not license putting nights back on sale")
            expect.ok(report.causes.contains {
                if case .disconnectedFeed = $0 { return true }; return false
            })
            let disconnection = report.causes.first {
                if case .disconnectedFeed = $0 { return true }; return false
            }
            expect.ok(disconnection?.permitsAutomaticPublication == false)
            expect.ok(disconnection?.isDeliberate == false,
                      "somebody caused it, but it is not a decision to reopen")
            expect.contains(report.reasons.joined(separator: " "), "back on sale")
        },

        TestCase(group: "Connection state",
                 name: "a disconnection is reported as such, not as a generic failure") { expect in
            let context = PublicationContext(
                listings: [
                    PlatformListing(id: 1, propertyID: 1, platform: .bookingCom, label: "B",
                                    lastSyncAt: Date().addingTimeInterval(-90 * 3_600),
                                    connectionState: .revoked),
                ],
                recentSyncRuns: [], decisions: [], sourceEvents: []
            )
            let proposed = CalendarFeedGenerator().generate(
                destination: .vrbo, propertyID: 1, propertyName: "P",
                sourceEvents: [], decisions: []
            )
            let report = FeedPublicationSafety().assess(
                proposed: proposed,
                lastKnownGood: FeedSnapshot(
                    propertyID: 1, destination: .vrbo, revision: 1,
                    entries: [SnapshotEntry(uid: "u", startDay: day(2026, 12, 10),
                                            endDay: day(2026, 12, 15), summary: "x")]
                ),
                context: context
            )
            // Despite being 90 hours old, it is described as disconnected
            // rather than merely stale — the accurate problem.
            expect.ok(report.causes.contains {
                if case .disconnectedFeed = $0 { return true }; return false
            })
            expect.ok(!report.causes.contains {
                if case .staleInboundFeed = $0 { return true }; return false
            }, "a disconnected feed is not described as stale")
            expect.equal(report.verdict, .refused)
        },

        TestCase(group: "Connection state",
                 name: "an owner disconnection behaves the same way") { expect in
            let state = FeedConnectionState.disconnectedByOwner
            expect.ok(!state.shouldAttemptImport)
            expect.ok(state.isDisconnected)
            expect.ok(state.nextStep == nil, "nothing is required of the owner")
            expect.contains(state.explanation, "turned this feed off")
        },

        TestCase(group: "Connection state", name: "every state says what it means") { expect in
            for state in FeedConnectionState.allCases {
                expect.ok(!state.displayName.isEmpty)
                expect.ok(!state.explanation.isEmpty)
            }
            expect.ok(FeedConnectionState.revoked.nextStep?.contains("fresh export URL") == true)
            expect.ok(!FeedConnectionState.revoked.shouldAttemptImport)
            expect.ok(FeedConnectionState.connected.shouldAttemptImport)
            expect.ok(FeedConnectionState.failing.shouldAttemptImport,
                      "a transient problem keeps being retried")
        },

        // --- Existing data is untouched -------------------------------------

        TestCase(group: "Connection state",
                 name: "revoking a feed does not touch events or classifications") { expect in
            let setup = try storeWithListing()
            try setup.store.events.upsert(CalendarEvent(
                listingID: setup.listingID, eventKey: "k", uid: "k", platform: .bookingCom,
                summary: "CLOSED - Not available",
                checkIn: day(2027, 7, 1), checkOut: day(2027, 7, 5)
            ))
            try setup.store.classifications.save(EventClassification(
                eventKey: "k", kind: .cancellationBlock, confidence: .high,
                source: .manual, needsReview: false, note: "mine"
            ))

            let listing = try setup.store.listings.find(id: setup.listingID)!
            let fetcher = StubFeedFetcher(responses: [
                listing.icalURL: .failure(.credentialRejected(status: 400, detail: "Invalid Token")),
            ])
            _ = await setup.store.makeImportService(fetcher: fetcher).importFeed(for: listing)

            expect.equal(try setup.store.events.count(), 1, "events kept")
            let classification = try setup.store.classifications.find(eventKey: "k")
            expect.equal(classification?.kind, .cancellationBlock)
            expect.equal(classification?.source, .manual)
            expect.equal(classification?.note, "mine")
        },
    ] }
}
