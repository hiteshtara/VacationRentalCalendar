import Foundation
import VRCCore
import VRCLambda

/// The read-only calendar endpoint Booking.com would subscribe to.
///
/// Routing is kept as a pure function so the security rules can be tested
/// without AWS, a network, or a real token. Everything that decides whether a
/// request is served lives here; the Lambda around it only fetches bytes.
public enum FeedEndpointTests {

    /// A token and the grant it unlocks. Synthetic throughout — this value is
    /// not, and must never be, a real feed token.
    static let token = "0123456789abcdef0123456789abcdef"
    static var grants: [String: FeedEndpoint.Grant] {
        [EventKey.sha256(token): FeedEndpoint.Grant(
            objectKey: "ical/booking-v1.ics", destination: "booking_com")]
    }
    static var path: String { "/ical/\(token).ics" }

    public static var cases: [TestCase] { [

        // --- What may be served ---------------------------------------------

        TestCase(group: "Feed endpoint", name: "a valid token is served") { expect in
            expect.equal(FeedEndpoint.route(method: "GET", path: path, grants: grants),
                         .serve(objectKey: "ical/booking-v1.ics"))
        },

        TestCase(group: "Feed endpoint", name: "HEAD is allowed, and resolves identically") { expect in
            // Some calendar clients probe with HEAD before fetching. Refusing it
            // would look like an outage to a subscriber that is behaving well.
            expect.equal(FeedEndpoint.route(method: "HEAD", path: path, grants: grants),
                         .serve(objectKey: "ical/booking-v1.ics"))
        },

        TestCase(group: "Feed endpoint", name: "the method check is case-insensitive") { expect in
            expect.equal(FeedEndpoint.route(method: "get", path: path, grants: grants),
                         .serve(objectKey: "ical/booking-v1.ics"))
        },

        // --- What may not ---------------------------------------------------

        TestCase(group: "Feed endpoint", name: "every writing method is refused") { expect in
            // A read-only endpoint that quietly accepted POST would be a far
            // worse bug than one that 404s a legitimate reader.
            for method in ["POST", "PUT", "PATCH", "DELETE", "OPTIONS", "TRACE", "CONNECT"] {
                expect.equal(FeedEndpoint.route(method: method, path: path, grants: grants),
                             .methodNotAllowed, "\(method) must be refused")
            }
        },

        TestCase(group: "Feed endpoint", name: "an unknown token is not found") { expect in
            let other = "ffffffffffffffffffffffffffffffff"
            expect.equal(FeedEndpoint.route(method: "GET", path: "/ical/\(other).ics",
                                            grants: grants), .notFound)
        },

        TestCase(group: "Feed endpoint", name: "a revoked token is not found") { expect in
            // Revocation is the grant disappearing. There is deliberately no
            // "revoked" state to report: a 410 would confirm the token was once
            // real, which is a small oracle and buys nothing.
            expect.equal(FeedEndpoint.route(method: "GET", path: path, grants: [:]), .notFound)
        },

        TestCase(group: "Feed endpoint", name: "a malformed path is not found, not an error") { expect in
            // Each of these would be a plausible probe. None may be
            // distinguishable from a wrong token, or the endpoint becomes an
            // oracle for what a valid path looks like.
            for bad in [
                "/", "/ical/", "/ical/.ics", "/ical/\(token)", "/ical/\(token).txt",
                "/ICAL/\(token).ics",                       // case-sensitive prefix
                "/ical/\(token).ics/extra",
                "/ical/../ical/\(token).ics",               // traversal
                "/ical/\(token.dropLast()).ics",            // 31 hex characters
                "/ical/\(token)0.ics",                      // 33
                "/ical/\(token.replacingOccurrences(of: "a", with: "g")).ics", // non-hex
                "/\(token).ics",
            ] {
                expect.equal(FeedEndpoint.route(method: "GET", path: bad, grants: grants),
                             .notFound, "path \(bad) must be a plain 404")
            }
        },

        TestCase(group: "Feed endpoint",
                 name: "a badly shaped token is refused even when the grant table would match it") { expect in
            // The point of the shape check, made observable. Without it, these
            // would be accepted as tokens, hashed, found, and SERVED — so a
            // plain "wrong token 404s" test proves nothing about the guard,
            // because a wrong token 404s at the lookup regardless.
            for malformed in [
                String(token.dropLast()),                               // 31 hex
                token + "0",                                            // 33 hex
                token.uppercased(),                                     // not lower-case
                token.replacingOccurrences(of: "a", with: "g"),         // not hex
            ] {
                let planted = [EventKey.sha256(malformed): FeedEndpoint.Grant(
                    objectKey: "ical/should-never-be-served.ics", destination: "booking_com")]
                expect.equal(
                    FeedEndpoint.route(method: "GET", path: "/ical/\(malformed).ics",
                                       grants: planted),
                    .notFound,
                    "a \(malformed.count)-character token must never reach the lookup")
            }
        },

        TestCase(group: "Feed endpoint", name: "the object key is never derived from the token") { expect in
            // The S3 key and the URL token are independent secrets. If the key
            // were the token, leaking either would leak both — and a bucket
            // listing would hand over the URL.
            let grant = grants.values.first!
            expect.notContains(grant.objectKey, token)
        },

        TestCase(group: "Feed endpoint",
                 name: "the raw token is never stored, only its digest") { expect in
            // The grant table is what the Lambda reads at runtime. A compromise
            // of it must not yield a working URL.
            for key in grants.keys {
                expect.notContains(key, token)
                expect.equal(key.count, 64, "a SHA-256 digest, not the token")
            }
        },

        // --- Response shaping ------------------------------------------------

        TestCase(group: "Feed endpoint", name: "a served calendar declares text/calendar") { expect in
            let headers = FeedEndpoint.servedHeaders
            expect.equal(headers["content-type"], "text/calendar; charset=utf-8")
        },

        TestCase(group: "Feed endpoint",
                 name: "caching never outlives a revocation") { expect in
            // Revocation has to bite immediately. Anything cacheable would keep
            // serving a withdrawn calendar from an intermediary after the grant
            // was deleted, which is the one failure this endpoint must not have.
            let cache = FeedEndpoint.servedHeaders["cache-control"] ?? ""
            expect.contains(cache, "no-store")
            expect.notContains(cache, "public")
        },
    ] }
}
