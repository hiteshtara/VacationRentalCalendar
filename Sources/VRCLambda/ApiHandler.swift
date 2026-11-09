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

        public init(method: String, path: String, principal: String?, body: [String: Any]) {
            self.method = method
            self.path = path
            self.principal = principal
            self.body = body
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
            return status(store: store)
        case ("GET", "/availability"):
            return availability(store: store)
        default:
            return LambdaJSON.httpResponse(404, [
                "error": "no such route",
                "detail": "\(request.method) \(request.path)",
            ])
        }
    }

    private func status(store: DataStore) -> Data {
        do {
            let events = try store.scalarInt(
                "SELECT count(*) FROM source_events WHERE withdrawn_at IS NULL")
            let approved = try store.scalarInt(
                "SELECT count(*) FROM availability_decisions WHERE status = ?", [.text("approved")])
            let published = try store.scalarInt(
                "SELECT count(*) FROM availability_decisions WHERE status = ?", [.text("published")])
            let conflicts = try store.scalarInt(
                "SELECT count(*) FROM conflicts WHERE resolved_at IS NULL")
            let lastImport = try store.queryOne(
                "SELECT max(finished_at) AS at FROM import_runs WHERE outcome = ?",
                [.text("ok")])

            return LambdaJSON.httpResponse(200, [
                "liveSourceEvents": events,
                "approvedDecisions": approved,
                "publishedDecisions": published,
                "openConflicts": conflicts,
                "lastSuccessfulImport": lastImport?.string("at") ?? "never",
                "outboundEnabled": context.outboundEnabled && OutboundSyncGate.isEnabled,
                // Said plainly, because a published feed is not an imported
                // one and the Mac must not display it as synchronised.
                "remoteSynchronised": false,
                "note": "a published feed is not evidence that a platform has read it",
            ])
        } catch let error as DataAPIError {
            // Fail closed: an unreadable database is reported as unknown, never
            // as zero conflicts and nothing to do.
            return LambdaJSON.httpResponse(503, [
                "error": "database unavailable",
                "detail": error.errorDescription ?? "\(error)",
                "remoteSynchronised": false,
            ])
        } catch {
            return LambdaJSON.httpResponse(500, ["error": "\(error)"])
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
