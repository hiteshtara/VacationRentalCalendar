import Foundation
import VRCCore

/// Routing and policy for the public, read-only calendar endpoint.
///
/// This is the only part of the outbound story that is reachable without AWS
/// credentials, so it is deliberately a pure function over its inputs: no
/// network, no clock, no storage. Everything that decides *whether* a request
/// is answered lives here and is unit-tested; the Lambda wrapped around it only
/// fetches bytes once this has said yes.
///
/// Two independent secrets are involved and they are kept independent:
///
/// * the **token** in the URL, which the subscriber holds, and
/// * the **S3 object key**, which only AWS and this code ever see.
///
/// Neither is derived from the other. If the bucket were ever listed, the keys
/// it revealed would not be usable URLs; if the URL leaked, it would not reveal
/// where the object lives. Only the SHA-256 *digest* of the token is stored at
/// runtime, so compromising the grant table does not yield a working URL
/// either.
public enum FeedEndpoint {

    /// What a valid token unlocks. Carries no credential of any kind.
    public struct Grant: Sendable, Equatable {
        public var objectKey: String
        public var destination: String

        public init(objectKey: String, destination: String) {
            self.objectKey = objectKey
            self.destination = destination
        }
    }

    public enum Outcome: Sendable, Equatable {
        case serve(objectKey: String)
        /// Wrong token, revoked token, or a path that is not a feed path. The
        /// three are deliberately indistinguishable: reporting them separately
        /// would turn the endpoint into an oracle for what a real path looks
        /// like, and a 410 would confirm a token had once been valid.
        case notFound
        case methodNotAllowed
    }

    /// Only reads. A calendar feed has no reason to accept anything else, and
    /// an endpoint that quietly tolerated a write would be a much worse fault
    /// than one that refused a legitimate reader.
    public static let allowedMethods: Set<String> = ["GET", "HEAD"]

    /// `no-store` because revocation has to bite immediately. Anything
    /// cacheable would let an intermediary keep serving a withdrawn calendar
    /// after the grant was deleted, which is the single failure this endpoint
    /// must not have. At roughly one request every two hours there is nothing
    /// to gain from caching anyway.
    public static let servedHeaders: [String: String] = [
        "content-type": "text/calendar; charset=utf-8",
        "cache-control": "no-store, max-age=0",
    ]

    private static let prefix = "/ical/"
    private static let suffix = ".ics"
    /// 128 bits, lower-case hex — the shape `FeedTokenRepository.generateKey()`
    /// produces. Anything else is rejected before a lookup is attempted.
    private static let tokenLength = 32

    public static func route(
        method: String, path: String, grants: [String: Grant]
    ) -> Outcome {
        guard allowedMethods.contains(method.uppercased()) else { return .methodNotAllowed }
        guard let token = token(in: path) else { return .notFound }
        // The lookup is by digest, so the table never holds anything that could
        // be replayed as a URL.
        guard let grant = grants[EventKey.sha256(token)] else { return .notFound }
        return .serve(objectKey: grant.objectKey)
    }

    /// Extracts the token from `/ical/<32 hex>.ics`, or nil for anything else.
    ///
    /// Strict on purpose: exact prefix (case-sensitive), exact suffix, exact
    /// length, hex only. A permissive parser here is how traversal and
    /// confused-deputy bugs start.
    static func token(in path: String) -> String? {
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let body = path.dropFirst(prefix.count).dropLast(suffix.count)
        guard body.count == tokenLength else { return nil }
        guard body.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else {
            return nil
        }
        return String(body)
    }

    /// Builds the grant table from the Secrets Manager payload, which is a
    /// flat map of `sha256(token) -> S3 object key`.
    ///
    /// Flat on purpose: `SecretsManagerReader` already hands back
    /// `[String: String]`, and the runtime needs nothing else — the object
    /// *is* the destination's calendar. Only **active** grants belong in the
    /// secret, so revoking a token means deleting its entry and there is no
    /// "retired" flag anyone can forget to check.
    public static func grants(from secret: [String: String]) -> [String: Grant] {
        var result: [String: Grant] = [:]
        for (digest, objectKey) in secret where !objectKey.isEmpty {
            let normalised = digest.lowercased()
            // Anything that is not a SHA-256 digest cannot have come from a
            // token, so it is not a grant — refuse it rather than carry it.
            guard normalised.count == 64,
                  normalised.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
            else { continue }
            result[normalised] = Grant(objectKey: objectKey, destination: "booking_com")
        }
        return result
    }
}
