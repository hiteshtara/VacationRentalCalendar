import Foundation
import VRCCore

/// A cancelled Keychain authorization must not disable a calendar.
///
/// What happened on 2026-11-10 at 23:05. A backup script launched a second
/// copy of the installed app to read credential health while the running app's
/// hourly auto-refresh fired. Two code objects asked for authorization on the
/// same items at the same second, and two of the three reads came back
/// `OSStatus -128`. `ImportService` filed that under "this credential cannot
/// be read" and latched `credentialUnreadable`, which `shouldAttemptImport`
/// refuses — so Airbnb and Vrbo stopped importing permanently, from a
/// condition that lasted one second. Booking.com, read at the same instant,
/// succeeded with HTTP 200, which is the proof that nothing was wrong with the
/// Keychain or with any credential.
///
/// `-128` is `errSecUserCanceled`, and the Security framework returns it both
/// when a person dismisses the dialog and when macOS cannot present one at
/// all. **The API does not distinguish those two.** So it cannot be read as a
/// verdict about the credential, and the only safe reading is "ask again
/// later". The codes that genuinely mean "this code object is refused" are
/// separate, and are classified separately here.
///
/// This is the same class of defect as the four-second Keychain deadline: a
/// transient condition recorded as a permanent one. That one silenced three
/// feeds for an hour; this one silenced two until a human noticed.
public enum KeychainCancellationTests {

    /// Fails every read with one fixed status, then succeeds.
    final class StatusFailingStore: FeedCredentialStore, @unchecked Sendable {
        let status: OSStatus
        let value: String
        var failuresLeft: Int
        private(set) var reads = 0
        init(status: OSStatus, url: String, failures: Int) {
            self.status = status; self.value = url; self.failuresLeft = failures
        }
        var storageDescription: String { "test double" }
        func save(url: String, reference: String) throws {}
        func delete(reference: String) throws {}
        func exists(reference: String) -> Bool { true }
        func url(reference: String) throws -> String? {
            reads += 1
            if failuresLeft > 0 {
                failuresLeft -= 1
                throw FeedCredentialError.keychainFailure(status, "read")
            }
            return value
        }
    }

    static func store(
        credentials: FeedCredentialStore, database: Database
    ) throws -> (store: RentalStore, listingID: Int64) {
        let store = try RentalStore(database: database, credentials: credentials)
        let property = try store.properties.insert(Property(name: "39 G Street"))
        let listing = try store.listings.insert(PlatformListing(
            propertyID: property.id!, platform: .vrbo, label: "Vrbo — 39 G Street",
            credentialRef: "vrbo-v6", connectionState: .connected))
        return (store, listing.id!)
    }

    static func fetcher(_ url: String) -> StubFeedFetcher {
        StubFeedFetcher(texts: [url: Fixtures.airbnbConfirmedBooking])
    }

    public static var cases: [TestCase] { [

        // MARK: - Classification

        TestCase(group: "Keychain cancellation",
                 name: "-128 is classified as a cancelled authorization, and is retryable") { expect in
            let failure = KeychainFailure.of(-128)
            expect.equal(failure, .authorizationCancelled)
            expect.ok(failure.isRetryable, "a cancelled prompt says nothing about the credential")
            expect.ok(failure.involvedAuthorization,
                      "it is the kind of failure a prompt produces")
        },

        TestCase(group: "Keychain cancellation",
                 name: "a cancelled authorization is NOT reported as explicit denial") { expect in
            // The distinction the requirement asks for, stated honestly: the
            // Security framework returns -128 for a dismissed dialog AND for
            // one it could not show. Anything claiming to tell those apart
            // would be inventing information.
            expect.ok(!KeychainFailure.of(-128).isSettledRefusal,
                      "-128 must never be treated as a settled answer")
            expect.contains(KeychainFailure.of(-128).explanation, "cancelled")
        },

        TestCase(group: "Keychain cancellation",
                 name: "a missing-interaction failure is retryable too") { expect in
            // errSecInteractionNotAllowed / errSecInteractionRequired: a prompt
            // was needed and could not be shown. Unambiguously transient.
            for status: OSStatus in [-25308, -25315] {
                let failure = KeychainFailure.of(status)
                expect.equal(failure, .interactionUnavailable, "status \(status)")
                expect.ok(failure.isRetryable)
                expect.ok(!failure.isSettledRefusal)
            }
        },

        TestCase(group: "Keychain cancellation",
                 name: "an access-list refusal is settled and NOT retryable") { expect in
            // errSecAuthFailed. This is the real "the item's access list names
            // another code object" case, where retrying cannot succeed and each
            // attempt holds the Keychain for the rest of the process.
            let failure = KeychainFailure.of(-25293)
            expect.equal(failure, .accessDenied)
            expect.ok(!failure.isRetryable)
            expect.ok(failure.isSettledRefusal, "re-entering the URL is the only fix")
        },

        TestCase(group: "Keychain cancellation",
                 name: "dark wake is retryable — it is the absence of a screen") { expect in
            // -25320, errSecInDarkWake: "In dark wake, no UI possible". The Mac
            // woke under Power Nap to run the hourly refresh, there was no
            // screen to show an authorization dialog on, and the read failed.
            //
            // It happened overnight on 2026-11-11 at 00:49 and latched all
            // three feeds into credentialUnreadable, which is never retried —
            // so thirteen hours of hourly refreshes recorded nothing but
            // disconnections. It says nothing whatever about the credential.
            let failure = KeychainFailure.of(-25320)
            expect.equal(failure, .interactionUnavailable)
            expect.ok(failure.isRetryable)
            expect.ok(!failure.isSettledRefusal)
        },

        TestCase(group: "Keychain cancellation",
                 name: "an UNRECOGNISED status is retryable, not a dead credential") { expect in
            // Reversing an earlier decision of mine. I defaulted unknown codes
            // to non-retryable on the reasoning that one might block and
            // poison the Keychain for the rest of the process. That risk is
            // real but it is already handled, by DeadlineFeedCredentialStore,
            // which bounds every read and reports a timeout as retryable.
            //
            // Meanwhile the cost of the conservative default is now measured:
            // it has silently disabled working feeds twice, from -128 and then
            // from -25320, both transient. "A transient condition must not be
            // recorded as a settled fact" has to apply to codes nobody has
            // enumerated yet, or the next unlisted code does it again.
            //
            // Only codes KNOWN to be settled now latch.
            let failure = KeychainFailure.of(-99_999)
            expect.equal(failure, .other(-99_999))
            expect.ok(failure.isRetryable, "the safe direction is to try again later")
            expect.ok(!failure.isSettledRefusal,
                      "and never to tell the owner their credential is broken")
        },

        TestCase(group: "Keychain cancellation",
                 name: "a missing entitlement is retryable — it is a build problem") { expect in
            // -34018. Nothing is wrong with the credential; the build is wrong.
            // Latching would mean a bad build permanently disconnected feeds
            // that a corrected build could read immediately.
            let failure = KeychainFailure.of(-34018)
            expect.ok(failure.isRetryable)
            expect.ok(!failure.isSettledRefusal)
        },

        TestCase(group: "Keychain cancellation",
                 name: "only an access-list refusal and a missing item still latch") { expect in
            // The complete list of non-retryable codes, asserted so that
            // widening it again is a deliberate act with a test to change.
            expect.ok(!KeychainFailure.of(-25293).isRetryable, "errSecAuthFailed")
            expect.ok(!KeychainFailure.of(-25300).isRetryable, "errSecItemNotFound")
            for status: OSStatus in [-128, -25308, -25315, -25320, -34018, -1, -99_999] {
                expect.ok(KeychainFailure.of(status).isRetryable, "\(status) must retry")
            }
        },

        // MARK: - Requirement 4: a cancellation cannot permanently disable imports

        TestCase(group: "Keychain cancellation",
                 name: "a cancelled authorization leaves the feed retryable, not unreadable") { expect in
            let credentials = StatusFailingStore(
                status: -128, url: "https://a.test/f.ics", failures: 1)
            let setup = try store(credentials: credentials, database: try Database.inMemory())
            let report = await setup.store.makeImportService(fetcher: fetcher("https://a.test/f.ics"))
                .importFeed(for: try setup.store.listings.find(id: setup.listingID)!)

            expect.equal(report.run.outcome, .failure,
                         "a failure, but not a disconnection")
            expect.equal(try setup.store.listings.find(id: setup.listingID)?.connectionState,
                         .failing, "NOT credentialUnreadable — this is the regression")
            expect.ok(try setup.store.listings.find(id: setup.listingID)!
                        .connectionState.shouldAttemptImport,
                      "and the next refresh is still willing to try")
        },

        TestCase(group: "Keychain cancellation",
                 name: "the very next refresh after a cancellation succeeds") { expect in
            // Requirement 4 end to end: nobody re-enters anything, nobody
            // clears a latch, and the calendar comes back on its own.
            let credentials = StatusFailingStore(
                status: -128, url: "https://a.test/f.ics", failures: 1)
            let setup = try store(credentials: credentials, database: try Database.inMemory())
            let feed = fetcher("https://a.test/f.ics")
            _ = await setup.store.makeImportService(fetcher: feed)
                .importFeed(for: try setup.store.listings.find(id: setup.listingID)!)

            let report = await setup.store.makeImportService(fetcher: feed)
                .importFeed(for: try setup.store.listings.find(id: setup.listingID)!)
            expect.equal(report.run.outcome, .success)
            expect.equal(try setup.store.listings.find(id: setup.listingID)?.connectionState,
                         .connected, "recovered with no human involved")
        },

        TestCase(group: "Keychain cancellation",
                 name: "repeated cancellations still never latch") { expect in
            // There is no number of cancellations that becomes evidence about
            // the credential. Five in a row, then it works.
            let credentials = StatusFailingStore(
                status: -128, url: "https://a.test/f.ics", failures: 5)
            let setup = try store(credentials: credentials, database: try Database.inMemory())
            let feed = fetcher("https://a.test/f.ics")
            for attempt in 1...5 {
                _ = await setup.store.makeImportService(fetcher: feed)
                    .importFeed(for: try setup.store.listings.find(id: setup.listingID)!)
                expect.ok(try setup.store.listings.find(id: setup.listingID)!
                            .connectionState.shouldAttemptImport,
                          "still retryable after cancellation \(attempt)")
            }
            expect.equal(
                await setup.store.makeImportService(fetcher: feed)
                    .importFeed(for: try setup.store.listings.find(id: setup.listingID)!)
                    .run.outcome,
                .success)
        },

        TestCase(group: "Keychain cancellation",
                 name: "an access-list refusal still latches, as it must") { expect in
            // The relaxation must not swallow the real case. -25293 cannot
            // succeed on retry and each attempt blocks the Keychain, so it
            // still stops and still asks for the URL again.
            let credentials = StatusFailingStore(
                status: -25293, url: "https://a.test/f.ics", failures: 1)
            let setup = try store(credentials: credentials, database: try Database.inMemory())
            let report = await setup.store.makeImportService(fetcher: fetcher("https://a.test/f.ics"))
                .importFeed(for: try setup.store.listings.find(id: setup.listingID)!)
            expect.equal(report.run.outcome, .disconnected)
            expect.equal(try setup.store.listings.find(id: setup.listingID)?.connectionState,
                         .credentialUnreadable)
        },

        TestCase(group: "Keychain cancellation",
                 name: "a cancelled authorization withdraws nothing") { expect in
            let credentials = StatusFailingStore(
                status: -128, url: "https://a.test/f.ics", failures: 0)
            let setup = try store(credentials: credentials, database: try Database.inMemory())
            let feed = fetcher("https://a.test/f.ics")
            _ = await setup.store.makeImportService(fetcher: feed)
                .importFeed(for: try setup.store.listings.find(id: setup.listingID)!)
            let before = try setup.store.events.allActive().count
            expect.ok(before > 0, "precondition")

            credentials.failuresLeft = 1
            let report = await setup.store.makeImportService(fetcher: feed)
                .importFeed(for: try setup.store.listings.find(id: setup.listingID)!)
            expect.equal(report.run.eventsTombstoned, 0)
            expect.equal(try setup.store.events.allActive().count, before,
                         "a cancelled prompt must not look like an empty feed")
        },

        // MARK: - Requirement 1: no prompt storms

        TestCase(group: "Keychain cancellation",
                 name: "a second automatic read after a cancellation does not reach the Keychain") { expect in
            // Retryable must not mean "ask again immediately". After a
            // cancellation the wrapper holds off, so a Refresh all pass over
            // three feeds cannot produce three dialogs in a row.
            let backing = StatusFailingStore(
                status: -128, url: "https://a.test/f.ics", failures: 1)
            let gate = AuthorizationCooloffFeedCredentialStore(
                wrapping: backing, cooloff: 600, now: { Date(timeIntervalSince1970: 1_000) })

            do { _ = try gate.url(reference: "vrbo-v6"); expect.fail("should have thrown") }
            catch { }
            expect.equal(backing.reads, 1)

            do {
                _ = try gate.url(reference: "vrbo-v6")
                expect.fail("the second read should have been suppressed")
            } catch let error as FeedCredentialError {
                guard case .authorizationSuppressed = error else {
                    return expect.fail("got \(error)")
                }
            }
            expect.equal(backing.reads, 1, "the Keychain was not touched again")
        },

        TestCase(group: "Keychain cancellation",
                 name: "the hold-off expires on its own") { expect in
            let backing = StatusFailingStore(
                status: -128, url: "https://a.test/f.ics", failures: 1)
            var clock = Date(timeIntervalSince1970: 1_000)
            let gate = AuthorizationCooloffFeedCredentialStore(
                wrapping: backing, cooloff: 600, now: { clock })
            _ = try? gate.url(reference: "vrbo-v6")

            clock = Date(timeIntervalSince1970: 1_000 + 601)
            expect.equal(try gate.url(reference: "vrbo-v6"), "https://a.test/f.ics")
            expect.equal(backing.reads, 2, "it did try again once the hold-off passed")
        },

        TestCase(group: "Keychain cancellation",
                 name: "a suppressed read is itself retryable, never a disconnection") { expect in
            // The suppression is our own decision, not the platform's answer.
            // It must never be mistaken for evidence about the credential.
            expect.ok(FeedCredentialError
                        .authorizationSuppressed(retryAt: Date())
                        .isRetryableCredentialFailure)
        },

        TestCase(group: "Keychain cancellation",
                 name: "the owner asking explicitly clears the hold-off") { expect in
            // A prompt is tolerable when the owner just asked for a refresh;
            // it is not tolerable on a timer. So an explicit click bypasses it.
            let backing = StatusFailingStore(
                status: -128, url: "https://a.test/f.ics", failures: 1)
            let gate = AuthorizationCooloffFeedCredentialStore(
                wrapping: backing, cooloff: 600, now: { Date(timeIntervalSince1970: 1_000) })
            _ = try? gate.url(reference: "vrbo-v6")
            expect.equal(backing.reads, 1)

            gate.allowRetry(reference: "vrbo-v6")
            expect.equal(try gate.url(reference: "vrbo-v6"), "https://a.test/f.ics")
            expect.equal(backing.reads, 2)
        },

        TestCase(group: "Keychain cancellation",
                 name: "a settled refusal is not held off — it is reported at once") { expect in
            // Holding off on -25293 would only delay the message the owner
            // needs, which is "enter the URL again".
            let backing = StatusFailingStore(
                status: -25293, url: "https://a.test/f.ics", failures: 2)
            let gate = AuthorizationCooloffFeedCredentialStore(
                wrapping: backing, cooloff: 600, now: { Date(timeIntervalSince1970: 1_000) })
            _ = try? gate.url(reference: "vrbo-v6")
            _ = try? gate.url(reference: "vrbo-v6")
            expect.equal(backing.reads, 2, "both attempts reached the Keychain")
        },

        TestCase(group: "Keychain cancellation",
                 name: "presence checks are never held off, because they cannot prompt") { expect in
            let backing = StatusFailingStore(
                status: -128, url: "https://a.test/f.ics", failures: 1)
            let gate = AuthorizationCooloffFeedCredentialStore(
                wrapping: backing, cooloff: 600, now: { Date(timeIntervalSince1970: 1_000) })
            _ = try? gate.url(reference: "vrbo-v6")
            expect.ok(gate.exists(reference: "vrbo-v6"),
                      "an attribute-only check stays available during a hold-off")
        },

        TestCase(group: "Keychain cancellation",
                 name: "a successful read clears any hold-off") { expect in
            let backing = StatusFailingStore(
                status: -128, url: "https://a.test/f.ics", failures: 0)
            let gate = AuthorizationCooloffFeedCredentialStore(
                wrapping: backing, cooloff: 600, now: { Date(timeIntervalSince1970: 1_000) })
            expect.equal(try gate.url(reference: "vrbo-v6"), "https://a.test/f.ics")
            expect.equal(try gate.url(reference: "vrbo-v6"), "https://a.test/f.ics")
            expect.equal(backing.reads, 2, "nothing was suppressed")
        },
    ] }
}
