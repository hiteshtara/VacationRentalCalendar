import Foundation
import VRCCore

/// Runs the real repository layer against a real PostgreSQL cluster.
///
/// Enabled by `VRC_PG_PORT`; skipped, with a note, when it is absent, so the
/// ordinary suite still runs on a machine with no database.
///
/// The transport below drives a **persistent** `psql` session over pipes, so
/// `BEGIN`/`COMMIT` actually span statements. A fresh `psql -c` per statement
/// would make every transaction test silently meaningless, which is worse than
/// not having them.
///
/// What this does not exercise is the Data API's own parameter transport —
/// values are rendered as properly-escaped PostgreSQL literals here, because
/// `psql` has no bind-parameter interface. That half is covered by the
/// DataStore tests, which assert the real path sends typed parameters and
/// never interpolates.
public enum PostgresIntegrationTests {

    static var port: String? {
        ProcessInfo.processInfo.environment["VRC_PG_PORT"]
    }

    // MARK: A persistent psql session

    public final class PsqlTransport: DataAPITransport, @unchecked Sendable {
        private let lock = NSLock()
        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        // A String accumulator rather than Data: Data's indices do not
        // re-base after removeFirst, which made the obvious implementation
        // crash on the second statement.
        private var pending = ""
        private static let marker = "__VRC_END__"
        var statements: [String] = []

        public init(port: String, database: String = "vrc", user: String = "vrctest") throws {
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/opt/postgresql@17/bin/psql")
            process.arguments = [
                "-h", "127.0.0.1", "-p", port, "-U", user, "-d", database,
                "-X",            // no .psqlrc
                "-q",            // no chatter
                "--csv",         // parseable rows, with a header
                "-v", "ON_ERROR_STOP=off",
            ]
            process.standardInput = input
            // One pipe for both, so an ERROR cannot be read out of order with
            // the rows it belongs to.
            process.standardOutput = output
            process.standardError = output
            try process.run()
        }

        deinit {
            input.fileHandleForWriting.write(Data("\\q\n".utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }

        private func run(_ sql: String) -> [String] {
            let statement = sql.trimmingCharacters(in: .whitespacesAndNewlines)
            let terminated = statement.hasSuffix(";") ? statement : statement + ";"
            input.fileHandleForWriting.write(
                Data((terminated + "\n\\echo " + Self.marker + "\n").utf8))

            let sentinel = Self.marker + "\n"
            while pending.range(of: sentinel) == nil {
                let more = output.fileHandleForReading.availableData
                if more.isEmpty { break }
                pending += String(data: more, encoding: .utf8) ?? ""
            }
            guard let found = pending.range(of: sentinel) else {
                let all = pending; pending = ""
                return all.split(separator: "\n").map(String.init)
            }
            let chunk = String(pending[pending.startIndex..<found.lowerBound])
            pending = String(pending[found.upperBound...])
            return chunk.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }

        public func send(_ call: DataAPICall) throws -> DataAPIResult {
            lock.lock(); defer { lock.unlock() }

            switch call.action {
            case .beginTransaction:
                _ = run("BEGIN")
                return DataAPIResult(statusCode: 200, payload: ["transactionId": "psql"])
            case .commitTransaction:
                let lines = run("COMMIT")
                if lines.contains(where: { $0.hasPrefix("ERROR:") }) {
                    return DataAPIResult(statusCode: 400,
                                         payload: ["message": lines.joined(separator: " ")])
                }
                return DataAPIResult(statusCode: 200, payload: [:])
            case .rollbackTransaction:
                _ = run("ROLLBACK")
                return DataAPIResult(statusCode: 200, payload: [:])
            case .execute:
                guard let named = call.body["sql"] as? String else {
                    return DataAPIResult(statusCode: 400, payload: ["message": "no sql"])
                }
                let sql = Self.inline(named, call.body["parameters"])
                statements.append(sql)

                let upper = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                let producesRows = upper.hasPrefix("SELECT") || upper.hasPrefix("WITH")
                    || upper.contains("RETURNING")

                let lines: [String]
                if producesRows {
                    lines = run(sql)
                } else if upper.hasPrefix("UPDATE") || upper.hasPrefix("DELETE")
                            || upper.hasPrefix("INSERT") {
                    // A data-modifying CTE turns the row count into a result
                    // row, which is the only way to read it back over psql.
                    lines = run("WITH _vrc AS (\(sql.hasSuffix(";") ? String(sql.dropLast()) : sql)"
                        + " RETURNING 1) SELECT count(*) AS numberOfRecordsUpdated FROM _vrc")
                } else {
                    lines = run(sql)
                }

                if let error = lines.first(where: { $0.hasPrefix("ERROR:") }) {
                    return DataAPIResult(statusCode: 400, payload: ["message": error])
                }
                return DataAPIResult(statusCode: 200, payload: Self.decode(lines))
            }
        }

        /// CSV with a header, back into the Data API's record shape.
        static func decode(_ lines: [String]) -> [String: Any] {
            guard let header = lines.first else { return ["numberOfRecordsUpdated": 0] }
            let names = splitCSV(header)
            let records = lines.dropFirst().map { line in
                splitCSV(line).map { value -> [String: Any] in
                    value == "" ? ["isNull": true] : ["stringValue": value]
                }
            }
            if names.count == 1, names[0].lowercased() == "numberofrecordsupdated" {
                let count = records.first?.first?["stringValue"] as? String ?? "0"
                return ["numberOfRecordsUpdated": Int(count) ?? 0]
            }
            return [
                "columnMetadata": names.map { ["name": $0] },
                "records": records,
                "numberOfRecordsUpdated": records.count,
            ]
        }

        static func splitCSV(_ line: String) -> [String] {
            var fields: [String] = []
            var current = ""
            var quoted = false
            var index = line.startIndex
            while index < line.endIndex {
                let character = line[index]
                if quoted {
                    if character == "\"" {
                        let next = line.index(after: index)
                        if next < line.endIndex, line[next] == "\"" {
                            current.append("\""); index = line.index(after: next); continue
                        }
                        quoted = false
                    } else { current.append(character) }
                } else if character == "\"" {
                    quoted = true
                } else if character == "," {
                    fields.append(current); current = ""
                } else {
                    current.append(character)
                }
                index = line.index(after: index)
            }
            fields.append(current)
            return fields
        }

        /// Renders `:pN` as escaped PostgreSQL literals. `psql` offers no bind
        /// interface; the typed-parameter path is asserted in DataStoreTests.
        static func inline(_ sql: String, _ raw: Any?) -> String {
            let parameters = (raw as? [[String: Any]]) ?? []
            var byName: [String: String] = [:]
            for parameter in parameters {
                guard let name = parameter["name"] as? String,
                      let value = parameter["value"] as? [String: Any] else { continue }
                byName[name] = literal(DataAPIStore.decodeField(value))
            }
            var output = ""
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
                        output += value; index = scan; continue
                    }
                }
                output.append(sql[index]); index = sql.index(after: index)
            }
            return output
        }

        static func literal(_ value: SQLValue) -> String {
            switch value {
            case .null: return "NULL"
            case .integer(let v): return String(v)
            case .real(let v): return String(v)
            case .text(let v): return "'" + v.replacingOccurrences(of: "'", with: "''") + "'"
            case .blob(let v): return "'\\x" + v.map { String(format: "%02x", $0) }.joined() + "'"
            }
        }
    }

    // MARK: Fixtures

    /// True when the suite is pointed at a real Aurora cluster rather than a
    /// local PostgreSQL. Set VRC_CLUSTER_ARN, VRC_DB_SECRET_ARN and
    /// VRC_DB_NAME to use the Data API, which is the path the Lambdas use.
    static var usingAurora: Bool {
        ProcessInfo.processInfo.environment["VRC_CLUSTER_ARN"] != nil
            && ProcessInfo.processInfo.environment["VRC_DB_SECRET_ARN"] != nil
    }

    /// Every table the setup empties, in dependency order so foreign keys do
    /// not block the clean-up.
    ///
    /// `app_settings` is deliberately absent: it carries the disposable marker
    /// that authorizes this truncation, and emptying it would revoke the
    /// permission on the way through.
    static let truncatedTables = [
        "published_feed_entries", "feed_publications", "feed_snapshots",
        "conflicts", "holds", "reservations", "availability_audit",
        "availability_decisions", "classifications", "events",
        "listing_connection_events", "sync_runs", "platform_listings",
        "properties", "conflict_acknowledgements", "feed_tokens",
        "idempotency_keys",
    ]

    /// **The only place in this suite that deletes rows.**
    ///
    /// `DestructiveTestIsolation` is checked *inside* this function rather than
    /// left as a precondition each caller must remember, because a guard you
    /// can forget to call is a guard that will eventually be forgotten. There
    /// is no path to the DELETEs that does not pass through here, which is the
    /// actual fix for 2026-11-09 — the tests of the guard itself prove only
    /// that it answers correctly when asked.
    ///
    /// Reading the marker first is safe: it is a SELECT, and it happens before
    /// anything is deleted.
    static func truncateForTest(
        _ store: DataAPIStore,
        target: DestructiveTestIsolation.Target,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try DestructiveTestIsolation.assertDisposable(
            target, environment: environment,
            marker: {
                try store.queryOne(
                    "SELECT value FROM app_settings WHERE key = ?",
                    [.text(DestructiveTestIsolation.markerKey)])?.string("value")
            })
        for table in truncatedTables {
            _ = try? store.run("DELETE FROM \(table)")
        }
    }

    /// The cluster identifier — the last component of the ARN. A missing or
    /// unparseable ARN yields an empty identifier, which the guard refuses.
    static func clusterIdentifier(_ environment: [String: String]) -> String {
        guard let arn = environment["VRC_CLUSTER_ARN"] else { return "" }
        return arn.split(separator: ":").last.map(String.init) ?? ""
    }

    /// A store over the real Data API. Rows are cleaned between cases the same
    /// way the psql path does, so the two produce comparable results.
    static func auroraStore() throws -> RentalStore {
        let environment = ProcessInfo.processInfo.environment
        var configuration = try DataAPIStore.Configuration.fromEnvironment(environment)
        configuration.actor = "owner"
        let store = DataAPIStore(
            transport: try URLSessionDataAPITransport.fromEnvironment(environment),
            configuration: configuration)
        try truncateForTest(
            store, target: .cluster(identifier: clusterIdentifier(environment)),
            environment: environment)
        return try RentalStore(database: store, credentials: InMemoryFeedCredentialStore(),
                               skipMigration: true)
    }

    static func freshStore() throws -> (RentalStore, PsqlTransport)? {
        guard let port else { return nil }
        let transport = try PsqlTransport(port: port)
        let store = DataAPIStore(
            transport: transport,
            configuration: .init(resourceArn: "arn:local", secretArn: "arn:local",
                                 database: "vrc", actor: "owner"),
            sleeper: { _ in })
        // Through the same single door as the Aurora path. A local port is not
        // a safe harbour: a tunnel can put a shared cluster behind 127.0.0.1,
        // so the label is deny-listed and the marker is required here too.
        try truncateForTest(store, target: .local(label: "127.0.0.1:\(port)/vrc"))
        return (try RentalStore(database: store, credentials: InMemoryFeedCredentialStore()),
                transport)
    }

    /// Whichever backend is configured: Aurora if the cluster variables are
    /// set, local PostgreSQL otherwise.
    static func backend() throws -> RentalStore? {
        if usingAurora { return try auroraStore() }
        return try freshStore()?.0
    }

    /// A second, independent session on the same database.
    ///
    /// Deliberately does **no** clean-up: the caller has already prepared the
    /// rows, and a second truncation would delete the very property the race
    /// is about. Each call builds its own transport, so two of these contend
    /// the way two Lambda invocations do — one connection each, nothing in
    /// Swift coordinating them.
    static func sibling() throws -> RentalStore? {
        let environment = ProcessInfo.processInfo.environment
        if usingAurora {
            var configuration = try DataAPIStore.Configuration.fromEnvironment(environment)
            configuration.actor = "owner"
            return try RentalStore(
                database: DataAPIStore(
                    transport: try URLSessionDataAPITransport.fromEnvironment(environment),
                    configuration: configuration),
                credentials: InMemoryFeedCredentialStore(), skipMigration: true)
        }
        guard let port else { return nil }
        return try RentalStore(
            database: DataAPIStore(
                transport: try PsqlTransport(port: port),
                configuration: .init(resourceArn: "arn:local", secretArn: "arn:local",
                                     database: "vrc", actor: "owner"),
                sleeper: { _ in }),
            credentials: InMemoryFeedCredentialStore(), skipMigration: true)
    }

    /// Two sessions each try to claim `nights` for `property`, released
    /// together so both are in flight at once. Returns how many the database
    /// accepted and the refusals it gave the rest.
    static func race(
        _ sessions: [RentalStore], property: Int64, checkIn: Date, checkOut: Date
    ) -> (accepted: Int, refusals: [String]) {
        let start = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var accepted = 0
        var refusals: [String] = []

        for (index, session) in sessions.enumerated() {
            DispatchQueue.global().async {
                start.wait()
                do {
                    _ = try session.database.run("""
                        INSERT INTO holds (property_id, channel, check_in, check_out,
                                           expires_at, external_ref, created_at)
                        VALUES (?, 'race', ?, ?, now() + interval '1 day', ?,
                                extract(epoch from now()))
                        """,
                        [.integer(property), .real(checkIn.timeIntervalSince1970),
                         .real(checkOut.timeIntervalSince1970), .text("race-\(index)")])
                    lock.lock(); accepted += 1; lock.unlock()
                } catch {
                    lock.lock(); refusals.append("\(error)"); lock.unlock()
                }
                finished.signal()
            }
        }
        for _ in sessions { start.signal() }
        for _ in sessions { finished.wait() }
        return (accepted, refusals)
    }

    static func liveHolds(_ store: RentalStore, property: Int64) throws -> Int {
        try store.database.query(
            "SELECT external_ref FROM holds WHERE property_id = ? AND released_at IS NULL",
            [.integer(property)]).count
    }

    static func skipped(_ expect: Expect) -> Bool {
        if usingAurora { return false }
        if port == nil {
            expect.ok(true, "skipped: set VRC_PG_PORT to run against PostgreSQL")
            return true
        }
        return false
    }

    /// The business outcomes, as a canonical report. Deliberately excludes ids
    /// and anything dialect-specific: what must match is the decision the
    /// business rules reach, not the serialisation.
    static func outcomes(_ store: RentalStore) throws -> String {
        var report = ""
        for item in try store.classifiedEvents()
            .sorted(by: { $0.event.eventKey < $1.event.eventKey }) {
            report += "event \(item.event.eventKey) "
                + "\(DayMath.icalDateString(item.event.checkIn))→"
                + "\(DayMath.icalDateString(item.event.checkOut)) "
                + "nights=\(item.event.nights) "
                + "kind=\(item.classification.kind.rawValue) "
                + "review=\(item.classification.needsReview) "
                + "genuine=\(item.classification.kind.describesGenuineUnavailability)\n"
        }
        for decision in try store.availability.all()
            .sorted(by: { $0.publicationUID < $1.publicationUID }) {
            report += "decision \(decision.publicationUID) "
                + "\(decision.destination.rawValue)/\(decision.action.rawValue)/"
                + "\(decision.status.rawValue) "
                + "\(DayMath.icalDateString(decision.startDay))→"
                + "\(DayMath.icalDateString(decision.endDay)) "
                + "nights=\(decision.nights)\n"
        }
        // Audit scoped to this run's decisions, not a global recent() — the
        // availability_audit table is append-only to the runtime role, so on a
        // shared cluster it accumulates across runs. Reading per current
        // decision isolates the run and makes the comparison robust. Found by
        // B5 on the real Data API.
        var auditLines: [String] = []
        for decision in try store.availability.all() {
            guard let decisionID = decision.id else { continue }
            for entry in try store.auditLog.entries(forDecision: decisionID) {
                auditLines.append("audit \(entry.actor)/\(entry.event) "
                    + "to=\(entry.toStatus?.rawValue ?? "-") detail=\(entry.detail)")
            }
        }
        for line in auditLines.sorted() { report += line + "\n" }
        return report
    }

    /// The workflow under test: the December decisions, the protected nights,
    /// a cancellation block that must stay unexportable, and an audit trail.
    static func workflow(_ store: RentalStore) throws {
        let property = try store.properties.insert(
            Property(name: "39 G Street", address: "South Boston, MA"))
        let listing = try store.listings.insert(PlatformListing(
            propertyID: property.id!, platform: .airbnb, label: "Airbnb — 39 G Street",
            icalURL: "https://example.test/a.ics", urlStorage: .database,
            connectionState: .connected))

        for (key, kind, from, to, summary) in [
            ("pg-res", BlockKind.confirmedReservation, (2027, 3, 1), (2027, 3, 5), "Reserved"),
            ("pg-cancel", BlockKind.cancellationBlock, (2026, 12, 17), (2026, 12, 19),
             "Airbnb (Not available)"),
            ("pg-owner", BlockKind.ownerBlock, (2027, 4, 1), (2027, 4, 4), "Blocked"),
        ] {
            _ = try store.events.upsert(CalendarEvent(
                listingID: listing.id!, eventKey: key, uid: key, platform: .airbnb,
                summary: summary, details: "",
                checkIn: DayMath.day(from.0, from.1, from.2),
                checkOut: DayMath.day(to.0, to.1, to.2)))
            try store.classifications.save(EventClassification(
                eventKey: key, kind: kind, confidence: .high, source: .manual,
                needsReview: false, exportApproved: kind != .confirmedReservation))
        }

        for (index, range) in [((2026, 12, 10), (2026, 12, 17)),
                               ((2026, 12, 19), (2026, 12, 20))].enumerated() {
            let decision = try store.availability.insert(AvailabilityDecision(
                propertyID: property.id!, destination: .vrbo, action: .block,
                startDay: DayMath.day(range.0.0, range.0.1, range.0.2),
                endDay: DayMath.day(range.1.0, range.1.1, range.1.2),
                status: .approved, publicationUID: "vrc-pg-\(index)",
                approvedAt: Date(timeIntervalSince1970: 1_764_000_000),
                approvedBy: "owner"))
            _ = try store.auditLog.record(AuditEntry(
                decisionID: decision.id, at: Date(timeIntervalSince1970: 1_764_000_000),
                actor: "owner", fromStatus: nil, toStatus: AvailabilityStatus.approved,
                event: "approved", detail: "approved decision \(index)"))
        }
    }

    public static var cases: [TestCase] { [

        TestCase(group: "PostgreSQL integration",
                 name: "the same repository workflow reaches the same business outcomes") { expect in
            if skipped(expect) { return }
            // SQLite, through the repositories.
            let sqlite = try RentalStore.makeInMemory()
            try workflow(sqlite)
            let sqliteOutcomes = try outcomes(sqlite)

            // PostgreSQL, through the same repositories.
            guard let postgres = try backend() else { return }
            try workflow(postgres)
            let postgresOutcomes = try outcomes(postgres)

            if sqliteOutcomes != postgresOutcomes {
                let a = sqliteOutcomes.split(separator: "\n").map(String.init)
                let b = postgresOutcomes.split(separator: "\n").map(String.init)
                for (index, line) in a.enumerated() where index >= b.count || b[index] != line {
                    expect.fail("line \(index + 1):\n  SQLite:   \(line)\n  Postgres: "
                        + (index < b.count ? b[index] : "<missing>"))
                }
                for extra in b.dropFirst(a.count) {
                    expect.fail("extra from Postgres: \(extra)")
                }
            }
            expect.equal(postgresOutcomes, sqliteOutcomes,
                         "business outcomes must be identical across dialects")
            expect.ok(sqliteOutcomes.contains("nights=7"), "the December block is 7 nights")
            expect.ok(sqliteOutcomes.contains("genuine=false"),
                      "the cancellation block is not genuine unavailability")
        },

        TestCase(group: "PostgreSQL integration",
                 name: "the generated daterange matches the repository's own night count") { expect in
            if skipped(expect) { return }
            guard let store = try backend() else { return }
            try workflow(store)

            // The repositories write epoch doubles; the constraints read a
            // daterange generated from them. If those ever disagreed, the
            // exclusion constraint would be protecting the wrong nights.
            let rows = try store.database.query("""
                SELECT event_key, upper(stay) - lower(stay) AS generated_nights
                  FROM events ORDER BY event_key
                """)
            expect.equal(rows.count, 3)
            var byKey: [String: Int] = [:]
            for row in rows { byKey[row.stringValue("event_key")] = row.intValue("generated_nights") }
            for item in try store.classifiedEvents() {
                expect.equal(byKey[item.event.eventKey], item.event.nights,
                             "generated nights must equal the repository's nights for "
                             + item.event.eventKey)
            }
        },

        TestCase(group: "PostgreSQL integration",
                 name: "December 17 and 18 are excluded by the decisions") { expect in
            if skipped(expect) { return }
            guard let store = try backend() else { return }
            try workflow(store)
            let decisions = try store.availability.all()
            for night in [DayMath.day(2026, 12, 17), DayMath.day(2026, 12, 18)] {
                let covered = decisions.contains { night >= $0.startDay && night < $0.endDay }
                expect.ok(!covered,
                          "\(DayMath.icalDateString(night)) must not be covered by any decision")
            }
            expect.equal(decisions.count, 2)
        },

        TestCase(group: "PostgreSQL integration",
                 name: "a rolled-back transaction leaves no rows") { expect in
            if skipped(expect) { return }
            struct Nope: Error {}
            guard let store = try backend() else { return }
            let before = try store.properties.all().count
            do {
                try store.database.transaction {
                    _ = try store.properties.insert(Property(name: "Doomed"))
                    _ = try store.properties.insert(Property(name: "Also doomed"))
                    throw Nope()
                }
                expect.fail("must throw")
            } catch is Nope { }
            expect.equal(try store.properties.all().count, before,
                         "a real PostgreSQL ROLLBACK undid both inserts")
        },

        TestCase(group: "PostgreSQL integration",
                 name: "a committed transaction persists every row") { expect in
            if skipped(expect) { return }
            guard let store = try backend() else { return }
            try store.database.transaction {
                _ = try store.properties.insert(Property(name: "Kept one"))
                _ = try store.properties.insert(Property(name: "Kept two"))
            }
            expect.equal(try store.properties.all().count, 2)
        },

        TestCase(group: "PostgreSQL integration",
                 name: "generated identifiers come back from RETURNING") { expect in
            if skipped(expect) { return }
            // PostgreSQL does not fill the Data API's generatedFields, so
            // without the RETURNING mapping every row would get id 0.
            guard let store = try backend() else { return }
            let first = try store.properties.insert(Property(name: "One"))
            let second = try store.properties.insert(Property(name: "Two"))
            expect.ok(first.id != nil && first.id != 0, "an id came back")
            expect.ok(second.id! > first.id!, "and they increase")
        },

        TestCase(group: "PostgreSQL integration",
                 name: "the database allow-list agrees with BlockKind, case by case") { expect in
            if skipped(expect) { return }
            // The check that would have caught the camelCase bug immediately:
            // ask the database about every BlockKind and compare with Swift.
            guard let store = try backend() else { return }
            for kind in BlockKind.allCases {
                let row = try store.database.queryOne(
                    "SELECT describes_genuine_unavailability(?) AS genuine", [.text(kind.rawValue)])
                // A PostgreSQL boolean comes back as "t"/"f" over psql but as a
                // booleanValue the Data API decodes to 1/0. Accept both so the
                // test asserts the business rule, not the wire encoding.
                let fromDatabase = (row?.string("genuine") ?? "").lowercased()
                let databaseSaysYes = ["t", "true", "1"].contains(fromDatabase)
                expect.equal(databaseSaysYes, kind.describesGenuineUnavailability,
                             "\(kind.rawValue): database=\(fromDatabase) "
                             + "swift=\(kind.describesGenuineUnavailability)")
            }
        },

        TestCase(group: "PostgreSQL integration",
                 name: "the export gate still excludes cancellation blocks") { expect in
            if skipped(expect) { return }
            guard let store = try backend() else { return }
            try workflow(store)
            // Read through the database's own allow-list, not the Swift one,
            // so both layers are checked to agree.
            let blocking = try store.database.query("""
                SELECT source, basis FROM blocking_intervals ORDER BY basis, source
                """)
            let classified = try store.classifiedEvents()
            let genuine = classified.filter {
                $0.classification.kind.describesGenuineUnavailability
            }
            expect.equal(blocking.count, genuine.count,
                         "the database view and the Swift rule agree on what blocks")
            expect.ok(genuine.allSatisfy { $0.classification.kind != .cancellationBlock },
                      "and a cancellation block is not among them")
        },

        // --- B6: concurrency over the Data API ---

        TestCase(group: "PostgreSQL integration",
                 name: "two sessions racing the same nights leave exactly one winner") { expect in
            if skipped(expect) { return }
            guard let store = try backend() else { return }
            let property = try store.properties.insert(
                Property(name: "Race — 39 G Street", address: "South Boston, MA"))
            guard let first = try sibling(), let second = try sibling() else { return }

            let outcome = race([first, second], property: property.id!,
                               checkIn: DayMath.day(2027, 6, 1),
                               checkOut: DayMath.day(2027, 6, 5))

            // The whole point: the database decides, and it decides once. A
            // second accepted hold on the same nights is a double booking.
            expect.equal(outcome.accepted, 1,
                         "exactly one session may hold the same nights")
            expect.equal(outcome.refusals.count, 1,
                         "and the loser must be refused, not silently dropped")
            // Which refusal matters. A dropped connection or a missing column
            // would also leave one winner, and this test would then be
            // passing while proving nothing about the constraint.
            expect.ok(outcome.refusals.first?.contains("no_overlapping_live_holds") == true,
                      "the refusal must come from the overlap constraint, got: "
                      + (outcome.refusals.first ?? "none"))
            expect.equal(try liveHolds(store, property: property.id!), 1,
                         "exactly one live hold row survives the race")
        },

        // The control for the test above. Without it, a constraint that
        // refused *every* hold would also report "exactly one winner" — the
        // race test would pass for the wrong reason and nobody would know.
        TestCase(group: "PostgreSQL integration",
                 name: "two sessions on non-overlapping nights both win") { expect in
            if skipped(expect) { return }
            guard let store = try backend() else { return }
            let property = try store.properties.insert(
                Property(name: "No race — 39 G Street", address: "South Boston, MA"))
            guard let first = try sibling(), let second = try sibling() else { return }

            let early = race([first], property: property.id!,
                             checkIn: DayMath.day(2027, 6, 1),
                             checkOut: DayMath.day(2027, 6, 5))
            // Starts on the first night the other gives up, which is the
            // checkout-day adjacency the half-open range is there to allow.
            let late = race([second], property: property.id!,
                            checkIn: DayMath.day(2027, 6, 5),
                            checkOut: DayMath.day(2027, 6, 9))

            expect.equal(early.accepted, 1, "the earlier stay is accepted")
            expect.equal(late.accepted, 1,
                         "and so is an adjacent one — the constraint rejects overlap, not all holds")
            expect.equal(try liveHolds(store, property: property.id!), 2,
                         "both live holds coexist")
        },
    ] }
}
