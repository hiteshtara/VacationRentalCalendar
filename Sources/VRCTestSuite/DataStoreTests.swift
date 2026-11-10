import Foundation
import VRCCore

/// The Data API store is the only thing standing between the tested business
/// rules and a managed database that can be asleep, throttling, or halfway
/// through a transaction. These cover the three behaviours that would cost
/// money if wrong: parameters must never be interpolated, a write must never
/// be retried when it might already have applied, and an unknown outcome must
/// never be reported as success.
public enum DataStoreTests {

    static func store(
        _ responses: [RecordingDataAPITransport.Scripted] = [],
        actor: String = "importer",
        maxAttempts: Int = 5
    ) -> (store: DataAPIStore, transport: RecordingDataAPITransport) {
        let transport = RecordingDataAPITransport(responses: responses)
        let store = DataAPIStore(
            transport: transport,
            configuration: .init(
                resourceArn: "arn:aws:rds:us-east-1:1:cluster:vrc-main",
                secretArn: "arn:aws:secretsmanager:us-east-1:1:secret:vrc/database/runtime",
                database: "vrc", actor: actor, maxAttempts: maxAttempts, resumeBudget: 10),
            sleeper: { _ in }   // no real waiting in tests
        )
        return (store, transport)
    }

    static func ok(_ payload: [String: Any] = ["numberOfRecordsUpdated": 1])
        -> RecordingDataAPITransport.Scripted {
        .init(statusCode: 200, payload: payload)
    }

    static func error(_ status: Int, _ type: String, _ message: String)
        -> RecordingDataAPITransport.Scripted {
        .init(statusCode: status, payload: ["__type": type, "message": message])
    }

    public static var cases: [TestCase] { [

        // --- Placeholder rewriting ---

        TestCase(group: "DataStore", name: "positional placeholders become named parameters") { expect in
            let rewritten = SQLScanner.rewritePlaceholders(
                "SELECT * FROM events WHERE listing_id = ? AND check_in >= ?")
            expect.equal(rewritten.placeholderCount, 2)
            expect.equal(rewritten.sql,
                "SELECT * FROM events WHERE listing_id = :p0 AND check_in >= :p1")
        },

        TestCase(group: "DataStore",
                 name: "a question mark inside a string literal is left alone") { expect in
            // This is the case that would corrupt real SQL. Reason text and
            // summaries in this project contain question marks.
            let rewritten = SQLScanner.rewritePlaceholders(
                "UPDATE d SET reason = 'why not? ask the owner' WHERE id = ?")
            expect.equal(rewritten.placeholderCount, 1)
            expect.ok(rewritten.sql.contains("'why not? ask the owner'"),
                      "the literal must survive untouched")
            expect.ok(rewritten.sql.hasSuffix("id = :p0"))
        },

        TestCase(group: "DataStore",
                 name: "an escaped quote does not end the literal early") { expect in
            let rewritten = SQLScanner.rewritePlaceholders(
                "SELECT ? WHERE note = 'it''s a ? here' AND x = ?")
            expect.equal(rewritten.placeholderCount, 2)
            expect.ok(rewritten.sql.contains("'it''s a ? here'"))
        },

        TestCase(group: "DataStore",
                 name: "question marks in comments and quoted identifiers are left alone") { expect in
            let a = SQLScanner.rewritePlaceholders("SELECT ? -- really? yes\nFROM t WHERE y = ?")
            expect.equal(a.placeholderCount, 2)
            let b = SQLScanner.rewritePlaceholders("SELECT \"odd?column\" FROM t WHERE z = ?")
            expect.equal(b.placeholderCount, 1)
            let c = SQLScanner.rewritePlaceholders("/* why? */ SELECT ? FROM t")
            expect.equal(c.placeholderCount, 1)
        },

        TestCase(group: "DataStore", name: "values travel as typed parameters, never inlined") { expect in
            let (store, transport) = store([ok()])
            // A value that would be catastrophic if interpolated.
            _ = try store.run("INSERT INTO classifications (note) VALUES (?)",
                              [.text("'); DROP TABLE reservations; --")])
            let sql = transport.executedSQL.last ?? ""
            expect.ok(!sql.contains("DROP TABLE"),
                      "the value must not appear in the SQL text")
            expect.ok(sql.contains(":p0"), "the SQL carries a placeholder")
            let parameters = transport.calls.last?.body["parameters"] as? [[String: Any]]
            expect.equal(parameters?.count, 1)
            let value = parameters?.first?["value"] as? [String: Any]
            expect.ok(value?["stringValue"] as? String == "'); DROP TABLE reservations; --",
                      "the value travels as a parameter")
        },

        TestCase(group: "DataStore", name: "a placeholder/parameter mismatch is refused") { expect in
            // Guessing which side is right would mean binding the wrong column.
            let (store, _) = store([ok()])
            do {
                _ = try store.run("SELECT ? , ?", [.integer(1)])
                expect.fail("a mismatch must throw")
            } catch let error as DataAPIError {
                if case .unsupported = error {} else { expect.fail("wrong error: \(error)") }
            }
        },

        TestCase(group: "DataStore", name: "a multi-statement execute is refused") { expect in
            let (store, _) = store([ok()])
            do {
                try store.execute("CREATE TABLE a (x int); CREATE TABLE b (y int)")
                expect.fail("two statements in one call must throw")
            } catch let error as DataAPIError {
                if case .unsupported = error {} else { expect.fail("wrong error: \(error)") }
            }
        },

        // --- Type round-tripping ---

        TestCase(group: "DataStore", name: "every SQLValue encodes to its Data API field") { expect in
            expect.ok(DataAPIStore.encode(.null)["isNull"] as? Bool == true)
            expect.ok(DataAPIStore.encode(.integer(7))["longValue"] as? Int64 == 7)
            expect.ok(DataAPIStore.encode(.real(1.5))["doubleValue"] as? Double == 1.5)
            expect.ok(DataAPIStore.encode(.text("x"))["stringValue"] as? String == "x")
            expect.ok(DataAPIStore.encode(.blob(Data([1, 2])))["blobValue"] as? String == "AQI=")
        },

        TestCase(group: "DataStore", name: "rows decode by column name") { expect in
            let (store, transport) = store()
            transport.enqueue(.init(statusCode: 200, payload: [
                "columnMetadata": [["name": "id"], ["name": "summary"], ["name": "ratio"],
                                   ["name": "missing"]],
                "records": [[["longValue": NSNumber(value: 42)],
                             ["stringValue": "Reserved"],
                             ["doubleValue": NSNumber(value: 0.25)],
                             ["isNull": true]]],
            ]))
            let rows = try store.query("SELECT id, summary, ratio, missing FROM t")
            expect.equal(rows.count, 1)
            expect.equal(rows[0].int("id"), 42)
            expect.equal(rows[0].string("summary"), "Reserved")
            expect.equal(rows[0].double("ratio"), 0.25)
            expect.ok(rows[0].string("missing") == nil, "a null column reads as nil")
        },

        TestCase(group: "DataStore", name: "a generated id is captured from RETURNING") { expect in
            let (store, transport) = store()
            transport.enqueue(.init(statusCode: 200, payload: [
                "numberOfRecordsUpdated": 1,
                "generatedFields": [["longValue": NSNumber(value: 1234)]],
            ]))
            _ = try store.run("INSERT INTO properties (slug) VALUES (?) RETURNING id",
                              [.text("39-g")])
            expect.equal(store.lastInsertRowID, 1234)
        },

        // --- Aurora is allowed to be asleep ---

        TestCase(group: "DataStore", name: "a resuming cluster is waited for, then succeeds") { expect in
            // Expected behaviour with minimum capacity 0, not an error.
            let (store, transport) = store([
                error(400, "BadRequestException", "Database is resuming after being auto-paused"),
                error(400, "BadRequestException", "Database is resuming after being auto-paused"),
                ok(["columnMetadata": [["name": "n"]], "records": [[["longValue": NSNumber(value: 3)]]]]),
            ])
            let value = try store.scalarInt("SELECT count(*) AS n FROM events")
            expect.equal(value, 3)
            expect.equal(transport.calls.count, 3, "it retried twice before succeeding")
        },

        TestCase(group: "DataStore", name: "a cluster that never resumes gives up") { expect in
            let (store, _) = store(Array(repeating:
                error(400, "BadRequestException", "Database is resuming after being auto-paused"),
                count: 8))
            do {
                _ = try store.query("SELECT 1")
                expect.fail("it must not wait forever")
            } catch let error as DataAPIError {
                if case .retriesExhausted = error {} else { expect.fail("wrong error: \(error)") }
            }
        },

        // --- Fail closed ---

        TestCase(group: "DataStore",
                 name: "a write that may have applied is NOT retried") { expect in
            // The dangerous case. A 500 on an INSERT might mean the row landed.
            // Retrying could double-insert; reporting success could lose it.
            // Neither is acceptable, so it fails closed.
            let (store, transport) = store([error(500, "InternalServerError", "boom"), ok()])
            do {
                _ = try store.run("INSERT INTO holds (stay) VALUES (?)", [.text("x")])
                expect.fail("an uncertain write must throw")
            } catch let error as DataAPIError {
                if case .indeterminate = error {} else { expect.fail("wrong error: \(error)") }
            }
            expect.equal(transport.calls.count, 1, "it must not have tried again")
        },

        TestCase(group: "DataStore", name: "a read may be retried after a transient failure") { expect in
            let (store, transport) = store([
                error(503, "ServiceUnavailable", "try later"),
                ok(["columnMetadata": [["name": "n"]], "records": [[["longValue": NSNumber(value: 1)]]]]),
            ])
            expect.equal(try store.scalarInt("SELECT 1 AS n"), 1)
            expect.equal(transport.calls.count, 2)
        },

        TestCase(group: "DataStore",
                 name: "a serialization failure is retried, because nothing applied") { expect in
            let (store, transport) = store([
                error(400, "BadRequestException",
                      "could not serialize access due to read/write dependencies (SQLSTATE 40001)"),
                ok(),
            ])
            _ = try store.run("UPDATE reservations SET status = ?", [.text("confirmed")])
            expect.equal(transport.calls.count, 2, "40001 rolled back, so a retry is safe")
        },

        TestCase(group: "DataStore", name: "an exclusion violation is never retried") { expect in
            // A real double booking. Retrying would just fail again, and the
            // caller needs to record a conflict instead.
            let (store, transport) = store([
                error(400, "BadRequestException",
                      "conflicting key value violates exclusion constraint \"no_double_booking\""),
            ])
            do {
                _ = try store.run("INSERT INTO reservations (stay) VALUES (?)", [.text("x")])
                expect.fail("must throw")
            } catch let error as DataAPIError {
                if case .indeterminate = error {
                    // Acceptable: a write whose outcome is unclear.
                } else if case .http = error {
                    // Also acceptable: reported as a permanent rejection.
                } else { expect.fail("wrong error: \(error)") }
            }
            expect.equal(transport.calls.count, 1, "no retry")
        },

        TestCase(group: "DataStore",
                 name: "a vanished transaction is reported, not silently re-run") { expect in
            // Re-running the statement would execute it OUTSIDE the
            // transaction, which is how partial writes happen.
            let (store, transport) = store([
                error(400, "BadRequestException", "Transaction abc123 is not found"),
            ])
            do {
                _ = try store.query("SELECT 1")
                expect.fail("must throw")
            } catch let error as DataAPIError {
                if case .indeterminate = error {} else { expect.fail("wrong error: \(error)") }
            }
            expect.equal(transport.calls.count, 1)
        },

        TestCase(group: "DataStore", name: "a transport failure during a write fails closed") { expect in
            let (store, _) = store()
            struct Dropped: Error {}
            let transport = RecordingDataAPITransport()
            transport.throwOnNext(Dropped())
            let isolated = DataAPIStore(
                transport: transport,
                configuration: .init(resourceArn: "a", secretArn: "b", database: "vrc"),
                sleeper: { _ in })
            do {
                _ = try isolated.run("INSERT INTO t VALUES (?)", [.integer(1)])
                expect.fail("must throw")
            } catch let error as DataAPIError {
                if case .indeterminate = error {} else { expect.fail("wrong error: \(error)") }
            }
            _ = store
        },

        // --- Transactions ---

        TestCase(group: "DataStore", name: "a transaction begins, declares the actor, and commits") { expect in
            let (store, transport) = store([
                ok(["transactionId": "txn-1"]),   // BeginTransaction
                ok(),                             // set_config('vrc.actor', …)
                ok(),                             // the caller's statement
                ok(),                             // CommitTransaction
            ], actor: "owner")
            try store.transaction {
                _ = try store.run("UPDATE reservations SET status = ?", [.text("cancelled")])
            }
            let actions = transport.calls.map(\.action.rawValue)
            expect.equal(actions, ["BeginTransaction", "Execute", "Execute", "CommitTransaction"])
            expect.ok(transport.executedSQL.contains { $0.contains("set_config('vrc.actor'") },
                      "the actor is declared, so the database guards can see it")
            let declaration = transport.calls[1].body["parameters"] as? [[String: Any]]
            let value = declaration?.first?["value"] as? [String: Any]
            expect.equal(value?["stringValue"] as? String, "owner")
        },

        TestCase(group: "DataStore", name: "a throwing body rolls back and rethrows the original") { expect in
            struct Nope: Error {}
            let (store, transport) = store([
                ok(["transactionId": "txn-2"]), ok(), ok(),
            ])
            do {
                try store.transaction { throw Nope() }
                expect.fail("the original error must surface")
            } catch is Nope {
                // correct
            } catch {
                expect.fail("wrong error: \(error)")
            }
            expect.ok(transport.calls.map(\.action).contains(.rollbackTransaction),
                      "it rolled back")
        },

        TestCase(group: "DataStore", name: "an unconfirmed commit is indeterminate, not success") { expect in
            let (store, _) = store([
                ok(["transactionId": "txn-3"]),           // begin
                ok(),                                     // actor
                ok(),                                     // statement
                error(500, "InternalServerError", "???"),  // commit
            ])
            do {
                try store.transaction {
                    _ = try store.run("INSERT INTO t VALUES (?)", [.integer(1)])
                }
                expect.fail("an unconfirmed commit must not be reported as success")
            } catch let error as DataAPIError {
                if case .indeterminate = error {} else { expect.fail("wrong error: \(error)") }
            }
        },

        TestCase(group: "DataStore", name: "a nested transaction joins the outer one") { expect in
            // Committing early would end the outer transaction and leave the
            // rest of its work running unprotected.
            let (store, transport) = store([
                ok(["transactionId": "txn-4"]), ok(), ok(), ok(), ok(),
            ])
            try store.transaction {
                _ = try store.run("UPDATE a SET x = ?", [.integer(1)])
                try store.transaction {
                    _ = try store.run("UPDATE b SET y = ?", [.integer(2)])
                }
            }
            let begins = transport.calls.filter { $0.action == .beginTransaction }.count
            let commits = transport.calls.filter { $0.action == .commitTransaction }.count
            expect.equal(begins, 1, "only one transaction is started")
            expect.equal(commits, 1, "and only one commit")
        },

        TestCase(group: "DataStore", name: "configuration comes from the Lambda environment") { expect in
            let config = try DataAPIStore.Configuration.fromEnvironment([
                "VRC_CLUSTER_ARN": "arn:cluster", "VRC_DB_SECRET_ARN": "arn:secret",
                "VRC_DB_NAME": "vrc", "VRC_ACTOR": "owner",
            ])
            expect.equal(config.database, "vrc")
            expect.equal(config.actor, "owner")
            do {
                _ = try DataAPIStore.Configuration.fromEnvironment(["VRC_DB_NAME": "vrc"])
                expect.fail("a missing ARN must throw rather than default")
            } catch let error as DataAPIError {
                if case .notConfigured = error {} else { expect.fail("wrong error: \(error)") }
            }
        },

        TestCase(group: "DataStore", name: "the actor defaults to the least privileged") { expect in
            let config = try DataAPIStore.Configuration.fromEnvironment([
                "VRC_CLUSTER_ARN": "a", "VRC_DB_SECRET_ARN": "b", "VRC_DB_NAME": "vrc",
            ])
            expect.equal(config.actor, "importer",
                         "an undeclared actor must be the least trusted one")
        },
    ] }
}
