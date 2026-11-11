import Foundation
import VRCCore

/// The narrow transfer path for a secret the application cannot read.
///
/// The Booking.com outbound feed token's ACL trusts only `/usr/bin/security`
/// and its partition is `apple-tool:`. Unlike a feed URL it cannot be
/// re-entered, because Booking.com is already subscribed to the URL containing
/// it — re-issuing means handing the platform a new URL. So it is handed over
/// by the tool that is trusted, in memory, under the same reference.
///
/// Every value here is an obvious fake. No live token is involved.
public enum SecretImportTests {

    static let token = "not-a-real-token-0123456789abcdef"
    static let reference = "rehearsal-feed-key-1-booking_com-v1"

    public static var cases: [TestCase] { [

        TestCase(group: "Secret import",
                 name: "a secret is stored under the same reference and verified") { expect in
            let store = InMemoryFeedCredentialStore()
            let report = try SecretImport.perform(
                reference: reference, value: token, into: store)
            expect.equal(report.reference, reference, "the name is never altered")
            expect.ok(report.verified)
            expect.equal(try store.url(reference: reference), token)
        },

        TestCase(group: "Secret import",
                 name: "the report carries a digest and never the value") { expect in
            let store = InMemoryFeedCredentialStore()
            let report = try SecretImport.perform(
                reference: reference, value: token, into: store)
            expect.ok(!report.description.contains(token),
                      "the value must not appear in anything printable")
            expect.equal(report.digest.count, 12)
            expect.equal(report.digest, SecretImport.digest(token),
                         "and it is a digest of what was actually stored")
            expect.contains(report.description, reference)
        },

        TestCase(group: "Secret import",
                 name: "an empty value is refused rather than written") { expect in
            // The failure that matters. If the upstream read produces nothing
            // — a cancelled prompt, a wrong reference — writing it would
            // destroy the credential while appearing to succeed.
            let store = InMemoryFeedCredentialStore()
            try store.save(url: token, reference: reference)
            for attempt in ["", "   ", "\n", "\t\n "] {
                do {
                    _ = try SecretImport.perform(
                        reference: reference, value: attempt, into: store)
                    expect.fail("an empty value was accepted")
                } catch let failure as SecretImport.Failure {
                    expect.equal(failure, .emptyValue(reference: reference))
                }
            }
            expect.equal(try store.url(reference: reference), token,
                         "the existing credential survived every attempt")
        },

        TestCase(group: "Secret import",
                 name: "surrounding whitespace is trimmed, the value is not") { expect in
            // `security -w` emits a trailing newline. Storing it would change
            // the token and break the feed.
            let store = InMemoryFeedCredentialStore()
            _ = try SecretImport.perform(
                reference: reference, value: "\n  \(token)  \n", into: store)
            expect.equal(try store.url(reference: reference), token)
        },

        TestCase(group: "Secret import",
                 name: "a refused write is reported without the value") { expect in
            let refusing = RefusingFeedCredentialStore()
            do {
                _ = try SecretImport.perform(
                    reference: reference, value: token, into: refusing)
                expect.fail("should have thrown")
            } catch let failure as SecretImport.Failure {
                let message = failure.errorDescription ?? ""
                expect.ok(!message.contains(token), "the value leaked into an error")
                expect.contains(message, reference)
            }
        },

        TestCase(group: "Secret import",
                 name: "a store that reads back something else fails verification") { expect in
            // Defends against a destination that silently stores nothing, or
            // stores it ungrouped where a later read finds a different item.
            let store = MisreadingFeedCredentialStore(returning: "something-else")
            do {
                _ = try SecretImport.perform(
                    reference: reference, value: token, into: store)
                expect.fail("should have thrown")
            } catch let failure as SecretImport.Failure {
                expect.equal(failure, .verificationFailed(reference: reference))
            }
        },

        TestCase(group: "Secret import",
                 name: "importing does not touch the legacy copy") { expect in
            // Rollback depends on the legacy entry being untouched, and this
            // path must not delete or re-home anything.
            let legacy = InMemoryFeedCredentialStore()
            try legacy.save(url: token, reference: reference)
            let modern = InMemoryFeedCredentialStore()
            _ = try SecretImport.perform(reference: reference, value: token, into: modern)
            expect.equal(try legacy.url(reference: reference), token,
                         "the legacy token is exactly where it was")
        },
    ] }

    /// Refuses every write.
    final class RefusingFeedCredentialStore: FeedCredentialStore, @unchecked Sendable {
        var storageDescription: String { "refusing" }
        func save(url: String, reference: String) throws {
            throw FeedCredentialError.keychainFailure(-34018, "add")
        }
        func url(reference: String) throws -> String? { nil }
        func delete(reference: String) throws {}
        func exists(reference: String) -> Bool { false }
    }

    /// Accepts writes but reads back the wrong thing.
    final class MisreadingFeedCredentialStore: FeedCredentialStore, @unchecked Sendable {
        let wrong: String
        init(returning wrong: String) { self.wrong = wrong }
        var storageDescription: String { "misreading" }
        func save(url: String, reference: String) throws {}
        func url(reference: String) throws -> String? { wrong }
        func delete(reference: String) throws {}
        func exists(reference: String) -> Bool { true }
    }
}
