import Foundation
import VRCCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The client's job is to be honest about uncertainty. A decision the owner
/// approved must not silently become two decisions, and must not silently
/// become none.
public enum CloudSyncClientTests {

    final class FakeTransport: CloudSyncClient.Transport, @unchecked Sendable {
        private let lock = NSLock()
        var scripted: [(status: Int, body: [String: Any])]
        var requests: [URLRequest] = []
        var throwOnce: Error?

        init(_ scripted: [(status: Int, body: [String: Any])] = []) { self.scripted = scripted }

        func send(_ request: URLRequest) throws -> CloudSyncClient.Response {
            lock.lock()
            requests.append(request)
            if let error = throwOnce { throwOnce = nil; lock.unlock(); throw error }
            let next = scripted.isEmpty ? (200, [String: Any]()) : scripted.removeFirst()
            lock.unlock()
            return CloudSyncClient.Response(
                statusCode: next.0,
                body: (try? JSONSerialization.data(withJSONObject: next.1)) ?? Data("{}".utf8))
        }
    }

    static func client(_ transport: FakeTransport) -> CloudSyncClient {
        CloudSyncClient(
            configuration: .init(endpoint: URL(string: "https://api.test")!, region: "us-east-1"),
            signer: SigV4Signer(accessKeyID: "AKIATEST", secretAccessKey: "secret",
                                region: "us-east-1", service: "execute-api"),
            transport: transport)
    }

    static func approved(_ uid: String = "vrc-client-1") -> AvailabilityDecision {
        AvailabilityDecision(
            id: 1, propertyID: 1, destination: .vrbo, action: .block,
            startDay: DayMath.day(2026, 12, 10), endDay: DayMath.day(2026, 12, 17),
            status: .approved, publicationUID: uid, approvedAt: Date())
    }

    public static var cases: [TestCase] { [

        // --- Reads ---

        TestCase(group: "Cloud client", name: "status is read and reported") { expect in
            let transport = FakeTransport([(200, [
                "liveSourceEvents": 7, "approvedDecisions": 2, "publishedDecisions": 0,
                "openConflicts": 1, "lastSuccessfulImport": "2026-11-09T08:00:00Z",
                "outboundEnabled": false, "remoteSynchronised": false,
                "failingSources": ["booking_com": "token revoked"],
                "staleSources": ["vrbo": "last success 9h ago"],
            ])])
            let status = try client(transport).status()
            expect.equal(status.liveSourceEvents, 7)
            expect.equal(status.approvedDecisions, 2)
            expect.equal(status.failingSources["booking_com"], "token revoked")
            expect.equal(status.staleSources["vrbo"], "last success 9h ago")
            expect.ok(!status.isHealthy, "a failing or stale source is not healthy")
        },

        TestCase(group: "Cloud client",
                 name: "remoteSynchronised is never inferred when absent") { expect in
            // A service that omits the field must not be read as synchronised.
            let transport = FakeTransport([(200, ["liveSourceEvents": 3])])
            let status = try client(transport).status()
            expect.ok(!status.remoteSynchronised,
                      "absence must mean false, never true")
            expect.ok(!status.outboundEnabled)
        },

        TestCase(group: "Cloud client", name: "every request is signed") { expect in
            let transport = FakeTransport([(200, ["liveSourceEvents": 0])])
            _ = try client(transport).status()
            let authorisation = transport.requests.first?
                .value(forHTTPHeaderField: "Authorization") ?? ""
            expect.ok(authorisation.hasPrefix("AWS4-HMAC-SHA256"),
                      "SigV4, so the gateway's AWS_IAM authoriser accepts it")
            expect.ok(authorisation.contains("execute-api"),
                      "scoped to the API service, not S3")
        },

        TestCase(group: "Cloud client", name: "a rejected credential is distinguished") { expect in
            for status in [401, 403] {
                let transport = FakeTransport([(status, ["error": "no"])])
                do {
                    _ = try client(transport).status()
                    expect.fail("must throw")
                } catch let error as CloudSyncClient.CloudError {
                    expect.equal(error, .unauthorised)
                }
            }
        },

        TestCase(group: "Cloud client",
                 name: "an unavailable service is an error, not an empty answer") { expect in
            // The dangerous failure: showing zero conflicts because the
            // service could not be reached.
            let transport = FakeTransport([(503, ["detail": "database unavailable"])])
            do {
                _ = try client(transport).status()
                expect.fail("must throw rather than return zeros")
            } catch let error as CloudSyncClient.CloudError {
                if case .serviceUnavailable = error {} else { expect.fail("wrong: \(error)") }
            }
        },

        TestCase(group: "Cloud client", name: "availability intervals are decoded") { expect in
            let transport = FakeTransport([(200, ["blocking": [
                ["property": "p1", "from": "2026-12-10", "to": "2026-12-17",
                 "basis": "reservation", "source": "airbnb"],
            ]])])
            let intervals = try client(transport).availability()
            expect.equal(intervals.count, 1)
            expect.equal(intervals[0].basis, "reservation")
            expect.equal(intervals[0].to, "2026-12-17")
        },

        // --- Idempotency ---

        TestCase(group: "Cloud client",
                 name: "the idempotency key is derived from the decision, not random") { expect in
            // A random key per attempt would defeat the entire mechanism.
            let a = CloudSyncClient.idempotencyKey(for: approved())
            let b = CloudSyncClient.idempotencyKey(for: approved())
            expect.equal(a, b, "the same decision yields the same key")
            var different = approved()
            different.endDay = DayMath.day(2026, 12, 18)
            expect.ok(CloudSyncClient.idempotencyKey(for: different) != a,
                      "a different range is a different decision")
        },

        TestCase(group: "Cloud client", name: "the key is sent as a signed header") { expect in
            let transport = FakeTransport([(200, ["publicationUID": "vrc-client-1"])])
            _ = try client(transport).submit(decision: approved())
            let request = transport.requests.first
            expect.equal(request?.value(forHTTPHeaderField: "Idempotency-Key"),
                         CloudSyncClient.idempotencyKey(for: approved()))
            let authorisation = request?.value(forHTTPHeaderField: "Authorization") ?? ""
            expect.ok(authorisation.contains("idempotency-key"),
                      "signed, so it cannot be stripped or altered in transit")
        },

        // --- Only approved decisions ---

        TestCase(group: "Cloud client", name: "an unapproved decision is never submitted") { expect in
            for status in [AvailabilityStatus.draft, .validated, .awaitingApproval, .cancelled] {
                var decision = approved()
                decision.status = status
                let transport = FakeTransport([(200, [:])])
                let outcome = try client(transport).submit(decision: decision)
                if case .rejected = outcome {} else {
                    expect.fail("\(status.rawValue) must be rejected locally")
                }
                expect.equal(transport.requests.count, 0,
                             "and must not reach the network at all")
            }
        },

        TestCase(group: "Cloud client",
                 name: "a submission never asks for publication") { expect in
            let transport = FakeTransport([(200, ["publicationUID": "x"])])
            _ = try client(transport).submit(decision: approved())
            let body = transport.requests.first?.httpBody ?? Data()
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            expect.ok(object["publish"] as? Bool == false,
                      "submitting a decision is not a request to publish it")
        },

        // --- Uncertainty and reconciliation ---

        TestCase(group: "Cloud client", name: "a 5xx write is uncertain, not failed") { expect in
            let transport = FakeTransport([(500, ["error": "boom"])])
            let outcome = try client(transport).submit(decision: approved())
            if case .uncertain = outcome {} else { expect.fail("got \(outcome)") }
        },

        TestCase(group: "Cloud client", name: "a dropped connection on a write is uncertain") { expect in
            struct Dropped: Error {}
            let transport = FakeTransport()
            transport.throwOnce = Dropped()
            let outcome = try client(transport).submit(decision: approved())
            if case .uncertain = outcome {} else { expect.fail("got \(outcome)") }
        },

        TestCase(group: "Cloud client",
                 name: "an uncertain write that DID apply is reconciled, not repeated") { expect in
            // The case that would otherwise create a duplicate decision.
            let transport = FakeTransport([
                (500, ["error": "boom"]),          // submit: uncertain
                (200, ["found": true]),            // reconcile: it did land
            ])
            let outcome = try client(transport).submitReconciling(decision: approved())
            expect.equal(outcome, .alreadyApplied(id: "vrc-client-1"))
            expect.equal(transport.requests.count, 2,
                         "it reconciled and stopped, rather than submitting again")
        },

        TestCase(group: "Cloud client",
                 name: "an uncertain write that did NOT apply is retried") { expect in
            let transport = FakeTransport([
                (500, ["error": "boom"]),              // submit: uncertain
                (200, ["found": false]),               // reconcile: nothing landed
                (200, ["publicationUID": "vrc-client-1"]),  // retry: applied
            ])
            let outcome = try client(transport).submitReconciling(decision: approved())
            expect.equal(outcome, .applied(id: "vrc-client-1"))
            expect.equal(transport.requests.count, 3)
        },

        TestCase(group: "Cloud client",
                 name: "a persistently uncertain write reports NOT applied") { expect in
            // The honest ending: the owner is told it did not happen, rather
            // than being left to assume either way.
            let transport = FakeTransport([
                (500, [:]), (200, ["found": false]),
                (500, [:]), (200, ["found": false]),
                (500, [:]), (200, ["found": false]),
            ])
            let outcome = try client(transport).submitReconciling(decision: approved())
            guard case .uncertain(let reason) = outcome else {
                expect.fail("got \(outcome)"); return
            }
            expect.ok(reason.contains("NOT been applied"),
                      "says plainly that nothing was applied")
            expect.ok(reason.contains("nothing was published"))
        },

        TestCase(group: "Cloud client", name: "a 409 is already-applied, not an error") { expect in
            let transport = FakeTransport([(409, ["publicationUID": "vrc-client-1"])])
            let outcome = try client(transport).submit(decision: approved())
            expect.equal(outcome, .alreadyApplied(id: "vrc-client-1"))
        },

        TestCase(group: "Cloud client", name: "a 400 is a rejection and is not retried") { expect in
            let transport = FakeTransport([(400, ["error": "overlaps a confirmed reservation"])])
            let outcome = try client(transport).submitReconciling(decision: approved())
            guard case .rejected(let reason) = outcome else {
                expect.fail("got \(outcome)"); return
            }
            expect.ok(reason.contains("overlaps"))
            expect.equal(transport.requests.count, 1, "a rejection is final")
        },
    ] }
}
