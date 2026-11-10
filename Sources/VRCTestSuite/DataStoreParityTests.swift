import Foundation
import VRCCore

/// Proves `DataAPIStore` is a faithful `DataStore`, by running the *same*
/// repository workflows through it and through SQLite and comparing the
/// results.
///
/// The transport below executes each Data API call against a real SQLite
/// database. That is not a mock: the SQL, the parameter binding, the
/// placeholder rewriting, the row decoding, the generated-id capture and the
/// transaction bracketing all run for real. What it removes is the network and
/// the Postgres dialect, so the thing under test is the store, not the schema.
///
/// This is how "the repositories work through both implementations" is
/// established without a cluster. What it deliberately does NOT prove is that
/// the repositories' SQL runs against the Postgres *schema* — that needs
/// schema convergence, and is listed as outstanding.
public enum DataStoreParityTests {

    /// A `DataAPITransport` backed by a real SQLite database.
    final class SQLiteBackedTransport: DataAPITransport, @unchecked Sendable {
        private let database: Database
        private let lock = NSLock()
        private var openTransaction: String?
        var executed: [String] = []

        init(_ database: Database) { self.database = database }

        func send(_ call: DataAPICall) throws -> DataAPIResult {
            lock.lock(); defer { lock.unlock() }

            switch call.action {
            case .beginTransaction:
                try database.execute("BEGIN")
                let id = "sqlite-txn-\(UUID().uuidString)"
                openTransaction = id
                return DataAPIResult(statusCode: 200, payload: ["transactionId": id])

            case .commitTransaction:
                try database.execute("COMMIT")
                openTransaction = nil
                return DataAPIResult(statusCode: 200, payload: [:])

            case .rollbackTransaction:
                try database.execute("ROLLBACK")
                openTransaction = nil
                return DataAPIResult(statusCode: 200, payload: [:])

            case .execute:
                guard let named = call.body["sql"] as? String else {
                    return DataAPIResult(statusCode: 400, payload: ["message": "no sql"])
                }
                // Postgres-only session setting; harmless to skip here, and
                // skipping it is what the real Postgres would do differently.
                if named.contains("set_config('vrc.actor'") {
                    return DataAPIResult(statusCode: 200, payload: ["numberOfRecordsUpdated": 0])
                }

                let (sql, values) = Self.toPositional(named, call.body["parameters"])
                executed.append(sql)

                let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if trimmed.hasPrefix("SELECT") || trimmed.hasPrefix("WITH") {
                    let rows = try database.query(sql, values)
                    // Metadata and records must agree on order; the names come
                    // from the row itself, sorted so it is deterministic.
                    let names = rows.first.map { Array($0.values.keys).sorted() } ?? []
                    return DataAPIResult(statusCode: 200, payload: [
                        "columnMetadata": names.map { ["name": $0] },
                        "records": rows.map { row in
                            names.map { Self.field(row.values[$0] ?? .null) }
                        },
                    ])
                }

                let affected = try database.run(sql, values)
                var payload: [String: Any] = ["numberOfRecordsUpdated": affected]
                if trimmed.hasPrefix("INSERT") {
                    payload["generatedFields"] = [["longValue": database.lastInsertRowID]]
                }
                return DataAPIResult(statusCode: 200, payload: payload)
            }
        }

        /// Turns `:p0` back into `?` and rebuilds the ordered value list, so
        /// the rewriter in `SQLScanner` is exercised in both directions.
        static func toPositional(_ sql: String, _ raw: Any?) -> (String, [SQLValue]) {
            let parameters = (raw as? [[String: Any]]) ?? []
            var byName: [String: SQLValue] = [:]
            for parameter in parameters {
                guard let name = parameter["name"] as? String,
                      let value = parameter["value"] as? [String: Any] else { continue }
                byName[name] = DataAPIStore.decodeField(value)
            }
            var output = ""
            var values: [SQLValue] = []
            var index = sql.startIndex
            while index < sql.endIndex {
                if sql[index] == ":" {
                    var scan = sql.index(after: index)
                    var name = ""
                    while scan < sql.endIndex,
                          sql[scan].isLetter || sql[scan].isNumber || sql[scan] == "_" {
                        name.append(sql[scan]); scan = sql.index(after: scan)
                    }
                    if let value = byName[name] {
                        output.append("?")
                        values.append(value)
                        index = scan
                        continue
                    }
                }
                output.append(sql[index])
                index = sql.index(after: index)
            }
            return (output, values)
        }

        static func field(_ value: SQLValue) -> [String: Any] {
            switch value {
            case .null: return ["isNull": true]
            case .integer(let v): return ["longValue": v]
            case .real(let v): return ["doubleValue": v]
            case .text(let v): return ["stringValue": v]
            case .blob(let v): return ["blobValue": v.base64EncodedString()]
            }
        }
    }

    /// A migrated SQLite database to stand behind the Data API transport. The
    /// cloud path does not run the SQLite migrator -- Postgres is migrated by
    /// the numbered files -- so the schema is created here first, exactly as a
    /// real cluster would arrive already migrated.
    static func migratedBacking() throws -> Database {
        let database = try Database.inMemory()
        try Migrator.migrate(database)
        return database
    }

    static func cloudStore(over database: Database) -> DataAPIStore {
        DataAPIStore(
            transport: SQLiteBackedTransport(database),
            configuration: .init(resourceArn: "arn:local", secretArn: "arn:local",
                                 database: "vrc", actor: "owner"),
            sleeper: { _ in })
    }

    /// The same workflow, run against whichever store it is given. Returns a
    /// canonical description so two runs can be compared exactly.
    static func workflow(_ store: RentalStore) throws -> String {
        var report = ""
        func line(_ text: String) { report += text + "\n" }

        let property = try store.properties.insert(Property(name: "39 G Street"))
        let propertyID = property.id!
        let listing = try store.listings.insert(PlatformListing(
            propertyID: propertyID, platform: .airbnb, label: "Airbnb — 39 G Street",
            icalURL: "https://example.test/a.ics", urlStorage: .database,
            connectionState: .connected))
        line("property=\(property.name) listing=\(listing.platform.rawValue)")

        // Two events whose handling differs: one genuine reservation, one
        // cancellation penalty that must never become exportable.
        for (key, kind, from, to) in [
            ("w-res", BlockKind.confirmedReservation, (2027, 3, 1), (2027, 3, 5)),
            ("w-cancel", BlockKind.cancellationBlock, (2027, 3, 10), (2027, 3, 12)),
        ] {
            let calendarEvent = CalendarEvent(
                listingID: listing.id!, eventKey: key, uid: key, platform: .airbnb,
                summary: kind == .confirmedReservation ? "Reserved" : "Airbnb (Not available)",
                details: "", checkIn: DayMath.day(from.0, from.1, from.2),
                checkOut: DayMath.day(to.0, to.1, to.2))
            _ = try store.events.upsert(calendarEvent)
            try store.classifications.save(EventClassification(
                eventKey: key, kind: kind, confidence: .high, source: .manual,
                needsReview: false, exportApproved: kind != .confirmedReservation))
            line("event \(key) nights=\(calendarEvent.nights) kind=\(kind.rawValue) "
                + "genuine=\(kind.describesGenuineUnavailability)")
        }

        // Date intervals, through the repository rather than recomputed.
        for item in try store.classifiedEvents().sorted(by: { $0.event.eventKey < $1.event.eventKey }) {
            line("interval \(item.event.eventKey) "
                + "\(DayMath.icalDateString(item.event.checkIn))→"
                + "\(DayMath.icalDateString(item.event.checkOut)) "
                + "nights=\(item.event.nights) kind=\(item.classification.kind.rawValue)")
        }

        // An availability decision and its audit trail.
        let decision = try store.availability.insert(AvailabilityDecision(
            propertyID: propertyID, destination: .vrbo, action: .block,
            startDay: DayMath.day(2026, 12, 10), endDay: DayMath.day(2026, 12, 17),
            status: .draft, publicationUID: "vrc-parity-workflow"))
        line("decision \(decision.publicationUID) \(decision.status.rawValue) "
            + "nights=\(decision.nights)")

        _ = try store.auditLog.record(AuditEntry(
            decisionID: decision.id, at: Date(timeIntervalSince1970: 1_764_000_000),
            actor: "owner", fromStatus: nil, toStatus: AvailabilityStatus.draft,
            event: "created", detail: "created by the parity workflow"))
        for entry in try store.auditLog.entries(forDecision: decision.id!) {
            line("audit actor=\(entry.actor) to=\(entry.toStatus?.rawValue ?? "-") "
                + "detail=\(entry.detail)")
        }

        line("counts events=\(try store.events.allActive().count) "
            + "decisions=\(try store.availability.all().count)")
        return report
    }

    public static var cases: [TestCase] { [

        TestCase(group: "DataStore parity",
                 name: "a repository workflow is identical through SQLite and the Data API store") { expect in
            // Same code, same inputs, two different DataStore implementations.
            let direct = try RentalStore.makeInMemory()
            let directReport = try workflow(direct)

            let backing = try migratedBacking()
            let cloud = try RentalStore(
                database: cloudStore(over: backing), credentials: InMemoryFeedCredentialStore())
            let cloudReport = try workflow(cloud)

            if directReport != cloudReport {
                let a = directReport.split(separator: "\n")
                let b = cloudReport.split(separator: "\n")
                for (index, line) in a.enumerated() where index >= b.count || b[index] != line {
                    expect.fail("line \(index + 1): SQLite=\"\(line)\" "
                        + "DataAPI=\"\(index < b.count ? String(b[index]) : "<missing>")\"")
                }
            }
            expect.equal(cloudReport, directReport,
                         "the two stores must produce identical results")
            expect.ok(!directReport.isEmpty, "the workflow actually did something")
        },

        TestCase(group: "DataStore parity",
                 name: "the Data API store really did the work, not a short circuit") { expect in
            // Guards against the previous test passing because both paths were
            // secretly the same object.
            let backing = try migratedBacking()
            let transport = SQLiteBackedTransport(backing)
            let store = DataAPIStore(
                transport: transport,
                configuration: .init(resourceArn: "a", secretArn: "b", database: "vrc",
                                     actor: "owner"),
                sleeper: { _ in })
            let rental = try RentalStore(
                database: store, credentials: InMemoryFeedCredentialStore())
            _ = try rental.properties.insert(Property(name: "Check"))
            expect.ok(transport.executed.count > 0,
                      "statements went through the Data API encoding")
            expect.ok(transport.executed.contains { $0.contains("INSERT INTO properties") },
                      "including the repository's own INSERT")
            expect.ok(transport.executed.contains { $0.contains("?") },
                      "placeholders round-tripped :p0 -> ? so values stayed parameterised")
        },

        TestCase(group: "DataStore parity",
                 name: "generated ids survive the Data API round trip") { expect in
            let backing = try migratedBacking()
            let rental = try RentalStore(
                database: cloudStore(over: backing), credentials: InMemoryFeedCredentialStore())
            let first = try rental.properties.insert(Property(name: "One"))
            let second = try rental.properties.insert(Property(name: "Two"))
            expect.ok(first.id != nil && second.id != nil, "both got ids")
            expect.ok(second.id! > first.id!, "and they are distinct and increasing")
        },

        TestCase(group: "DataStore parity",
                 name: "a rolled-back repository transaction leaves nothing behind") { expect in
            struct Nope: Error {}
            let backing = try migratedBacking()
            let rental = try RentalStore(
                database: cloudStore(over: backing), credentials: InMemoryFeedCredentialStore())
            let before = try rental.properties.all().count
            do {
                try rental.database.transaction {
                    _ = try rental.properties.insert(Property(name: "Doomed"))
                    throw Nope()
                }
                expect.fail("must throw")
            } catch is Nope { /* correct */ }
            expect.equal(try rental.properties.all().count, before,
                         "the insert was rolled back through the Data API path")
        },
    ] }
}
