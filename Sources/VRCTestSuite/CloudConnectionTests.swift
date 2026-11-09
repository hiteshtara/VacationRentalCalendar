import Foundation
import VRCCore

/// The connection layer's job is to tell the interface the truth about its own
/// configuration, including the two failures that are easy to confuse: nothing
/// has been set up yet, and something was set up but cannot be read.
public enum CloudConnectionTests {

    static func connection() throws -> (CloudConnection, RentalStore, InMemoryFeedCredentialStore) {
        let credentials = InMemoryFeedCredentialStore()
        let store = try RentalStore(database: Database.inMemory(), credentials: credentials)
        return (CloudConnection(settings: store.settings, credentials: credentials),
                store, credentials)
    }

    /// A credential store whose reads throw, standing in for the Keychain ACL
    /// refusing a rebuilt binary. That failure must not look like "not set up".
    final class UnreadableStore: FeedCredentialStore, @unchecked Sendable {
        var storageDescription: String { "unreadable" }
        struct Denied: Error {}
        func save(url: String, reference: String) throws {}
        func url(reference: String) throws -> String? { throw Denied() }
        func delete(reference: String) throws {}
        /// Presence never consults the ACL, so this stands in for a stored
        /// credential the running build is not allowed to read.
        func exists(reference: String) -> Bool { true }
    }

    public static var cases: [TestCase] { [

        TestCase(group: "Cloud connection",
                 name: "an unconfigured app names every missing part") { expect in
            let (connection, _, _) = try connection()
            guard case .notConfigured(let missing) = connection.availability() else {
                return expect.fail("expected notConfigured")
            }
            expect.equal(missing.count, 3, "endpoint, access key and secret are all missing")
            expect.ok(connection.makeClient() == nil, "no client without configuration")
        },

        TestCase(group: "Cloud connection",
                 name: "a missing credential is reported, not guessed at") { expect in
            let (connection, _, credentials) = try connection()
            try connection.setEndpoint("https://api.test", region: "us-east-1")
            try credentials.save(url: "AKIATEST", reference: CloudConnection.accessKeyReference)
            guard case .notConfigured(let missing) = connection.availability() else {
                return expect.fail("expected notConfigured with the secret absent")
            }
            expect.equal(missing, ["secret key"])
        },

        TestCase(group: "Cloud connection",
                 name: "full configuration yields a usable client") { expect in
            let (connection, _, _) = try connection()
            try connection.setEndpoint("https://api.test", region: "eu-west-2")
            try connection.setCredentials(accessKeyID: "AKIATEST", secretAccessKey: "secret")
            guard case .configured(let endpoint, let region) = connection.availability() else {
                return expect.fail("expected configured")
            }
            expect.equal(endpoint.absoluteString, "https://api.test")
            expect.equal(region, "eu-west-2")
            expect.ok(connection.makeClient() != nil, "a client is built")
        },

        TestCase(group: "Cloud connection",
                 name: "a non-HTTPS endpoint is refused") { expect in
            let (connection, _, _) = try connection()
            do {
                try connection.setEndpoint("http://api.test")
                expect.fail("plain HTTP should be refused — the request carries a signature")
            } catch {
                expect.ok(true, "refused")
            }
            guard case .notConfigured = connection.availability() else {
                return expect.fail("the refused endpoint must not have been stored")
            }
        },

        TestCase(group: "Cloud connection",
                 name: "an insecure endpoint stored by another route is still refused",
                 requirement: "A signed request must not travel over http") { expect in
            let (connection, store, credentials) = try connection()
            try connection.setCredentials(accessKeyID: "AKIATEST", secretAccessKey: "secret")
            _ = credentials
            // Written straight to app_settings, bypassing setEndpoint.
            try store.settings.set(CloudConnection.endpointSettingKey, "http://api.test")
            guard case .insecureEndpoint = connection.availability() else {
                return expect.fail("expected insecureEndpoint")
            }
            expect.ok(connection.makeClient() == nil, "and no client is built from it")
        },

        TestCase(group: "Cloud connection",
                 name: "an unreadable credential is distinguished from an absent one",
                 requirement: "Keychain ACL failures need re-entry, not setup") { expect in
            let credentials = InMemoryFeedCredentialStore()
            let store = try RentalStore(database: Database.inMemory(), credentials: credentials)
            let connection = CloudConnection(
                settings: store.settings, credentials: UnreadableStore())
            try connection.setEndpoint("https://api.test")
            guard case .credentialUnreadable(let detail) = connection.availability() else {
                return expect.fail("expected credentialUnreadable, not notConfigured")
            }
            expect.ok(!detail.isEmpty, "the reason is carried through")
            expect.ok(connection.makeClient() == nil, "no client from an unreadable credential")
        },

        TestCase(group: "Cloud connection",
                 name: "presence does not read the secrets",
                 requirement: "Drawing the interface must not block on a Keychain prompt") { expect in
            let credentials = InMemoryFeedCredentialStore()
            let store = try RentalStore(database: Database.inMemory(), credentials: credentials)
            let connection = CloudConnection(
                settings: store.settings, credentials: UnreadableStore())
            try connection.setEndpoint("https://api.test")
            // The same store that makes availability() fail reports present
            // here, which is the whole point: launch must not touch the value.
            expect.ok(connection.presence().isConfigured,
                      "presence sees the credential without reading it")
            guard case .credentialUnreadable = connection.availability() else {
                return expect.fail("the full read still reports the refusal")
            }
        },

        TestCase(group: "Cloud connection",
                 name: "presence still names what is missing") { expect in
            let (connection, _, _) = try connection()
            try connection.setEndpoint("https://api.test")
            guard case .notConfigured(let missing) = connection.presence() else {
                return expect.fail("expected notConfigured")
            }
            expect.equal(missing, ["access key", "secret key"])
        },

        // --- What the interface shows ---

        TestCase(group: "Cloud connection",
                 name: "a snapshot never infers platform confirmation") { expect in
            let healthy = CloudSnapshot(
                health: .healthy,
                status: CloudSyncClient.Status(
                    liveSourceEvents: 7, approvedDecisions: 2, publishedDecisions: 1,
                    openConflicts: 0, lastSuccessfulImport: "2026-11-09T08:00:00Z",
                    outboundEnabled: false, remoteSynchronised: false,
                    failingSources: [:], staleSources: [:]),
                intervals: [], checkedAt: Date())
            // A clean request is not evidence a platform read the feed.
            expect.ok(!healthy.isRemoteSynchronised,
                      "a healthy service is still not platform confirmation")
            expect.equal(healthy.label, "Connected")
        },

        TestCase(group: "Cloud connection",
                 name: "an unreached service never reports as healthy") { expect in
            let snapshot = CloudSnapshot(health: .unreachable("connection refused"))
            expect.equal(snapshot.label, "connection refused")
            expect.ok(!snapshot.isRemoteSynchronised)
            expect.ok(!snapshot.outboundEnabled,
                      "outbound is only ON when the service says so")
        },

        TestCase(group: "Cloud connection",
                 name: "a stale source makes the snapshot degraded, not healthy",
                 requirement: "An indicator that can only say 'fine' is worse than none") { expect in
            let status = CloudSyncClient.Status(
                liveSourceEvents: 7, approvedDecisions: 0, publishedDecisions: 0,
                openConflicts: 0, lastSuccessfulImport: "2026-11-08T08:00:00Z",
                outboundEnabled: false, remoteSynchronised: false,
                failingSources: [:], staleSources: ["vrbo": "last success 30h ago"])
            expect.ok(!status.isHealthy, "a stale source is not health")
        },
    ] }
}
