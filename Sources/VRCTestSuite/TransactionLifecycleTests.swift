import Foundation
import VRCCore

/// Failure injection at every point in the transaction lifecycle.
///
/// The defects these cover were all silent: a leaked depth made later
/// transactions run with no transaction at all, and a prematurely-set actor
/// flag made statements run with the database's least-privileged default. Both
/// would have produced wrong data rather than an error, which is why each
/// transition is now exercised with a failure and then checked for a clean
/// state by running a second transaction successfully afterwards.
public enum TransactionLifecycleTests {

    static func make(
        _ responses: [RecordingDataAPITransport.Scripted],
        actor: String = "owner",
        maxAttempts: Int = 1
    ) -> (DataAPIStore, RecordingDataAPITransport) {
        let transport = RecordingDataAPITransport(responses: responses)
        return (DataAPIStore(
            transport: transport,
            configuration: .init(resourceArn: "arn:cluster", secretArn: "arn:secret",
                                 database: "vrc", actor: actor,
                                 maxAttempts: maxAttempts, resumeBudget: 1),
            sleeper: { _ in }), transport)
    }

    static func ok(_ payload: [String: Any] = ["numberOfRecordsUpdated": 1])
        -> RecordingDataAPITransport.Scripted { .init(statusCode: 200, payload: payload) }
    static func begun(_ id: String = "txn-1") -> RecordingDataAPITransport.Scripted {
        .init(statusCode: 200, payload: ["transactionId": id])
    }
    static func fail(_ status: Int, _ type: String, _ message: String)
        -> RecordingDataAPITransport.Scripted {
        .init(statusCode: status, payload: ["__type": type, "message": message])
    }
    static func serialization() -> RecordingDataAPITransport.Scripted {
        fail(400, "BadRequestException",
             "could not serialize access due to concurrent update (SQLSTATE 40001)")
    }

    /// After any failure, the store must be usable again. A leaked depth shows
    /// up here as a transaction that never issues BeginTransaction.
    static func assertRecovers(
        _ store: DataAPIStore, _ transport: RecordingDataAPITransport, _ expect: Expect
    ) throws {
        let before = transport.calls.count
        transport.enqueue(begun("txn-recover"))
        transport.enqueue(ok())   // actor
        transport.enqueue(ok())   // statement
        transport.enqueue(ok())   // commit
        try store.transaction {
            _ = try store.run("UPDATE t SET x = ?", [.integer(1)])
        }
        let after = Array(transport.calls.dropFirst(before))
        expect.ok(after.contains { $0.action == .beginTransaction },
                  "a later transaction must still issue BeginTransaction — if it does not, "
                  + "the depth leaked and this ran with no transaction")
        expect.ok(after.contains { $0.action == .commitTransaction }, "and must commit")
    }

    public static var cases: [TestCase] { [

        TestCase(group: "Transaction lifecycle",
                 name: "a failed BeginTransaction leaves no state behind") { expect in
            let (store, transport) = make([fail(500, "InternalServerError", "no")])
            var bodyRan = false
            do {
                try store.transaction { bodyRan = true }
                expect.fail("the transaction must not proceed")
            } catch { /* expected */ }
            expect.ok(!bodyRan, "the body must not run without a transaction")
            try assertRecovers(store, transport, expect)
        },

        TestCase(group: "Transaction lifecycle",
                 name: "a BeginTransaction with no transaction id resets state") { expect in
            // A 200 with an empty body. Previously this threw while the depth
            // was already incremented.
            let (store, transport) = make([.init(statusCode: 200, payload: [:])])
            do {
                try store.transaction { }
                expect.fail("there is no transaction to run in")
            } catch let error as DataAPIError {
                if case .malformedResponse = error {} else { expect.fail("wrong error: \(error)") }
            }
            try assertRecovers(store, transport, expect)
        },

        TestCase(group: "Transaction lifecycle",
                 name: "a failed actor declaration does not mark the actor declared") { expect in
            // The silent one. If the flag were set anyway, later statements in
            // the transaction would run as the database default 'importer' and
            // the guards would refuse an owner's own changes.
            let (store, transport) = make([
                begun(), fail(500, "InternalServerError", "set_config failed"),
            ])
            do {
                try store.transaction { _ = try store.run("UPDATE t SET x = ?", [.integer(1)]) }
                expect.fail("a failed actor declaration must abort the transaction")
            } catch { /* expected */ }

            // Second attempt must declare the actor again.
            transport.enqueue(begun("txn-2"))
            transport.enqueue(ok())   // actor, this time succeeding
            transport.enqueue(ok())   // statement
            transport.enqueue(ok())   // commit
            try store.transaction { _ = try store.run("UPDATE t SET x = ?", [.integer(1)]) }
            let declarations = transport.executedSQL.filter { $0.contains("set_config('vrc.actor'") }
            expect.equal(declarations.count, 2,
                         "the actor must be declared again after the first attempt failed")
        },

        TestCase(group: "Transaction lifecycle",
                 name: "a throwing body rolls back and leaves clean state") { expect in
            struct Nope: Error {}
            // Only two calls are issued: begin, then rollback. The body throws
            // before any statement, so no actor declaration happens.
            let (store, transport) = make([begun(), ok()])
            do {
                try store.transaction { throw Nope() }
                expect.fail("the original error must surface")
            } catch is Nope { /* correct */ }
            expect.ok(transport.calls.contains { $0.action == .rollbackTransaction })
            try assertRecovers(store, transport, expect)
        },

        TestCase(group: "Transaction lifecycle",
                 name: "a failed rollback is indeterminate and still resets state") { expect in
            struct Nope: Error {}
            // begin succeeds, then the rollback itself fails.
            let (store, transport) = make([
                begun(), fail(500, "InternalServerError", "rollback failed"),
            ])
            do {
                try store.transaction { throw Nope() }
                expect.fail("must throw")
            } catch let error as DataAPIError {
                if case .indeterminate(let detail) = error {
                    expect.ok(detail.contains("rollback"), "says the rollback failed")
                    expect.ok(detail.contains("expires") || detail.contains("unknown"),
                              "and that the transaction may still be open server-side")
                } else { expect.fail("wrong error: \(error)") }
            }
            // The invalid transaction must not be reusable.
            try assertRecovers(store, transport, expect)
        },

        TestCase(group: "Transaction lifecycle",
                 name: "an unconfirmed commit stays indeterminate") { expect in
            let (store, transport) = make([
                begun(), ok(), ok(), fail(500, "InternalServerError", "???"),
            ])
            do {
                try store.transaction { _ = try store.run("INSERT INTO t VALUES (?)", [.integer(1)]) }
                expect.fail("an unconfirmed commit must not be success")
            } catch let error as DataAPIError {
                if case .indeterminate = error {} else { expect.fail("wrong error: \(error)") }
            }
            try assertRecovers(store, transport, expect)
        },

        // --- Serialisation failures restart the whole transaction ---

        TestCase(group: "Transaction lifecycle",
                 name: "a 40001 inside a transaction restarts the WHOLE transaction") { expect in
            // The important one. Retrying only the failing statement would run
            // it inside a transaction PostgreSQL has already aborted.
            let (store, transport) = make([
                begun("txn-a"), ok(),       // begin, actor
                serialization(),            // the statement trips 40001
                ok(),                       // rollback
                begun("txn-b"), ok(),       // begin again, actor again
                ok(),                       // statement succeeds
                ok(),                       // commit
            ], maxAttempts: 1)              // statement-level retries off, so only
                                            // the transaction-level retry can save this

            var bodyRuns = 0
            try store.transaction(attempts: 3) {
                bodyRuns += 1
                _ = try store.run("UPDATE reservations SET status = ?", [.text("confirmed")])
            }
            expect.equal(bodyRuns, 2, "the body ran again from the start")
            let begins = transport.calls.filter { $0.action == .beginTransaction }.count
            let commits = transport.calls.filter { $0.action == .commitTransaction }.count
            let rollbacks = transport.calls.filter { $0.action == .rollbackTransaction }.count
            expect.equal(begins, 2, "a second transaction was begun")
            expect.equal(rollbacks, 1, "the aborted one was rolled back")
            expect.equal(commits, 1, "and exactly one commit happened")
        },

        TestCase(group: "Transaction lifecycle",
                 name: "the actor is re-declared in the restarted transaction") { expect in
            let (store, transport) = make([
                begun("txn-a"), ok(), serialization(), ok(),
                begun("txn-b"), ok(), ok(), ok(),
            ], maxAttempts: 1)
            try store.transaction(attempts: 3) {
                _ = try store.run("UPDATE t SET x = ?", [.integer(1)])
            }
            let declarations = transport.executedSQL.filter { $0.contains("set_config('vrc.actor'") }
            expect.equal(declarations.count, 2,
                         "a restarted transaction is a new transaction and needs the actor again")
        },

        TestCase(group: "Transaction lifecycle",
                 name: "repeated serialisation failures eventually give up") { expect in
            var script: [RecordingDataAPITransport.Scripted] = []
            for _ in 0..<4 { script += [begun(), ok(), serialization(), ok()] }
            let (store, _) = make(script, maxAttempts: 1)
            do {
                try store.transaction(attempts: 3) {
                    _ = try store.run("UPDATE t SET x = ?", [.integer(1)])
                }
                expect.fail("it must not retry for ever")
            } catch let error as DataAPIError {
                if case .serializationFailure = error {} else { expect.fail("wrong error: \(error)") }
            }
        },

        TestCase(group: "Transaction lifecycle",
                 name: "a 40001 OUTSIDE a transaction is retried as one statement") { expect in
            // A lone statement is its own transaction, so retrying it here is
            // correct and cheaper than involving the caller.
            let (store, transport) = make([serialization(), ok()], maxAttempts: 3)
            _ = try store.run("UPDATE t SET x = ?", [.integer(1)])
            expect.equal(transport.calls.count, 2)
            expect.ok(!transport.calls.contains { $0.action == .beginTransaction },
                      "no explicit transaction is involved")
        },

        // --- Nesting ---

        TestCase(group: "Transaction lifecycle",
                 name: "a nested transaction joins, and a nested failure aborts both") { expect in
            struct Nope: Error {}
            let (store, transport) = make([begun(), ok(), ok(), ok()])
            do {
                try store.transaction {
                    _ = try store.run("UPDATE a SET x = ?", [.integer(1)])
                    try store.transaction { throw Nope() }
                }
                expect.fail("the inner failure must abort the outer transaction")
            } catch is Nope { /* correct */ }
            expect.equal(transport.calls.filter { $0.action == .beginTransaction }.count, 1)
            expect.equal(transport.calls.filter { $0.action == .commitTransaction }.count, 0,
                         "nothing may be committed")
            expect.ok(transport.calls.contains { $0.action == .rollbackTransaction })
            try assertRecovers(store, transport, expect)
        },

        TestCase(group: "Transaction lifecycle",
                 name: "nesting three deep still commits exactly once") { expect in
            let (store, transport) = make([begun(), ok(), ok(), ok(), ok(), ok()])
            try store.transaction {
                _ = try store.run("UPDATE a SET x = ?", [.integer(1)])
                try store.transaction {
                    try store.transaction {
                        _ = try store.run("UPDATE b SET y = ?", [.integer(2)])
                    }
                }
            }
            expect.equal(transport.calls.filter { $0.action == .beginTransaction }.count, 1)
            expect.equal(transport.calls.filter { $0.action == .commitTransaction }.count, 1)
        },

        // --- Concurrency ---

        TestCase(group: "Transaction lifecycle",
                 name: "a second thread using the same store mid-transaction is refused") { expect in
            // Sharing one store across threads would interleave statements
            // from two transactions into whichever id happened to be set.
            // Refused loudly instead.
            let (store, _) = make([begun(), ok(), ok(), ok()])
            var secondThreadError: Error?
            let gate = DispatchSemaphore(value: 0)
            let done = DispatchSemaphore(value: 0)

            try store.transaction {
                DispatchQueue.global().async {
                    do {
                        try store.transaction { }
                    } catch { secondThreadError = error }
                    done.signal()
                }
                done.wait()
                gate.signal()
                _ = try store.run("UPDATE t SET x = ?", [.integer(1)])
            }
            gate.wait()

            guard let error = secondThreadError as? DataAPIError else {
                expect.fail("the second thread should have been refused")
                return
            }
            if case .concurrentUse = error {} else { expect.fail("wrong error: \(error)") }
        },

        TestCase(group: "Transaction lifecycle",
                 name: "sequential transactions on one store are fine") { expect in
            let (store, transport) = make([
                begun("t1"), ok(), ok(), ok(),
                begun("t2"), ok(), ok(), ok(),
            ])
            try store.transaction { _ = try store.run("UPDATE a SET x = ?", [.integer(1)]) }
            try store.transaction { _ = try store.run("UPDATE b SET y = ?", [.integer(2)]) }
            expect.equal(transport.calls.filter { $0.action == .beginTransaction }.count, 2)
            expect.equal(transport.calls.filter { $0.action == .commitTransaction }.count, 2)
        },

        TestCase(group: "Transaction lifecycle",
                 name: "statements carry the current transaction id, and none after it ends") { expect in
            let (store, transport) = make([begun("txn-xyz"), ok(), ok(), ok(), ok()])
            try store.transaction { _ = try store.run("UPDATE t SET x = ?", [.integer(1)]) }
            let inside = transport.calls.filter {
                $0.action == .execute && ($0.body["sql"] as? String)?.contains("UPDATE t") == true
            }
            expect.equal(inside.first?.body["transactionId"] as? String, "txn-xyz")

            _ = try store.run("UPDATE t SET x = ?", [.integer(2)])
            let after = transport.calls.last
            expect.ok(after?.body["transactionId"] == nil,
                      "a statement after the transaction must not quote a dead transaction id")
        },
    ] }
}
