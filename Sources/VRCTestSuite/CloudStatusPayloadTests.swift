import Foundation
import VRCCore

/// The payload is the only thing that crosses from the helper back to the GUI,
/// so its shape is a security boundary: it must round-trip, and it must never
/// be able to carry a secret, because no field holds one.
public enum CloudStatusPayloadTests {

    static func status() -> CloudSyncClient.Status {
        CloudSyncClient.Status(
            liveSourceEvents: 0, approvedDecisions: 0, publishedDecisions: 0,
            openConflicts: 0, lastSuccessfulImport: "never",
            outboundEnabled: false, remoteSynchronised: false,
            failingSources: [:], staleSources: [:])
    }

    static func intervals() -> [CloudSyncClient.BlockingInterval] {
        [CloudSyncClient.BlockingInterval(property: "39 G Street",
            from: "2027-07-01", to: "2027-07-08", basis: "reservation", source: "direct"),
         CloudSyncClient.BlockingInterval(property: "39 G Street",
            from: "2027-09-01", to: "2027-09-04", basis: "hold", source: "direct")]
    }

    public static var cases: [TestCase] { [

        TestCase(group: "Cloud payload",
                 name: "a reached payload round-trips through JSON") { expect in
            let payload = CloudStatusPayload.reached(status(), intervals: intervals())
            let text = payload.encoded()
            guard let decoded = CloudStatusPayload.decode(Data(text.utf8)) else {
                return expect.fail("did not decode")
            }
            expect.equal(decoded, payload)
            expect.equal(decoded.intervals.count, 2)
            expect.ok(decoded.ok)
        },

        TestCase(group: "Cloud payload",
                 name: "the encoded form is a single line",
                 requirement: "The GUI reads one JSON line from stdout") { expect in
            let text = CloudStatusPayload.reached(status(), intervals: intervals()).encoded()
            expect.ok(!text.contains("\n"), "no embedded newline")
        },

        TestCase(group: "Cloud payload",
                 name: "no field can carry a secret",
                 requirement: "Never return secret keys, tokens or feed URLs") { expect in
            // The exhaustive key set is asserted, so adding a field that could
            // hold a credential would fail this test until the list is updated
            // and a reviewer has looked at the new name.
            let text = CloudStatusPayload.reached(status(), intervals: intervals()).encoded()
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                as? [String: Any] ?? [:]
            let allowed: Set<String> = [
                "ok", "health", "message",
                "liveSourceEvents", "approvedDecisions", "publishedDecisions",
                "openConflicts", "lastSuccessfulImport", "outboundEnabled",
                "remoteSynchronised", "failingSources", "staleSources", "intervals",
            ]
            for key in object.keys {
                expect.ok(allowed.contains(key), "unexpected top-level field: \(key)")
            }
            for forbidden in ["secret", "accessKey", "token", "url", "credential", "password"] {
                expect.notContains(text.lowercased(), forbidden.lowercased())
            }
        },

        TestCase(group: "Cloud payload",
                 name: "garbage is rejected, not shown") { expect in
            expect.ok(CloudStatusPayload.decode(Data("not json".utf8)) == nil)
            expect.ok(CloudStatusPayload.decode(Data("{}".utf8)) == nil,
                      "a payload missing required fields does not decode")
        },

        TestCase(group: "Cloud payload",
                 name: "a failure payload is not ok and carries a message") { expect in
            let payload = CloudStatusPayload.failure(.unreachable, "Could not reach the AWS service.")
            let decoded = CloudStatusPayload.decode(Data(payload.encoded().utf8))
            expect.ok(decoded?.ok == false)
            expect.equal(decoded?.health, .unreachable)
            expect.ok(decoded?.intervals.isEmpty == true)
        },
    ] }
}
