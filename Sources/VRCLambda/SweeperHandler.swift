import Foundation
import VRCCore

/// Releases holds whose expiry has passed.
///
/// Idempotent by construction: a single UPDATE with the expiry in its WHERE
/// clause. Running it twice, or concurrently with itself, releases nothing
/// extra.
///
/// This is the active-release path. The database's own view of availability
/// also excludes an expired-but-unswept hold, so correctness never depends on
/// this having run — exactly the arrangement the website already uses, where
/// DynamoDB TTL is only a backstop.
public struct SweeperHandler {
    let context: ServiceContext

    public init(context: ServiceContext) { self.context = context }

    public struct Outcome: Sendable {
        public var holdsReleased: Int
        public var detail: String
    }

    public func run(store: DataStore) throws -> Outcome {
        let released = try store.transaction {
            try store.run("""
                UPDATE holds
                   SET released_at = now()
                 WHERE released_at IS NULL
                   AND expires_at <= now()
                """)
        }
        return Outcome(
            holdsReleased: released,
            detail: released == 0
                ? "nothing had expired"
                : "released \(released) expired hold(s); no confirmed reservation was touched")
    }
}
