import Foundation
import VRCCore

/// The Mac application's sync endpoint.
///
/// Authentication is API Gateway's `AWS_IAM`: the request is SigV4-signed and
/// the gateway rejects anything unsigned before this code runs. That means no
/// token handling here, and no login state to get wrong. This handler still
/// checks that an authorised principal was attached, because defence that
/// depends on a single layer is not defence.
public struct ApiHandler {
    let context: ServiceContext

    public init(context: ServiceContext) { self.context = context }

    public struct Request: Sendable {
        public var method: String
        public var path: String
        public var principal: String?
        public var body: [String: Any]
        public var idempotencyKey: String?

        public init(
            method: String, path: String, principal: String?,
            body: [String: Any], idempotencyKey: String? = nil
        ) {
            self.method = method
            self.path = path
            self.principal = principal
            self.body = body
            self.idempotencyKey = idempotencyKey
        }

        /// API Gateway HTTP API v2 payload.
        public init(event: [String: Any]) {
            let requestContext = event["requestContext"] as? [String: Any] ?? [:]
            let http = requestContext["http"] as? [String: Any] ?? [:]
            self.method = (http["method"] as? String ?? "GET").uppercased()
            self.path = http["path"] as? String ?? "/"
            let authorizer = requestContext["authorizer"] as? [String: Any] ?? [:]
            let iam = authorizer["iam"] as? [String: Any] ?? [:]
            self.principal = (iam["userArn"] as? String)
                ?? (iam["userId"] as? String)
                ?? (requestContext["identity"] as? [String: Any])?["caller"] as? String
            if let raw = event["body"] as? String, let data = raw.data(using: .utf8) {
                self.body = LambdaJSON.object(data)
            } else {
                self.body = [:]
            }
            // Header names arrive lower-cased from the HTTP API.
            let headers = (event["headers"] as? [String: Any]) ?? [:]
            self.idempotencyKey = (headers["idempotency-key"] as? String)
                ?? (headers["Idempotency-Key"] as? String)
        }
    }

    /// Routes against the repository layer, so validation, the audit row and
    /// the conflict check are the same code the Mac application runs.
    public func handle(_ request: Request, rental: RentalStore) -> Data {
        guard let principal = request.principal, !principal.isEmpty else {
            return LambdaJSON.httpResponse(401, [
                "error": "unauthenticated",
                "detail": "this endpoint requires a SigV4-signed request",
            ])
        }

        // The actor is the authenticated principal's role, never anything the
        // body claims. A client cannot promote itself by sending a field.
        let actor = context.actor
        let routes = DecisionRoutes(context: context)

        switch (request.method, request.path) {
        case ("POST", "/decisions"):
            return routes.submit(
                body: request.body, idempotencyKey: request.idempotencyKey,
                actor: actor, store: rental)
        case ("GET", let path) where path.hasPrefix("/decisions/"):
            let uid = String(path.dropFirst("/decisions/".count))
            guard !uid.isEmpty else {
                return LambdaJSON.httpResponse(400, ["error": "no publication UID"])
            }
            return routes.lookup(
                publicationUID: uid.removingPercentEncoding ?? uid, store: rental)
        case ("GET", "/status"), ("GET", "/"):
            return status(rental: rental)
        case ("GET", "/availability"):
            return availability(store: rental.database)
        default:
            return LambdaJSON.httpResponse(404, [
                "error": "no such route",
                "detail": "\(request.method) \(request.path)",
            ])
        }
    }

    public func handle(_ request: Request, store: DataStore) -> Data {
        guard let principal = request.principal, !principal.isEmpty else {
            // Should be impossible behind AWS_IAM, which is exactly why it is
            // worth refusing loudly rather than assuming.
            return LambdaJSON.httpResponse(401, [
                "error": "unauthenticated",
                "detail": "this endpoint requires a SigV4-signed request",
            ])
        }

        switch (request.method, request.path) {
        case ("GET", "/status"), ("GET", "/"):
            return LambdaJSON.httpResponse(500, [
                "error": "this overload requires the repository layer",
            ])
        case ("GET", "/availability"):
            return availability(store: store)
        default:
            return LambdaJSON.httpResponse(404, [
                "error": "no such route",
                "detail": "\(request.method) \(request.path)",
            ])
        }
    }

    /// Built on the repositories rather than hand-written SQL.
    ///
    /// The previous version queried `source_events` and `import_runs` — table
    /// names from the superseded schema. They do not exist in the repository
    /// schema, so every call returned 503 against the real cluster. Using the
    /// repositories means the handler cannot drift from the schema the Mac
    /// uses, because it is the same code.
    private func status(rental: RentalStore) -> Data {
        do {
            let events = try rental.events.allActive()
            let decisions = try rental.availability.all()
            let listings = try rental.listings.all()
            let runs = try rental.syncRuns.recent(limit: 50)

            // A source is failing if its connection state says so; stale if it
            // has not succeeded inside the freshness window. Both are reported
            // rather than collapsed into a single "healthy" flag, because they
            // need different responses.
            var failing: [String: String] = [:]
            var stale: [String: String] = [:]
            let now = Date()
            for listing in listings {
                let platform = listing.platform.rawValue
                if !listing.connectionState.shouldAttemptImport {
                    failing[platform] = listing.connectionState.rawValue
                    continue
                }
                guard let last = listing.lastSyncAt else {
                    stale[platform] = "never imported"
                    continue
                }
                let age = now.timeIntervalSince(last)
                if age > 6 * 3600 {
                    stale[platform] = "last success \(Int(age / 3600))h ago"
                }
            }

            let lastSuccess = runs
                .filter { $0.outcome == .success }
                .compactMap(\.finishedAt)
                .max()

            // `conflicts` is created by 011_safety.sql and has no repository,
            // so this is the one direct query left — and it is a count, not a
            // business decision.
            let openConflicts = (try? rental.database.scalarInt(
                "SELECT count(*) FROM conflicts WHERE resolved_at IS NULL")) ?? 0

            return LambdaJSON.httpResponse(200, [
                "liveSourceEvents": events.count,
                "approvedDecisions": decisions.filter { $0.status == .approved }.count,
                "publishedDecisions": decisions.filter {
                    $0.status == .published || $0.status == .verified
                }.count,
                "openConflicts": openConflicts,
                "lastSuccessfulImport": lastSuccess
                    .map { ISO8601DateFormatter().string(from: $0) } ?? "never",
                "outboundEnabled": context.outboundEnabled && OutboundSyncGate.isEnabled,
                // Said plainly, because a published feed is not an imported
                // one and the Mac must not display it as synchronised.
                "remoteSynchronised": false,
                "failingSources": failing,
                "staleSources": stale,
                "note": "a published feed is not evidence that a platform has read it",
            ])
        } catch let error as DataAPIError {
            // Fail closed: an unreadable database is reported as unavailable,
            // never as zero conflicts and nothing to do.
            return LambdaJSON.httpResponse(503, [
                "error": "database unavailable",
                "detail": error.errorDescription ?? "\(error)",
                "remoteSynchronised": false,
            ])
        } catch {
            return LambdaJSON.httpResponse(503, [
                "error": "database unavailable",
                "detail": "\(error)",
                "remoteSynchronised": false,
            ])
        }
    }

    private func availability(store: DataStore) -> Data {
        do {
            let rows = try store.query("""
                SELECT property_id, lower(stay) AS starts, upper(stay) AS ends, basis, source
                  FROM blocking_intervals
                 ORDER BY starts
                 LIMIT 2000
                """)
            let intervals = rows.map { row in
                [
                    "property": row.stringValue("property_id"),
                    "from": row.stringValue("starts"),
                    "to": row.stringValue("ends"),
                    "basis": row.stringValue("basis"),
                    "source": row.stringValue("source"),
                ]
            }
            return LambdaJSON.httpResponse(200, ["blocking": intervals, "count": intervals.count])
        } catch {
            return LambdaJSON.httpResponse(503, [
                "error": "database unavailable", "detail": "\(error)",
            ])
        }
    }
}
