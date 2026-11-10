import Foundation
import VRCCore

/// Regression tests for the SigV4 session-token fault.
///
/// The bug, found by the feed endpoint returning a flat 403 against real S3:
/// `S3ObjectStore` set `X-Amz-Security-Token` on the request but never asked
/// the signer to include it in `SignedHeaders`. S3 rejects any `x-amz-*`
/// header it receives that the signature does not cover. Secrets Manager
/// tolerates the same omission, which is why it went unnoticed — nothing else
/// in this project reads or writes S3 at runtime yet, so the first real S3
/// call was also the first time it could fail.
///
/// In Lambda the credentials are always temporary, so the header is always
/// present and the fault was unconditional there.
public enum SigningTests {

    /// Fixed inputs so a signature is reproducible.
    ///
    /// Deliberately NOT AWS's documentation example key. That value is public
    /// and harmless, but it matches `check-no-secrets.sh`'s
    /// `(AKIA|ASIA)[0-9A-Z]{16}` pattern, so committing it breaks the gate for
    /// everyone afterwards — and a scanner people learn to ignore is worse than
    /// no scanner. Short, obviously-fake values match the convention already
    /// used in CloudSyncClientTests.
    static let signer = SigV4Signer(
        accessKeyID: "AKIATEST", secretAccessKey: "not-a-real-secret",
        region: "us-east-1", service: "s3")
    static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    static func signedHeaders(
        of request: URLRequest
    ) -> [String] {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              let range = authorization.range(of: "SignedHeaders=") else { return [] }
        let rest = authorization[range.upperBound...]
        let list = rest.prefix(while: { $0 != "," })
        return list.split(separator: ";").map(String.init)
    }

    static func sign(sessionToken: String?, alsoSign: [String]) -> URLRequest {
        var request = URLRequest(
            url: URL(string: "https://bucket.s3.us-east-1.amazonaws.com/ical/x.ics")!)
        request.httpMethod = "GET"
        if let sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        try? signer.sign(&request, payload: Data(), now: fixedDate, alsoSign: alsoSign)
        return request
    }

    public static var cases: [TestCase] { [

        TestCase(group: "Signing",
                 name: "a session token is covered by the signature when asked for") { expect in
            // The fix. S3 computes the signature over SignedHeaders; if the
            // token is sent but not listed there, the request is a 403.
            let request = sign(sessionToken: "FwoGZXIvYXdzEXAMPLE",
                               alsoSign: ["X-Amz-Security-Token"])
            let headers = signedHeaders(of: request)
            expect.ok(headers.contains("x-amz-security-token"),
                      "signed headers were \(headers)")
            expect.equal(request.value(forHTTPHeaderField: "X-Amz-Security-Token"),
                         "FwoGZXIvYXdzEXAMPLE", "and the header is still sent")
        },

        TestCase(group: "Signing",
                 name: "without asking, the token is sent but NOT signed — the original bug") { expect in
            // Kept as a characterisation of the trap. This is what every S3
            // call did before the fix: header present, signature silent about
            // it, S3 answering 403 with nothing useful in the body.
            let request = sign(sessionToken: "FwoGZXIvYXdzEXAMPLE", alsoSign: [])
            let headers = signedHeaders(of: request)
            expect.ok(!headers.contains("x-amz-security-token"),
                      "the signer only covers what it is given")
            expect.ok(request.value(forHTTPHeaderField: "X-Amz-Security-Token") != nil,
                      "yet the header is on the wire — which is exactly the mismatch")
        },

        TestCase(group: "Signing",
                 name: "long-term credentials are unaffected") { expect in
            // The guard is `sessionToken == nil ? [] : [...]`, so a developer
            // running with static keys signs precisely what it signed before.
            // This is the compatibility half of the change.
            let before = signedHeaders(of: sign(sessionToken: nil, alsoSign: []))
            let after = signedHeaders(of: sign(sessionToken: nil, alsoSign: []))
            expect.equal(before, after)
            expect.equal(before, ["host", "x-amz-content-sha256", "x-amz-date"],
                         "the baseline set is unchanged")
            expect.ok(!before.contains("x-amz-security-token"))
        },

        TestCase(group: "Signing",
                 name: "signed headers stay sorted, which the canonical request requires") { expect in
            // SigV4 requires SignedHeaders in lower-case ascending order. An
            // added header must not break that ordering, or every request
            // fails rather than just the ones carrying a token.
            let headers = signedHeaders(of: sign(sessionToken: "t", alsoSign: ["X-Amz-Security-Token"]))
            expect.equal(headers, headers.sorted(), "got \(headers)")
            expect.ok(headers.allSatisfy { $0 == $0.lowercased() })
        },

        TestCase(group: "Signing",
                 name: "a payload hash is always present and matches the body") { expect in
            // S3 rejects a SigV4 request with no x-amz-content-sha256, so this
            // is the other header that must never go missing.
            var request = URLRequest(url: URL(string: "https://bucket.s3.us-east-1.amazonaws.com/k")!)
            request.httpMethod = "PUT"
            let body = Data("BEGIN:VCALENDAR".utf8)
            try? signer.sign(&request, payload: body, now: fixedDate,
                             alsoSign: ["X-Amz-Security-Token"])
            let hash = request.value(forHTTPHeaderField: "x-amz-content-sha256")
            expect.equal(hash, EventKey.sha256("BEGIN:VCALENDAR"),
                         "the hash covers the body actually sent")
            expect.ok(signedHeaders(of: request).contains("x-amz-content-sha256"))
        },

        TestCase(group: "Signing",
                 name: "the signature changes when the token changes") { expect in
            // If it did not, the token would not really be covered and the
            // first test above would be passing on appearances.
            func authorization(_ token: String) -> String {
                sign(sessionToken: token, alsoSign: ["X-Amz-Security-Token"])
                    .value(forHTTPHeaderField: "Authorization") ?? ""
            }
            expect.ok(!authorization("tokenA").isEmpty)
            expect.ok(authorization("tokenA") != authorization("tokenB"),
                      "two different session tokens must not share a signature")
        },
    ] }
}
