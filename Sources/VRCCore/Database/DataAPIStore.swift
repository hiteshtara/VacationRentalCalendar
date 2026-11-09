import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Transport

/// One Data API call. Separated from the store so the SQL translation, the
/// parameter binding, the retry policy and the fail-closed behaviour are all
/// testable without an AWS account.
public struct DataAPICall: Sendable {
    public enum Action: String, Sendable {
        case execute = "Execute"
        case beginTransaction = "BeginTransaction"
        case commitTransaction = "CommitTransaction"
        case rollbackTransaction = "RollbackTransaction"
    }
    public var action: Action
    public var body: [String: Any]

    public init(action: Action, body: [String: Any]) {
        self.action = action
        self.body = body
    }
}

public struct DataAPIResult: Sendable {
    public var statusCode: Int
    public var payload: [String: Any]

    public init(statusCode: Int, payload: [String: Any]) {
        self.statusCode = statusCode
        self.payload = payload
    }
}

public protocol DataAPITransport: Sendable {
    /// Synchronous on purpose — see the note on `DataStore`.
    func send(_ call: DataAPICall) throws -> DataAPIResult
}

public enum DataAPIError: Error, LocalizedError {
    case notConfigured(String)
    case http(Int, type: String, message: String)
    case malformedResponse(String)
    /// A statement whose outcome could not be established. Never treated as
    /// success and never retried blindly inside a transaction.
    case indeterminate(String)
    case retriesExhausted(attempts: Int, lastError: String)
    case unsupported(String)
    /// SQLSTATE 40001 or 40P01. The database has already rolled the whole
    /// transaction back, so the only correct response is to run the entire
    /// transaction again -- never to retry the one statement, which would
    /// execute inside a transaction the server has already aborted.
    case serializationFailure(String)
    /// Two threads tried to use one store while a transaction was open. The
    /// transaction id is per-instance state, so this would interleave
    /// statements from different transactions.
    case concurrentUse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let what):
            return "The database connection is not configured: \(what)."
        case .http(let status, let type, let message):
            return "The database rejected the statement (HTTP \(status), \(type)): \(message)"
        case .malformedResponse(let detail):
            return "The database returned something unreadable: \(detail)"
        case .indeterminate(let detail):
            return "The outcome of this database operation is unknown, so it is "
                + "being treated as a failure: \(detail)"
        case .retriesExhausted(let attempts, let last):
            return "Gave up after \(attempts) attempts. Last error: \(last)"
        case .unsupported(let what):
            return "Not supported against Aurora over the Data API: \(what)"
        case .serializationFailure(let detail):
            return "The database rolled this transaction back to preserve "
                + "serialisability: \(detail)"
        case .concurrentUse(let detail):
            return "This database connection is already inside a transaction on "
                + "another thread: \(detail)"
        }
    }
}

// MARK: - The store

/// `DataStore` over the RDS Data API.
///
/// SQL over HTTPS, which is the whole reason the Lambdas stay out of a VPC and
/// no NAT gateway is needed. Three behaviours matter more than the plumbing:
///
/// **Parameterised, always.** Repository SQL uses `?`. Those are rewritten to
/// the Data API's named parameters and the values travel as typed parameters,
/// never interpolated. String literals and comments in the SQL are skipped by
/// the rewriter so a `?` inside one is left alone.
///
/// **Aurora may be asleep.** With minimum capacity 0 the cluster pauses, and
/// the first statement after a pause can take up to about fifteen seconds and
/// may be rejected outright while the cluster resumes. That is a normal
/// condition here, not an error, so it is retried with backoff.
///
/// **Fail closed.** A statement whose outcome cannot be established throws.
/// It is never reported as success, and a write is never retried when the
/// first attempt might already have applied — the caller gets
/// `.indeterminate` and decides.
public final class DataAPIStore: DataStore, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var resourceArn: String
        public var secretArn: String
        public var database: String
        /// Declared to the database as `vrc.actor`, so migrations 002 and 003
        /// can tell an importer from an owner. Defaults to the least
        /// privileged value.
        public var actor: String
        public var maxAttempts: Int
        public var resumeBudget: TimeInterval

        public init(
            resourceArn: String,
            secretArn: String,
            database: String,
            actor: String = "importer",
            maxAttempts: Int = 5,
            resumeBudget: TimeInterval = 40
        ) {
            self.resourceArn = resourceArn
            self.secretArn = secretArn
            self.database = database
            self.actor = actor
            self.maxAttempts = maxAttempts
            self.resumeBudget = resumeBudget
        }

        /// Reads what the Lambdas are given by Terraform.
        public static func fromEnvironment(
            _ environment: [String: String] = ProcessInfo.processInfo.environment
        ) throws -> Configuration {
            func need(_ key: String) throws -> String {
                guard let value = environment[key], !value.isEmpty else {
                    throw DataAPIError.notConfigured(key)
                }
                return value
            }
            return Configuration(
                resourceArn: try need("VRC_CLUSTER_ARN"),
                secretArn: try need("VRC_DB_SECRET_ARN"),
                database: try need("VRC_DB_NAME"),
                actor: environment["VRC_ACTOR"] ?? "importer"
            )
        }
    }

    private let transport: DataAPITransport
    private let configuration: Configuration
    private let sleeper: (TimeInterval) -> Void

    private let lock = NSLock()
    private var transactionID: String?
    private var transactionDepth = 0
    private var lastGeneratedID: Int64 = 0
    /// Which thread owns the open transaction. The transaction id is
    /// per-instance, so a second thread issuing statements would interleave
    /// them into someone else's transaction. Detected and refused rather than
    /// silently corrupting both.
    private var transactionOwner: ObjectIdentifier?
    /// Set once per transaction, so `vrc.actor` is declared before any
    /// statement the guards would inspect.
    private var actorDeclared = false

    public init(
        transport: DataAPITransport,
        configuration: Configuration,
        sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.transport = transport
        self.configuration = configuration
        self.sleeper = sleeper
    }

    public var dialect: SQLDialect { .postgres }

    public var lastInsertRowID: Int64 {
        lock.lock(); defer { lock.unlock() }
        return lastGeneratedID
    }

    // MARK: Statements

    public func execute(_ sql: String) throws {
        // Multiple statements in one string are not accepted by the Data API,
        // and silently running only the first would be worse than refusing.
        let statements = SQLScanner.splitStatements(sql)
        guard statements.count <= 1 else {
            throw DataAPIError.unsupported(
                "a batch of \(statements.count) statements in one call — send them individually "
                + "so each outcome is known")
        }
        _ = try perform(sql, [], expecting: .write)
    }

    @discardableResult
    public func run(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int {
        let result = try perform(
            Self.withGeneratedIDReturned(sql), parameters, expecting: .write)
        if let generated = result.generatedID {
            lock.lock(); lastGeneratedID = generated; lock.unlock()
        }
        return result.rowsAffected
    }

    /// Tables whose primary key is a generated `bigint` identity column.
    ///
    /// Derived from `Migrations/postgres/010_repository_schema.sql`. The other
    /// tables the repositories write -- `app_settings`, `classifications`,
    /// `conflict_acknowledgements`, `feed_tokens` -- have natural text keys and
    /// no `id` column at all, so asking for one back would make the statement
    /// fail.
    static let identityTables: Set<String> = [
        "properties", "platform_listings", "events", "availability_decisions",
        "availability_audit", "sync_runs", "feed_snapshots", "feed_publications",
        "published_feed_entries", "listing_connection_events",
        "reservations", "holds", "conflicts",
    ]

    /// Appends `RETURNING id` to an INSERT so the generated key comes back.
    ///
    /// This is a dialect mapping, not an optimisation. The RDS Data API
    /// populates `generatedFields` for MySQL's auto-increment but **not** for
    /// PostgreSQL identity columns, so `lastInsertRowID` would silently stay 0
    /// and every repository that reads it back -- properties, listings,
    /// events, decisions, the audit log -- would hand out id 0 for every row.
    /// The SQLite path is untouched: it has a real `last_insert_rowid()`.
    static func withGeneratedIDReturned(_ sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("INSERT INTO"),
              !trimmed.uppercased().contains("RETURNING") else { return sql }

        // The table name is the token after INSERT INTO, before a paren or
        // whitespace.
        let afterInto = trimmed.dropFirst("INSERT INTO".count)
            .drop(while: { $0 == " " || $0 == "\n" })
        let table = String(afterInto.prefix(while: {
            $0.isLetter || $0.isNumber || $0 == "_"
        })).lowercased()
        guard identityTables.contains(table) else { return sql }

        let withoutTrailingSemicolon = trimmed.hasSuffix(";")
            ? String(trimmed.dropLast()) : trimmed
        return withoutTrailingSemicolon + " RETURNING id"
    }

    public func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [Row] {
        try perform(sql, parameters, expecting: .read).rows
    }

    public func queryOne(_ sql: String, _ parameters: [SQLValue] = []) throws -> Row? {
        try query(sql, parameters).first
    }

    public func scalarInt(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int {
        guard let row = try queryOne(sql, parameters) else { return 0 }
        guard let first = row.values.first?.value else { return 0 }
        switch first {
        case .integer(let v): return Int(v)
        case .real(let v): return Int(v)
        case .text(let v): return Int(v) ?? 0
        default: return 0
        }
    }

    // MARK: Transactions

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try transaction(attempts: 3, body)
    }

    /// Runs `body` in a transaction, restarting the WHOLE transaction if the
    /// database rolls it back for serialisability.
    ///
    /// Restarting the whole thing is the only correct response to SQLSTATE
    /// 40001 or 40P01. PostgreSQL aborts the entire transaction, so every
    /// later statement in it fails with "current transaction is aborted" --
    /// retrying the single statement that happened to trip it would run inside
    /// a transaction the server has already discarded. An earlier revision did
    /// exactly that.
    ///
    /// `body` must therefore be safe to run more than once. Every caller in
    /// this project is: they read, decide, and write inside the same closure.
    public func transaction<T>(attempts: Int, _ body: () throws -> T) throws -> T {
        // Re-entrant: a nested call joins the outer transaction. Committing
        // here would end it early and leave the outer scope writing outside a
        // transaction without knowing it.
        if try isInTransactionOnThisThread() {
            lock.lock(); transactionDepth += 1; lock.unlock()
            defer { lock.lock(); transactionDepth -= 1; lock.unlock() }
            return try body()
        }

        var attempt = 0
        while true {
            attempt += 1
            do {
                return try runOneTransaction(body)
            } catch let error as DataAPIError {
                guard case .serializationFailure(let detail) = error,
                      attempt < max(1, attempts) else { throw error }
                // Nothing was applied, so running it again is safe. Jittered
                // so two contending writers do not retry in lockstep for ever.
                let base = min(1.0, 0.05 * pow(2, Double(attempt - 1)))
                sleeper(base + Double.random(in: 0...(base / 2)))
                _ = detail
                continue
            }
        }
    }

    /// One attempt. Guarantees that instance state is clean on every exit path
    /// — including a failed BeginTransaction, a response with no transaction
    /// id, a throwing body, a failed rollback and an unconfirmed commit.
    private func runOneTransaction<T>(_ body: () throws -> T) throws -> T {
        // Claim ownership BEFORE anything can fail, and release it in a defer,
        // so no error path can leave depth or ownership behind. The previous
        // implementation incremented the depth first and then called
        // BeginTransaction: when that throw happened, the depth stayed at 1
        // and every later transaction silently ran with no transaction at all.
        lock.lock()
        transactionDepth = 1
        transactionOwner = ObjectIdentifier(Thread.current)
        transactionID = nil
        actorDeclared = false
        lock.unlock()

        defer {
            lock.lock()
            transactionID = nil
            transactionDepth = 0
            transactionOwner = nil
            actorDeclared = false
            lock.unlock()
        }

        let begun = try call(.beginTransaction, body: baseBody())
        guard let id = begun.payload["transactionId"] as? String, !id.isEmpty else {
            throw DataAPIError.malformedResponse(
                "BeginTransaction returned no transactionId, so there is no transaction to "
                + "run in")
        }
        lock.lock(); transactionID = id; lock.unlock()

        let value: T
        do {
            value = try body()
        } catch {
            // Roll back, and report the ORIGINAL failure — except when the
            // rollback itself fails, which the caller needs to know about
            // because the server may still hold the transaction open until it
            // expires.
            lock.lock(); transactionID = nil; lock.unlock()
            var rollback = baseBody()
            rollback["transactionId"] = id
            do {
                _ = try call(.rollbackTransaction, body: rollback, insideTransaction: false)
            } catch let rollbackError {
                // A serialisation failure needs to reach the retry loop even
                // when the rollback also failed: the database has already
                // discarded the transaction either way.
                if let original = error as? DataAPIError,
                   case .serializationFailure = original {
                    throw original
                }
                throw DataAPIError.indeterminate(
                    "the transaction failed (\(error)) and the rollback also failed "
                    + "(\(rollbackError)); the server may hold this transaction open until it "
                    + "expires, and whether any of its statements applied is unknown")
            }
            throw error
        }

        var commit = baseBody()
        commit["transactionId"] = id
        lock.lock(); transactionID = nil; lock.unlock()
        do {
            // isWrite: true deliberately. A commit is the most consequential
            // write there is; retrying one whose result is unknown could apply
            // the whole transaction twice.
            _ = try call(.commitTransaction, body: commit, isWrite: true,
                         insideTransaction: false)
        } catch let error as DataAPIError {
            // A commit that was rolled back for serialisability is a clean
            // restart, not an unknown outcome.
            if case .serializationFailure = error { throw error }
            throw DataAPIError.indeterminate(
                "the commit did not confirm, so whether this change was applied is "
                + "unknown: \(error)")
        } catch {
            throw DataAPIError.indeterminate(
                "the commit did not confirm, so whether this change was applied is "
                + "unknown: \(error)")
        }
        return value
    }

    /// True when this thread already holds a transaction on this store.
    /// Throws when a DIFFERENT thread holds one, because sharing a store
    /// across threads mid-transaction would interleave statements from two
    /// transactions into whichever id happened to be set.
    private func isInTransactionOnThisThread() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let owner = transactionOwner else { return false }
        guard owner == ObjectIdentifier(Thread.current) else {
            throw DataAPIError.concurrentUse(
                "a transaction is open on another thread; give each thread its own "
                + "DataAPIStore rather than sharing one")
        }
        return true
    }

    // MARK: Plumbing

    private enum Expectation { case read, write }

    struct Outcome {
        var rows: [Row] = []
        var rowsAffected = 0
        var generatedID: Int64?
    }

    private func baseBody() -> [String: Any] {
        [
            "resourceArn": configuration.resourceArn,
            "secretArn": configuration.secretArn,
            "database": configuration.database,
        ]
    }

    private func perform(
        _ sql: String, _ parameters: [SQLValue], expecting: Expectation
    ) throws -> Outcome {
        try declareActorIfNeeded()

        let translated = SQLScanner.rewritePlaceholders(sql)
        guard translated.placeholderCount == parameters.count else {
            throw DataAPIError.unsupported(
                "\(translated.placeholderCount) placeholder(s) but \(parameters.count) "
                + "parameter(s) — refusing to guess which is right")
        }

        var body = baseBody()
        body["sql"] = translated.sql
        body["includeResultMetadata"] = true
        if !parameters.isEmpty {
            body["parameters"] = parameters.enumerated().map { index, value in
                ["name": "p\(index)", "value": Self.encode(value)]
            }
        }
        lock.lock(); let txn = transactionID; lock.unlock()
        if let txn { body["transactionId"] = txn }

        let result = try call(.execute, body: body, isWrite: expecting == .write)
        return try Self.decode(result.payload)
    }

    /// Declares the actor once per transaction (or once per statement outside
    /// one). The database guards read `vrc.actor`, and an undeclared actor is
    /// treated as the least privileged, so forgetting this is safe but
    /// useless.
    private func declareActorIfNeeded() throws {
        lock.lock()
        let inTransaction = transactionID != nil
        let already = actorDeclared
        let txn = transactionID
        lock.unlock()

        guard inTransaction, !already else { return }

        var body = baseBody()
        body["sql"] = "SELECT set_config('vrc.actor', :actor, true)"
        body["parameters"] = [["name": "actor", "value": ["stringValue": configuration.actor]]]
        if let txn { body["transactionId"] = txn }

        // Marked only AFTER the statement succeeds. An earlier revision set
        // the flag first, so a failed declaration left the store believing the
        // actor had been declared — and every subsequent statement in that
        // transaction would then run as the database's default actor,
        // 'importer', silently losing the owner's privileges.
        _ = try call(.execute, body: body, isWrite: false)
        lock.lock(); actorDeclared = true; lock.unlock()
    }

    private func call(
        _ action: DataAPICall.Action,
        body: [String: Any],
        isWrite: Bool = false,
        insideTransaction: Bool? = nil
    ) throws -> DataAPIResult {
        // Default: whatever the store's current state says.
        let withinTransaction: Bool = {
            if let insideTransaction { return insideTransaction }
            lock.lock(); defer { lock.unlock() }
            return transactionID != nil
        }()
        var attempt = 0
        var waited: TimeInterval = 0
        var lastDescription = "none"

        while attempt < configuration.maxAttempts {
            attempt += 1
            do {
                let result = try transport.send(DataAPICall(action: action, body: body))
                if (200...299).contains(result.statusCode) { return result }

                let failure = Self.classify(result)
                lastDescription = failure.description

                switch failure.kind {
                case .resuming:
                    // Expected with minimum capacity 0. Wait and try again,
                    // within a budget, because a cluster that never wakes is a
                    // real failure.
                    guard waited < configuration.resumeBudget else {
                        throw DataAPIError.retriesExhausted(
                            attempts: attempt,
                            lastError: "Aurora did not finish resuming within "
                                + "\(Int(configuration.resumeBudget))s: \(failure.description)")
                    }
                    let pause = min(5, 1 * pow(2, Double(attempt - 1)))
                    waited += pause
                    sleeper(pause)
                    continue

                case .transient:
                    // A read may be retried freely. A write may not: it might
                    // already have applied, and applying it twice is worse
                    // than failing.
                    if isWrite {
                        throw DataAPIError.indeterminate(
                            "a write failed in a way that may or may not have applied, so it "
                            + "will not be retried automatically: \(failure.description)")
                    }
                    sleeper(min(2, 0.25 * pow(2, Double(attempt - 1))))
                    continue

                case .serializationFailure:
                    // 40001 / 40P01.
                    //
                    // Inside a transaction this must NOT be retried here.
                    // PostgreSQL has aborted the whole transaction, so the
                    // retried statement would run inside one the server has
                    // already discarded and fail with "current transaction is
                    // aborted". It is surfaced so `transaction()` can restart
                    // the entire body, which is the only correct recovery.
                    if withinTransaction {
                        throw DataAPIError.serializationFailure(failure.description)
                    }
                    // Outside a transaction a single statement is its own
                    // transaction, so retrying it here is safe.
                    sleeper(min(1, 0.1 * pow(2, Double(attempt - 1))))
                    continue

                case .transactionGone:
                    // The transaction id is no longer valid, so every
                    // statement in it is lost. Retrying this one statement
                    // would silently run it outside the transaction.
                    throw DataAPIError.indeterminate(
                        "the transaction expired or was closed, so the work in it did not "
                        + "complete: \(failure.description)")

                case .permanent:
                    throw DataAPIError.http(
                        result.statusCode, type: failure.type, message: failure.message)
                }
            } catch let error as DataAPIError {
                throw error
            } catch {
                // Transport-level failure: no response at all. For a write,
                // that is precisely the indeterminate case.
                lastDescription = "\(error)"
                if isWrite {
                    throw DataAPIError.indeterminate(
                        "the database could not be reached while writing, so whether the "
                        + "change applied is unknown: \(error)")
                }
                guard attempt < configuration.maxAttempts else { break }
                sleeper(min(2, 0.25 * pow(2, Double(attempt - 1))))
            }
        }
        throw DataAPIError.retriesExhausted(attempts: attempt, lastError: lastDescription)
    }

    // MARK: Failure classification

    public enum FailureKind {
        case resuming
        case transient
        case serializationFailure
        case transactionGone
        case permanent
    }

    public struct Failure {
        public var kind: FailureKind
        public var type: String
        public var message: String
        public var description: String { "\(type): \(message)" }
    }

    public static func classify(_ result: DataAPIResult) -> Failure {
        let rawType = (result.payload["__type"] as? String)
            ?? (result.payload["code"] as? String) ?? ""
        let type = rawType.split(separator: "#").last.map(String.init) ?? rawType
        let message = (result.payload["message"] as? String)
            ?? (result.payload["Message"] as? String) ?? ""
        let haystack = (type + " " + message).lowercased()

        func failure(_ kind: FailureKind) -> Failure {
            Failure(kind: kind, type: type.isEmpty ? "HTTP \(result.statusCode)" : type,
                    message: message)
        }

        // Aurora waking from zero capacity.
        if haystack.contains("databaseresuming") || haystack.contains("resuming after being auto-paused")
            || haystack.contains("is resuming") {
            return failure(.resuming)
        }
        // A transaction that no longer exists. Checked BEFORE the generic
        // BadRequest arm, because its type is also BadRequestException.
        if haystack.contains("transaction") &&
            (haystack.contains("not found") || haystack.contains("is not valid")
             || haystack.contains("completed") || haystack.contains("aborted")) {
            return failure(.transactionGone)
        }
        // Postgres serialization failure and deadlock, surfaced in the message.
        if haystack.contains("40001") || haystack.contains("could not serialize")
            || haystack.contains("40p01") || haystack.contains("deadlock detected") {
            return failure(.serializationFailure)
        }
        if haystack.contains("throttl") || haystack.contains("toomanyrequests")
            || haystack.contains("serviceunavailable") || haystack.contains("timeout")
            || result.statusCode == 429 || result.statusCode >= 500 {
            return failure(.transient)
        }
        return failure(.permanent)
    }

    // MARK: Encoding and decoding

    public static func encode(_ value: SQLValue) -> [String: Any] {
        switch value {
        case .null: return ["isNull": true]
        case .integer(let v): return ["longValue": v]
        case .real(let v): return ["doubleValue": v]
        case .text(let v): return ["stringValue": v]
        case .blob(let v): return ["blobValue": v.base64EncodedString()]
        }
    }

    static func decode(_ payload: [String: Any]) throws -> Outcome {
        var outcome = Outcome()
        outcome.rowsAffected = (payload["numberOfRecordsUpdated"] as? Int)
            ?? Int((payload["numberOfRecordsUpdated"] as? NSNumber)?.intValue ?? 0)

        if let generated = payload["generatedFields"] as? [[String: Any]],
           let first = generated.first {
            outcome.generatedID = (first["longValue"] as? Int64)
                ?? (first["longValue"] as? NSNumber)?.int64Value
        }

        // A `RETURNING id` row. PostgreSQL does not fill generatedFields, so
        // this is where the key actually arrives.
        if outcome.generatedID == nil,
           let names = payload["columnMetadata"] as? [[String: Any]],
           names.count == 1,
           ((names[0]["name"] as? String) ?? (names[0]["label"] as? String)) == "id",
           let records = payload["records"] as? [[[String: Any]]],
           let row = records.first, let field = row.first {
            switch decodeField(field) {
            case .integer(let value): outcome.generatedID = value
            case .real(let value): outcome.generatedID = Int64(value)
            // A bigint can arrive as a string: the Data API renders some
            // numeric types as stringValue, and so does any transport that
            // reads rows as text. Refusing it here would leave every
            // repository handing out id 0.
            case .text(let value): outcome.generatedID = Int64(value)
            default: break
            }
            // An INSERT ... RETURNING reports no updated-row count, but it did
            // insert exactly the rows it returned.
            if outcome.rowsAffected == 0 { outcome.rowsAffected = records.count }
        }

        guard let records = payload["records"] as? [[[String: Any]]] else {
            return outcome
        }
        let names: [String] = (payload["columnMetadata"] as? [[String: Any]])?
            .map { ($0["name"] as? String) ?? ($0["label"] as? String) ?? "" }
            ?? []
        guard names.isEmpty || names.allSatisfy({ !$0.isEmpty }) else {
            throw DataAPIError.malformedResponse("a result column has no name")
        }

        outcome.rows = records.map { record in
            var values: [String: SQLValue] = [:]
            for (index, field) in record.enumerated() {
                let name = index < names.count ? names[index] : "column\(index)"
                values[name] = decodeField(field)
            }
            return Row(values: values)
        }
        return outcome
    }

    public static func decodeField(_ field: [String: Any]) -> SQLValue {
        if (field["isNull"] as? Bool) == true { return .null }
        if let v = field["stringValue"] as? String { return .text(v) }
        if let v = field["longValue"] as? Int64 { return .integer(v) }
        if let v = field["longValue"] as? NSNumber { return .integer(v.int64Value) }
        if let v = field["doubleValue"] as? Double { return .real(v) }
        if let v = field["doubleValue"] as? NSNumber { return .real(v.doubleValue) }
        if let v = field["booleanValue"] as? Bool { return .integer(v ? 1 : 0) }
        if let v = field["blobValue"] as? String, let data = Data(base64Encoded: v) {
            return .blob(data)
        }
        return .null
    }
}
