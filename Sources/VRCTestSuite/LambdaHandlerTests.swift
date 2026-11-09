import Foundation
import VRCCore
import VRCLambda

/// The handlers are where a safety rule becomes an action against the real
/// world, so these test the refusals rather than the happy paths.
public enum LambdaHandlerTests {

    // MARK: Doubles

    final class FakeObjects: ObjectStore, @unchecked Sendable {
        private let lock = NSLock()
        var stored: [String: Data] = [:]
        var failPut: String?

        init(_ initial: [String: Data] = [:]) { stored = initial }

        func get(key: String) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            guard let data = stored[key] else {
                throw LambdaRuntime.HandlerError(type: "NoSuchKey", message: key)
            }
            return data
        }
        func put(key: String, body: Data, contentType: String) throws {
            if let failPut, key.contains(failPut) {
                throw LambdaRuntime.HandlerError(type: "S3", message: "PUT refused")
            }
            lock.lock(); stored[key] = body; lock.unlock()
        }
        func putIfAbsent(key: String, body: Data, contentType: String) throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            if stored[key] != nil { return false }
            stored[key] = body
            return true
        }
    }

    final class FakeInvoker: FunctionInvoker, @unchecked Sendable {
        private let lock = NSLock()
        var invocations: [(function: String, payload: Data)] = []
        func invoke(function: String, payload: Data) throws {
            lock.lock(); invocations.append((function, payload)); lock.unlock()
        }
    }

    final class FakeInvalidator: CacheInvalidator, @unchecked Sendable {
        var shouldFail = false
        var calls = 0
        func invalidate(paths: [String]) throws {
            calls += 1
            if shouldFail {
                throw LambdaRuntime.HandlerError(type: "CloudFront", message: "purge failed")
            }
        }
    }

    struct StubFetcher: FeedFetching {
        let responses: [String: FeedResponse]
        let failures: Set<String>
        func fetch(urlString: String) async throws -> FeedResponse {
            if failures.contains(urlString) {
                throw FeedFetchError.httpError(500)
            }
            guard let response = responses[urlString] else {
                throw FeedFetchError.httpError(404)
            }
            return response
        }
    }

    static func feed(stamp: String, summary: String = "Reserved",
                     start: String = "20270301", end: String = "20270305") -> String {
        ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//T//EN", "BEGIN:VEVENT",
         "DTSTAMP:\(stamp)", "UID:u1@test", "DTSTART;VALUE=DATE:\(start)",
         "DTEND;VALUE=DATE:\(end)", "SUMMARY:\(summary)", "END:VEVENT", "END:VCALENDAR"]
            .joined(separator: "\r\n")
    }

    static func fetchContext() -> ServiceContext {
        // No VRC_DB_SECRET_ARN: this is what the fetcher is actually given.
        ServiceContext(actor: "importer", environment: [
            "VRC_RAW_BUCKET": "vrc-raw", "VRC_PROCESS_FUNCTION": "vrc-process",
        ])
    }

    static func classified(_ kind: BlockKind, key: String = "k1") -> ClassifiedEvent {
        ClassifiedEvent(
            event: CalendarEvent(
                listingID: 1, eventKey: key, uid: key, platform: .airbnb,
                summary: kind == .confirmedReservation ? "Reserved" : "Blocked",
                details: "", checkIn: DayMath.day(2027, 3, 1), checkOut: DayMath.day(2027, 3, 5)),
            classification: EventClassification(
                eventKey: key, kind: kind, confidence: .high, source: .manual,
                needsReview: false, exportApproved: true),
            listingLabel: "Airbnb", propertyID: 1, propertyName: "39 G Street")
    }

    static func decision(_ status: AvailabilityStatus) -> AvailabilityDecision {
        AvailabilityDecision(
            id: 1, propertyID: 1, destination: .vrbo, action: .block,
            startDay: DayMath.day(2026, 12, 10), endDay: DayMath.day(2026, 12, 17),
            status: status, publicationUID: "vrc-test-1", approvedAt: Date())
    }

    public static var cases: [TestCase] { [

        // --- Fetcher: the component that must not reach the database ---

        TestCase(group: "Lambda handlers",
                 name: "the fetcher refuses to run if given a database credential") { expect in
            // IAM already prevents this. Checking it again at runtime means a
            // future policy edit that widened the fetcher's access is still
            // caught.
            let context = ServiceContext(actor: "importer", environment: [
                "VRC_RAW_BUCKET": "b", "VRC_DB_SECRET_ARN": "arn:secret",
            ])
            let handler = FetchHandler(
                context: context, fetcher: StubFetcher(responses: [:], failures: []),
                objects: FakeObjects(), invoker: FakeInvoker())
            do {
                _ = try handler.run(sources: [])
                expect.fail("a fetcher holding a database credential must refuse to run")
            } catch let error as LambdaRuntime.HandlerError {
                expect.equal(error.type, "PrivilegeViolation")
            }
        },

        TestCase(group: "Lambda handlers",
                 name: "an unchanged feed does not wake the processor") { expect in
            // The entire cost model rests on this.
            let unchanged = feed(stamp: "20261109T090000Z")
            let hash = SemanticFeedHash.hash(try ICalParser.parse(unchanged).events)
            let objects = FakeObjects(["hashes/airbnb.sha256": Data(hash.utf8)])
            let invoker = FakeInvoker()
            let handler = FetchHandler(
                context: fetchContext(),
                fetcher: StubFetcher(
                    responses: ["https://a/": FeedResponse(text: unchanged, httpStatus: 200)],
                    failures: []),
                objects: objects, invoker: invoker)

            let outcome = try handler.run(
                sources: [.init(name: "airbnb", url: "https://a/")])
            expect.equal(outcome.unchanged, ["airbnb"])
            expect.equal(invoker.invocations.count, 0, "the database must stay asleep")
        },

        TestCase(group: "Lambda handlers",
                 name: "a regenerated DTSTAMP alone does not wake the processor") { expect in
            let first = feed(stamp: "20261109T090000Z")
            let hash = SemanticFeedHash.hash(try ICalParser.parse(first).events)
            let objects = FakeObjects(["hashes/airbnb.sha256": Data(hash.utf8)])
            let invoker = FakeInvoker()
            // Same calendar, new generation timestamp — what every poll sees.
            let restamped = feed(stamp: "20261109T094500Z")
            let handler = FetchHandler(
                context: fetchContext(),
                fetcher: StubFetcher(
                    responses: ["https://a/": FeedResponse(text: restamped, httpStatus: 200)],
                    failures: []),
                objects: objects, invoker: invoker)
            let outcome = try handler.run(sources: [.init(name: "airbnb", url: "https://a/")])
            expect.equal(outcome.unchanged, ["airbnb"])
            expect.equal(invoker.invocations.count, 0)
        },

        TestCase(group: "Lambda handlers",
                 name: "a real change wakes the processor and stores the payload") { expect in
            let objects = FakeObjects(["hashes/airbnb.sha256": Data("stale".utf8)])
            let invoker = FakeInvoker()
            let handler = FetchHandler(
                context: fetchContext(),
                fetcher: StubFetcher(
                    responses: ["https://a/": FeedResponse(
                        text: feed(stamp: "s", summary: "Blocked"), httpStatus: 200)],
                    failures: []),
                objects: objects, invoker: invoker)
            let outcome = try handler.run(sources: [.init(name: "airbnb", url: "https://a/")])
            expect.equal(outcome.changed, ["airbnb"])
            expect.equal(invoker.invocations.count, 1)
            expect.ok(objects.stored.keys.contains { $0.hasPrefix("payloads/airbnb/") },
                      "the raw payload is kept for forensics")
            expect.ok(objects.stored["hashes/airbnb.sha256"] != nil, "the new hash is recorded")
        },

        TestCase(group: "Lambda handlers",
                 name: "a failed fetch records the failure and wakes nothing") { expect in
            let objects = FakeObjects()
            let invoker = FakeInvoker()
            let handler = FetchHandler(
                context: fetchContext(),
                fetcher: StubFetcher(responses: [:], failures: ["https://a/"]),
                objects: objects, invoker: invoker)
            let outcome = try handler.run(sources: [.init(name: "airbnb", url: "https://a/")])
            expect.equal(outcome.failed.count, 1)
            expect.equal(outcome.changed.count, 0)
            expect.equal(invoker.invocations.count, 0,
                         "a failed fetch must not start a reconciliation")
            expect.ok(objects.stored.isEmpty, "and must not overwrite the recorded hash")
        },

        TestCase(group: "Lambda handlers",
                 name: "a 304 Not Modified ends the cycle before parsing") { expect in
            let invoker = FakeInvoker()
            let handler = FetchHandler(
                context: fetchContext(),
                fetcher: StubFetcher(
                    responses: ["https://a/": FeedResponse(text: "", httpStatus: 304)],
                    failures: []),
                objects: FakeObjects(), invoker: invoker)
            let outcome = try handler.run(sources: [.init(name: "airbnb", url: "https://a/")])
            expect.equal(outcome.notModified, ["airbnb"])
            expect.equal(invoker.invocations.count, 0)
        },

        // --- Publisher: four gates ---

        TestCase(group: "Lambda handlers",
                 name: "publication is refused while the code gate is closed") { expect in
            expect.ok(!OutboundSyncGate.isEnabled,
                      "this test is only meaningful while the gate is shut")
            let handler = PublishHandler(
                context: ServiceContext(actor: "owner", environment: ["VRC_OUTBOUND_ENABLED": "true"]),
                objects: FakeObjects(), invalidator: FakeInvalidator())
            let outcome = try handler.publish(
                destination: .vrbo, propertyID: 1, propertyName: "39 G Street",
                sourceEvents: [classified(.ownerBlock)], decisions: [decision(.approved)],
                objectKey: "feeds/x.ics", revision: 1)
            expect.equal(outcome.stage, .refused)
            expect.ok(outcome.detail.contains("OutboundSyncGate"))
            expect.ok(!outcome.isRemoteSynchronised)
        },

        TestCase(group: "Lambda handlers",
                 name: "publication is refused while the environment gate is closed") { expect in
            let handler = PublishHandler(
                context: ServiceContext(actor: "owner", environment: ["VRC_OUTBOUND_ENABLED": "false"]),
                objects: FakeObjects(), invalidator: FakeInvalidator())
            let outcome = try handler.publish(
                destination: .vrbo, propertyID: 1, propertyName: "39 G Street",
                sourceEvents: [], decisions: [decision(.approved)],
                objectKey: "feeds/x.ics", revision: 1)
            expect.equal(outcome.stage, .refused)
        },

        TestCase(group: "Lambda handlers",
                 name: "an unapproved decision is never published") { expect in
            for status in [AvailabilityStatus.draft, .validated, .awaitingApproval, .cancelled] {
                let handler = PublishHandler(
                    context: ServiceContext(actor: "owner",
                                            environment: ["VRC_OUTBOUND_ENABLED": "true"]),
                    objects: FakeObjects(), invalidator: FakeInvalidator())
                let outcome = try handler.publish(
                    destination: .vrbo, propertyID: 1, propertyName: "p",
                    sourceEvents: [], decisions: [decision(status)],
                    objectKey: "feeds/x.ics", revision: 1)
                expect.equal(outcome.stage, .refused, "\(status.rawValue) must not publish")
            }
        },

        TestCase(group: "Lambda handlers",
                 name: "a decision for another destination is not published here") { expect in
            var other = decision(.approved)
            other.destination = .airbnb
            let handler = PublishHandler(
                context: ServiceContext(actor: "owner", environment: ["VRC_OUTBOUND_ENABLED": "true"]),
                objects: FakeObjects(), invalidator: FakeInvalidator())
            let outcome = try handler.publish(
                destination: .vrbo, propertyID: 1, propertyName: "p",
                sourceEvents: [], decisions: [other],
                objectKey: "feeds/x.ics", revision: 1)
            expect.equal(outcome.stage, .refused)
        },

        // --- Sweeper ---

        TestCase(group: "Lambda handlers",
                 name: "the sweeper only ever touches expired, unreleased holds") { expect in
            let transport = RecordingDataAPITransport(responses: [
                .init(statusCode: 200, payload: ["transactionId": "t1"]),
                .init(statusCode: 200, payload: [:]),
                .init(statusCode: 200, payload: ["numberOfRecordsUpdated": 3]),
                .init(statusCode: 200, payload: [:]),
            ])
            let store = DataAPIStore(
                transport: transport,
                configuration: .init(resourceArn: "a", secretArn: "b", database: "vrc",
                                     actor: "owner"),
                sleeper: { _ in })
            let outcome = try SweeperHandler(
                context: ServiceContext(actor: "owner", environment: [:])).run(store: store)
            expect.equal(outcome.holdsReleased, 3)
            let sql = transport.executedSQL.joined(separator: " ")
            expect.ok(sql.contains("UPDATE holds"), "it updates holds")
            expect.ok(sql.contains("released_at IS NULL"), "only unreleased ones")
            expect.ok(sql.contains("expires_at <= now()"), "and only expired ones")
            expect.ok(!sql.lowercased().contains("reservations"),
                      "it must never touch the reservations table")
        },

        // --- API ---

        TestCase(group: "Lambda handlers",
                 name: "an unsigned API request is refused") { expect in
            let store = DataAPIStore(
                transport: RecordingDataAPITransport(),
                configuration: .init(resourceArn: "a", secretArn: "b", database: "vrc"),
                sleeper: { _ in })
            let response = ApiHandler(context: ServiceContext(actor: "owner", environment: [:]))
                .handle(.init(method: "GET", path: "/status", principal: nil, body: [:]),
                        store: store)
            let decoded = LambdaJSON.object(response)
            expect.equal(decoded["statusCode"] as? Int, 401)
        },

        TestCase(group: "Lambda handlers",
                 name: "the API parses the gateway's IAM principal") { expect in
            let request = ApiHandler.Request(event: [
                "requestContext": [
                    "http": ["method": "get", "path": "/status"],
                    "authorizer": ["iam": ["userArn": "arn:aws:iam::1:user/vrc-mac-client"]],
                ],
            ])
            expect.equal(request.method, "GET")
            expect.equal(request.principal, "arn:aws:iam::1:user/vrc-mac-client")
        },

        TestCase(group: "Lambda handlers",
                 name: "an unreachable database is 503, never an empty all-clear") { expect in
            // The dangerous failure: reporting zero conflicts because the
            // database could not be read.
            let transport = RecordingDataAPITransport(responses: [
                .init(statusCode: 400, payload: [
                    "__type": "BadRequestException", "message": "no",
                ]),
            ])
            let store = DataAPIStore(
                transport: transport,
                configuration: .init(resourceArn: "a", secretArn: "b", database: "vrc",
                                     maxAttempts: 1),
                sleeper: { _ in })
            let response = ApiHandler(context: ServiceContext(actor: "owner", environment: [:]))
                .handle(.init(method: "GET", path: "/status",
                              principal: "arn:aws:iam::1:user/vrc-mac-client", body: [:]),
                        store: store)
            let decoded = LambdaJSON.object(response)
            expect.equal(decoded["statusCode"] as? Int, 503)
            let body = LambdaJSON.object(Data((decoded["body"] as? String ?? "").utf8))
            expect.ok(body["remoteSynchronised"] as? Bool == false)
        },

        TestCase(group: "Lambda handlers",
                 name: "status never claims a platform has read the feed") { expect in
            let transport = RecordingDataAPITransport(responses: [
                .init(statusCode: 200, payload: ["columnMetadata": [["name": "c"]],
                                                 "records": [[["longValue": NSNumber(value: 7)]]]]),
                .init(statusCode: 200, payload: ["columnMetadata": [["name": "c"]],
                                                 "records": [[["longValue": NSNumber(value: 2)]]]]),
                .init(statusCode: 200, payload: ["columnMetadata": [["name": "c"]],
                                                 "records": [[["longValue": NSNumber(value: 0)]]]]),
                .init(statusCode: 200, payload: ["columnMetadata": [["name": "c"]],
                                                 "records": [[["longValue": NSNumber(value: 0)]]]]),
                .init(statusCode: 200, payload: ["columnMetadata": [["name": "at"]],
                                                 "records": [[["isNull": true]]]]),
            ])
            let store = DataAPIStore(
                transport: transport,
                configuration: .init(resourceArn: "a", secretArn: "b", database: "vrc"),
                sleeper: { _ in })
            let response = ApiHandler(context: ServiceContext(actor: "owner", environment: [:]))
                .handle(.init(method: "GET", path: "/status",
                              principal: "arn:aws:iam::1:user/x", body: [:]),
                        store: store)
            let body = LambdaJSON.object(
                Data((LambdaJSON.object(response)["body"] as? String ?? "").utf8))
            expect.equal(body["liveSourceEvents"] as? Int, 7)
            expect.equal(body["approvedDecisions"] as? Int, 2)
            expect.ok(body["remoteSynchronised"] as? Bool == false,
                      "publishing is not importing, and the Mac must not be told otherwise")
            expect.ok(body["outboundEnabled"] as? Bool == false)
        },

        TestCase(group: "Lambda handlers", name: "an unknown route is 404") { expect in
            let store = DataAPIStore(
                transport: RecordingDataAPITransport(),
                configuration: .init(resourceArn: "a", secretArn: "b", database: "vrc"),
                sleeper: { _ in })
            let response = ApiHandler(context: ServiceContext(actor: "owner", environment: [:]))
                .handle(.init(method: "DELETE", path: "/everything",
                              principal: "arn:aws:iam::1:user/x", body: [:]),
                        store: store)
            expect.equal(LambdaJSON.object(response)["statusCode"] as? Int, 404)
        },

        // --- Process ---

        TestCase(group: "Lambda handlers",
                 name: "an empty parsed feed withdraws nothing") { expect in
            let objects = FakeObjects([
                "payloads/airbnb/1.ics": Data("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR".utf8),
            ])
            let store = DataAPIStore(
                transport: RecordingDataAPITransport(),
                configuration: .init(resourceArn: "a", secretArn: "b", database: "vrc"),
                sleeper: { _ in })
            let outcome = try ProcessHandler(
                context: ServiceContext(actor: "importer", environment: [:]), objects: objects)
                .run(source: "airbnb", payloadKey: "payloads/airbnb/1.ics", store: store)
            expect.equal(outcome.withdrawn, 0)
            expect.ok(outcome.detail.contains("empty feed"),
                      "and says why, rather than looking like a clean import")
        },

        TestCase(group: "Lambda handlers",
                 name: "every BlockKind maps to a block_kind enum value") { expect in
            // A new kind that fell through would be a runtime failure in the
            // importer, so the mapping is exhaustive by construction.
            let handler = ProcessHandler(
                context: ServiceContext(actor: "importer", environment: [:]),
                objects: FakeObjects())
            let expected = ["confirmed_reservation", "owner_block", "maintenance_block",
                            "cancellation_block", "platform_restriction", "unknown_unavailable"]
            let mapped = BlockKind.allCases.map { handler.postgresKind($0) }
            expect.equal(Set(mapped), Set(expected))
            expect.equal(mapped.count, BlockKind.allCases.count)
        },
    ] }
}
