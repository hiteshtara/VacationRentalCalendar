import Foundation
import VRCCore

/// `POST /decisions` and `GET /decisions/{uid}`.
///
/// Built on the tested repositories rather than hand-written SQL, so the
/// validation, the audit row and the conflict check are the same code the Mac
/// application runs.
///
/// Two rules shape everything here:
///
/// **Submitting is not publishing.** Recording an approved decision changes
/// nothing a platform can see. Publication is a separate, gated step, and this
/// route never triggers it — not even as a convenience.
///
/// **A retry must not become a second decision.** Every mutating request
/// carries a content-derived idempotency key, recorded with its outcome, so a
/// client that retried after a timeout gets the first answer back.
public struct DecisionRoutes {

    public struct Submission: Sendable {
        public var publicationUID: String
        public var propertyID: Int64
        public var destination: RentalPlatform
        public var action: AvailabilityAction
        public var startDay: Date
        public var endDay: Date
        public var reason: String
        public var publish: Bool

        /// Parses and validates shape only. Business validation is below, so
        /// a malformed request and a disallowed one are distinguishable.
        public init?(body: [String: Any]) {
            guard let uid = body["publicationUID"] as? String, !uid.isEmpty,
                  let from = body["from"] as? String, let to = body["to"] as? String,
                  let start = DecisionRoutes.day(from), let end = DecisionRoutes.day(to),
                  let destinationName = body["destination"] as? String,
                  let destination = RentalPlatform(rawValue: destinationName),
                  let actionName = body["action"] as? String,
                  let action = AvailabilityAction(rawValue: actionName)
            else { return nil }

            let property: Int64
            if let value = body["propertyID"] as? Int64 { property = value }
            else if let value = body["propertyID"] as? Int { property = Int64(value) }
            else if let value = body["propertyID"] as? NSNumber { property = value.int64Value }
            else { return nil }

            self.publicationUID = uid
            self.propertyID = property
            self.destination = destination
            self.action = action
            self.startDay = start
            self.endDay = end
            self.reason = body["reason"] as? String ?? ""
            self.publish = body["publish"] as? Bool ?? false
        }
    }

    static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = DayMath.utc
        for format in ["yyyyMMdd", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    let context: ServiceContext

    public init(context: ServiceContext) { self.context = context }

    // MARK: GET /decisions/{uid}

    /// The reconciliation endpoint. A client that could not tell whether its
    /// write landed asks here, so it never has to guess.
    public func lookup(publicationUID: String, store: RentalStore) -> Data {
        do {
            let match = try store.availability.all()
                .first { $0.publicationUID == publicationUID }
            guard let match else {
                return LambdaJSON.httpResponse(200, [
                    "found": false, "publicationUID": publicationUID,
                ])
            }
            return LambdaJSON.httpResponse(200, [
                "found": true,
                "publicationUID": match.publicationUID,
                "destination": match.destination.rawValue,
                "action": match.action.rawValue,
                "status": match.status.rawValue,
                "from": DayMath.icalDateString(match.startDay),
                "to": DayMath.icalDateString(match.endDay),
                "nights": match.nights,
                // Said explicitly, because "recorded" and "published" are
                // different things and conflating them is how a feed gets
                // assumed to be live.
                "published": match.status == .published || match.status == .verified,
                "remoteSynchronised": false,
            ])
        } catch {
            // Fail closed. A client reconciling an uncertain write must never
            // be told "not found" because the database was unreachable: it
            // would then resubmit and could create a duplicate.
            return LambdaJSON.httpResponse(503, [
                "error": "database unavailable",
                "detail": (error as? LocalizedError)?.errorDescription ?? "\(error)",
                "found": NSNull(),
            ])
        }
    }

    // MARK: POST /decisions

    public func submit(
        body: [String: Any], idempotencyKey: String?, actor: String, store: RentalStore
    ) -> Data {
        guard let key = idempotencyKey, !key.isEmpty else {
            return LambdaJSON.httpResponse(400, [
                "error": "an Idempotency-Key header is required",
                "detail": "without one a retried request could create a second decision",
            ])
        }
        guard let submission = Submission(body: body) else {
            return LambdaJSON.httpResponse(400, ["error": "malformed decision"])
        }

        // Submitting is never publishing.
        if submission.publish {
            return LambdaJSON.httpResponse(422, [
                "error": "this route does not publish",
                "detail": "recording a decision and publishing a feed are separate, "
                    + "and publication is gated independently",
            ])
        }
        guard submission.endDay > submission.startDay else {
            return LambdaJSON.httpResponse(422, [
                "error": "the range must contain at least one night",
                "detail": "check-out must be after check-in; intervals are half-open",
            ])
        }

        do {
            var outcome: [String: Any] = [:]
            var status = 200

            try store.database.transaction {
                // 1. Idempotency. The insert is the claim; losing it means
                //    someone got here first.
                let existing = try store.database.queryOne(
                    "SELECT publication_uid, response_status FROM idempotency_keys WHERE key = ?",
                    [.text(key)])
                if let existing {
                    status = Int(existing.int("response_status") ?? 200)
                    outcome = [
                        "alreadyApplied": true,
                        "publicationUID": existing.stringValue("publication_uid"),
                        "detail": "this request was already processed",
                    ]
                    return
                }

                // 2. The publication UID is the second idempotency anchor: a
                //    client that lost its key but reused the UID must not
                //    create a duplicate decision either.
                if let duplicate = try store.availability.all()
                    .first(where: { $0.publicationUID == submission.publicationUID }) {
                    status = 409
                    outcome = [
                        "alreadyApplied": true,
                        "publicationUID": duplicate.publicationUID,
                        "status": duplicate.status.rawValue,
                        "detail": "a decision with this publication UID already exists",
                    ]
                    _ = try store.database.run("""
                        INSERT INTO idempotency_keys
                            (key, route, publication_uid, response_status, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        """, [.text(key), .text("POST /decisions"),
                              .text(duplicate.publicationUID), .integer(409),
                              .real(Date().timeIntervalSince1970)])
                    return
                }

                // 3. Only the owner may record an approved decision, and the
                //    actor comes from the authenticated principal, not the body.
                guard actor == "owner" || actor == "admin" else {
                    status = 403
                    outcome = ["error": "actor \(actor) may not record an availability decision"]
                    return
                }

                // 4. Conflict check: a block must not be recorded over nights
                //    an existing approved decision already covers for the same
                //    destination, and a reopen must not contradict one.
                let overlapping = try store.availability.all().filter {
                    $0.destination == submission.destination
                        && [AvailabilityStatus.approved, .published, .verified].contains($0.status)
                        && $0.startDay < submission.endDay
                        && submission.startDay < $0.endDay
                }
                if let clash = overlapping.first {
                    status = 409
                    outcome = [
                        "error": "overlaps an existing \(clash.status.rawValue) decision",
                        "conflictsWith": clash.publicationUID,
                        "from": DayMath.icalDateString(clash.startDay),
                        "to": DayMath.icalDateString(clash.endDay),
                    ]
                    return
                }

                // 5. Record it. Approved, because the owner approved it on the
                //    Mac — and `approvedBy` is the authenticated principal, not
                //    anything the client claimed.
                let stored = try store.availability.insert(AvailabilityDecision(
                    propertyID: submission.propertyID,
                    destination: submission.destination,
                    action: submission.action,
                    startDay: submission.startDay,
                    endDay: submission.endDay,
                    status: .approved,
                    reason: submission.reason,
                    publicationUID: submission.publicationUID,
                    approvedAt: Date(),
                    approvedBy: actor))

                // 6. Audit. Append-only, and the route is named so the trail
                //    distinguishes a cloud submission from a local approval.
                _ = try store.auditLog.record(AuditEntry(
                    decisionID: stored.id, at: Date(), actor: actor,
                    fromStatus: nil, toStatus: .approved, event: "approved",
                    detail: "recorded via POST /decisions (\(stored.nights) night(s), "
                        + "\(submission.destination.displayName)); not published"))

                _ = try store.database.run("""
                    INSERT INTO idempotency_keys
                        (key, route, publication_uid, response_status, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    """, [.text(key), .text("POST /decisions"),
                          .text(stored.publicationUID), .integer(201),
                          .real(Date().timeIntervalSince1970)])

                status = 201
                outcome = [
                    "publicationUID": stored.publicationUID,
                    "status": stored.status.rawValue,
                    "nights": stored.nights,
                    "approvedBy": actor,
                    // Stated on every success, so no client can infer it.
                    "published": false,
                    "remoteSynchronised": false,
                    "detail": "recorded. Publication is a separate, gated step and did not happen.",
                ]
            }
            return LambdaJSON.httpResponse(status, outcome)

        } catch let error as DataAPIError {
            if case .indeterminate(let detail) = error {
                // The one response that must not be mistaken for either
                // success or failure. 503 so the client reconciles rather than
                // assuming.
                return LambdaJSON.httpResponse(503, [
                    "error": "the outcome of this write is unknown",
                    "detail": detail,
                    "reconcile": "GET /decisions/\(submission.publicationUID)",
                ])
            }
            // Every 503 from this route carries the reconciliation pointer, not
            // just the strictly-indeterminate one. From the client's side a
            // failed write is a failed write: it cannot tell whether the
            // database was reached before or after the statement landed, so it
            // must always be told where to find out rather than being left to
            // guess or to resubmit blindly.
            return LambdaJSON.httpResponse(503, [
                "error": "database unavailable",
                "detail": error.errorDescription ?? "\(error)",
                "reconcile": "GET /decisions/\(submission.publicationUID)",
            ])
        } catch {
            return LambdaJSON.httpResponse(503, [
                "error": "the outcome of this write is unknown",
                "detail": "\(error)",
                "reconcile": "GET /decisions/\(submission.publicationUID)",
            ])
        }
    }
}
