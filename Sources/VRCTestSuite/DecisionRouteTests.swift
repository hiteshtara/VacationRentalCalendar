import Foundation
import VRCCore
import VRCLambda

/// `POST /decisions` and `GET /decisions/{uid}`, against a real PostgreSQL
/// cluster when `VRC_PG_PORT` is set and against SQLite otherwise, so the
/// routes are exercised either way.
public enum DecisionRouteTests {

    static func store() throws -> RentalStore {
        if let port = ProcessInfo.processInfo.environment["VRC_PG_PORT"] {
            let transport = try PostgresIntegrationTests.PsqlTransport(port: port)
            for table in ["availability_audit", "availability_decisions",
                          "idempotency_keys", "classifications", "events",
                          "platform_listings", "properties"] {
                _ = try? transport.send(DataAPICall(
                    action: .execute, body: ["sql": "DELETE FROM \(table)"]))
            }
            return try RentalStore(
                database: DataAPIStore(
                    transport: transport,
                    configuration: .init(resourceArn: "a", secretArn: "b", database: "vrc",
                                         actor: "owner"),
                    sleeper: { _ in }),
                credentials: InMemoryFeedCredentialStore())
        }
        let local = try RentalStore.makeInMemory()
        // SQLite has no idempotency_keys table; the repository schema is
        // generated from it, so this is created here for the route's own use.
        try local.database.execute("""
            CREATE TABLE IF NOT EXISTS idempotency_keys (
                key TEXT PRIMARY KEY, route TEXT NOT NULL, publication_uid TEXT,
                response_status INTEGER NOT NULL, created_at REAL NOT NULL)
            """)
        return local
    }

    static func handler(actor: String = "owner") -> ApiHandler {
        ApiHandler(context: ServiceContext(actor: actor, environment: [:]))
    }

    static func body(
        uid: String = "vrc-route-1", propertyID: Int64, from: String = "20261210",
        to: String = "20261217", publish: Bool = false,
        destination: String = "vrbo", action: String = "block"
    ) -> [String: Any] {
        [
            "publicationUID": uid, "propertyID": propertyID,
            "destination": destination, "action": action,
            "from": from, "to": to, "reason": "controlled test", "publish": publish,
        ]
    }

    static func post(
        _ handler: ApiHandler, _ store: RentalStore, _ payload: [String: Any],
        key: String? = "idem-1", principal: String? = "arn:aws:iam::1:user/vrc-mac-client"
    ) -> (status: Int, body: [String: Any]) {
        let response = handler.handle(
            .init(method: "POST", path: "/decisions", principal: principal,
                  body: payload, idempotencyKey: key),
            rental: store)
        let envelope = LambdaJSON.object(response)
        return (envelope["statusCode"] as? Int ?? 0,
                LambdaJSON.object(Data((envelope["body"] as? String ?? "").utf8)))
    }

    static func get(
        _ handler: ApiHandler, _ store: RentalStore, _ uid: String,
        principal: String? = "arn:aws:iam::1:user/vrc-mac-client"
    ) -> (status: Int, body: [String: Any]) {
        let response = handler.handle(
            .init(method: "GET", path: "/decisions/\(uid)", principal: principal, body: [:]),
            rental: store)
        let envelope = LambdaJSON.object(response)
        return (envelope["statusCode"] as? Int ?? 0,
                LambdaJSON.object(Data((envelope["body"] as? String ?? "").utf8)))
    }

    static func property(_ store: RentalStore) throws -> Int64 {
        try store.properties.insert(Property(name: "39 G Street")).id!
    }

    public static var cases: [TestCase] { [

        // --- Authentication and authorisation ---

        TestCase(group: "Decision routes", name: "an unsigned POST is refused") { expect in
            let store = try store()
            let result = post(handler(), store, body(propertyID: try property(store)),
                              principal: nil)
            expect.equal(result.status, 401)
            expect.equal(try store.availability.all().count, 0, "and nothing was recorded")
        },

        TestCase(group: "Decision routes",
                 name: "an importer may not record a decision") { expect in
            // The actor comes from the authenticated principal, not the body.
            let store = try store()
            let result = post(handler(actor: "importer"), store,
                              body(propertyID: try property(store)))
            expect.equal(result.status, 403)
            expect.equal(try store.availability.all().count, 0)
        },

        TestCase(group: "Decision routes", name: "an unsigned GET is refused") { expect in
            let store = try store()
            expect.equal(get(handler(), store, "anything", principal: nil).status, 401)
        },

        // --- Idempotency ---

        TestCase(group: "Decision routes", name: "a missing idempotency key is refused") { expect in
            let store = try store()
            let result = post(handler(), store, body(propertyID: try property(store)), key: nil)
            expect.equal(result.status, 400)
            expect.ok((result.body["detail"] as? String ?? "").contains("second decision"),
                      "and says why")
        },

        TestCase(group: "Decision routes",
                 name: "the same key twice records one decision") { expect in
            let store = try store()
            let payload = body(propertyID: try property(store))
            let first = post(handler(), store, payload, key: "idem-same")
            let second = post(handler(), store, payload, key: "idem-same")
            expect.equal(first.status, 201)
            expect.ok(second.body["alreadyApplied"] as? Bool == true,
                      "the retry is recognised")
            expect.equal(try store.availability.all().count, 1,
                         "exactly one decision exists")
        },

        TestCase(group: "Decision routes",
                 name: "a reused publication UID with a NEW key is still not duplicated") { expect in
            // A client that lost its key must not be able to create a second
            // decision for the same publication UID.
            let store = try store()
            let payload = body(propertyID: try property(store))
            _ = post(handler(), store, payload, key: "key-a")
            let second = post(handler(), store, payload, key: "key-b")
            expect.equal(second.status, 409)
            expect.ok(second.body["alreadyApplied"] as? Bool == true)
            expect.equal(try store.availability.all().count, 1)
        },

        // --- Validation ---

        TestCase(group: "Decision routes", name: "publish:true is refused") { expect in
            // Submitting is not publishing, and the route will not be talked
            // into doing both.
            let store = try store()
            let result = post(handler(), store,
                              body(propertyID: try property(store), publish: true))
            expect.equal(result.status, 422)
            expect.equal(try store.availability.all().count, 0)
        },

        TestCase(group: "Decision routes", name: "a malformed decision is refused") { expect in
            let store = try store()
            for broken in [["publicationUID": "x"], ["from": "20261210", "to": "20261217"],
                           ["publicationUID": "x", "propertyID": 1, "destination": "nope",
                            "action": "block", "from": "20261210", "to": "20261217"]] {
                expect.equal(post(handler(), store, broken).status, 400)
            }
        },

        TestCase(group: "Decision routes", name: "a zero-night range is refused") { expect in
            let store = try store()
            let result = post(handler(), store,
                              body(propertyID: try property(store),
                                   from: "20261210", to: "20261210"))
            expect.equal(result.status, 422)
            expect.ok((result.body["detail"] as? String ?? "").contains("half-open"))
        },

        // --- Conflict checks ---

        TestCase(group: "Decision routes",
                 name: "an overlapping approved decision is a conflict") { expect in
            let store = try store()
            let id = try property(store)
            _ = post(handler(), store, body(uid: "vrc-a", propertyID: id,
                                            from: "20261210", to: "20261217"), key: "k1")
            let clash = post(handler(), store, body(uid: "vrc-b", propertyID: id,
                                                    from: "20261215", to: "20261220"), key: "k2")
            expect.equal(clash.status, 409)
            expect.equal(clash.body["conflictsWith"] as? String, "vrc-a")
            expect.equal(try store.availability.all().count, 1)
        },

        TestCase(group: "Decision routes",
                 name: "a checkout-day-adjacent decision is NOT a conflict") { expect in
            // Dec 10-17 then Dec 17-20: the 17th is a turnover, not an overlap.
            // Rejecting this would lose a sellable night.
            let store = try store()
            let id = try property(store)
            _ = post(handler(), store, body(uid: "vrc-a", propertyID: id,
                                            from: "20261210", to: "20261217"), key: "k1")
            let next = post(handler(), store, body(uid: "vrc-b", propertyID: id,
                                                   from: "20261217", to: "20261220"), key: "k2")
            expect.equal(next.status, 201)
            expect.equal(try store.availability.all().count, 2)
        },

        TestCase(group: "Decision routes",
                 name: "an overlap on a DIFFERENT destination is allowed") { expect in
            // Per-platform control is the whole point of the project.
            let store = try store()
            let id = try property(store)
            _ = post(handler(), store, body(uid: "vrc-a", propertyID: id), key: "k1")
            let other = post(handler(), store,
                             body(uid: "vrc-b", propertyID: id, destination: "airbnb"), key: "k2")
            expect.equal(other.status, 201)
        },

        // --- What a success does and does not do ---

        TestCase(group: "Decision routes",
                 name: "a recorded decision is approved, audited, and not published") { expect in
            let store = try store()
            let result = post(handler(), store, body(propertyID: try property(store)))
            expect.equal(result.status, 201)
            expect.equal(result.body["status"] as? String, "approved")
            expect.equal(result.body["nights"] as? Int, 7)
            expect.equal(result.body["approvedBy"] as? String, "owner")
            expect.ok(result.body["published"] as? Bool == false)
            expect.ok(result.body["remoteSynchronised"] as? Bool == false)

            let stored = try store.availability.all()
            expect.equal(stored.count, 1)
            guard let decision = stored.first else {
                expect.fail("nothing was recorded; POST returned \(result.status) "
                    + "body=\(result.body)")
                return
            }
            expect.equal(decision.status, .approved)
            expect.equal(decision.approvedBy, "owner",
                         "the approver is the authenticated principal, not a body field")

            let audit = try store.auditLog.recent(limit: 10)
            expect.equal(audit.count, 1, "exactly one audit row")
            guard let entry = audit.first else { expect.fail("no audit row"); return }
            expect.equal(entry.toStatus, .approved)
            expect.ok(entry.detail.contains("not published"),
                      "and the trail says so explicitly")
        },

        // --- Reconciliation ---

        TestCase(group: "Decision routes", name: "GET finds a recorded decision") { expect in
            let store = try store()
            _ = post(handler(), store, body(uid: "vrc-find-me", propertyID: try property(store)))
            let found = get(handler(), store, "vrc-find-me")
            expect.equal(found.status, 200)
            expect.ok(found.body["found"] as? Bool == true)
            expect.equal(found.body["nights"] as? Int, 7)
            expect.ok(found.body["published"] as? Bool == false)
        },

        TestCase(group: "Decision routes",
                 name: "GET reports absence as found:false, not as an error") { expect in
            // The client reconciles on this, so it must be an answer rather
            // than a failure.
            let store = try store()
            let missing = get(handler(), store, "vrc-never-existed")
            expect.equal(missing.status, 200)
            expect.ok(missing.body["found"] as? Bool == false)
        },

        TestCase(group: "Decision routes",
                 name: "an unreachable database is 503 with found:null, never found:false") { expect in
            // If this returned found:false the client would resubmit and could
            // create a duplicate.
            let transport = RecordingDataAPITransport(responses: [
                .init(statusCode: 200, payload: ["columnMetadata": [["name": "count"]],
                                                 "records": [[["longValue": NSNumber(value: 1)]]]]),
                .init(statusCode: 400, payload: ["__type": "BadRequestException",
                                                 "message": "no"]),
            ])
            let store = try RentalStore(
                database: DataAPIStore(
                    transport: transport,
                    configuration: .init(resourceArn: "a", secretArn: "b", database: "vrc",
                                         maxAttempts: 1),
                    sleeper: { _ in }),
                credentials: InMemoryFeedCredentialStore())
            let result = get(handler(), store, "vrc-anything")
            expect.equal(result.status, 503)
            expect.ok(result.body["found"] is NSNull,
                      "absence must not be asserted when the database cannot be read")
        },

        TestCase(group: "Decision routes",
                 name: "an indeterminate write is 503 pointing at reconciliation") { expect in
            // The outcome must stay unknown, and the client must be told where
            // to find out.
            let transport = RecordingDataAPITransport(responses: [
                .init(statusCode: 200, payload: ["columnMetadata": [["name": "count"]],
                                                 "records": [[["longValue": NSNumber(value: 1)]]]]),
                .init(statusCode: 200, payload: ["transactionId": "t1"]),
                .init(statusCode: 200, payload: [:]),
                .init(statusCode: 500, payload: ["__type": "InternalServerError",
                                                 "message": "boom"]),
            ])
            let store = try RentalStore(
                database: DataAPIStore(
                    transport: transport,
                    configuration: .init(resourceArn: "a", secretArn: "b", database: "vrc",
                                         actor: "owner", maxAttempts: 1),
                    sleeper: { _ in }),
                credentials: InMemoryFeedCredentialStore())
            let result = post(handler(), store, body(uid: "vrc-unknown", propertyID: 1))
            expect.equal(result.status, 503)
            let reconcile = result.body["reconcile"] as? String ?? ""
            expect.ok(reconcile.contains("/decisions/vrc-unknown"),
                      "and names the route that settles it: \(reconcile)")
        },
    ] }
}
