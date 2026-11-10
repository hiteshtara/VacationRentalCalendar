import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Thin, synchronous wrapper over the SQLite C API.
///
/// Serialised with a recursive lock so the SwiftUI main actor and background
/// refresh tasks can share one connection without stepping on each other.
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let path: String

    // MARK: - Lifecycle

    public init(path: String) throws {
        self.path = path
        if path != ":memory:" {
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try? FileManager.default.createDirectory(
                    atPath: directory, withIntermediateDirectories: true
                )
            }
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError.openFailed(path: path, message: message)
        }
        self.handle = handle
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA busy_timeout = 5000;")
        if path != ":memory:" {
            try execute("PRAGMA journal_mode = WAL;")
        }
    }

    /// A throwaway database for tests.
    public static func inMemory() throws -> Database {
        try Database(path: ":memory:")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    // MARK: - Primitives

    private func requireHandle() throws -> OpaquePointer {
        guard let handle else { throw SQLiteError.notOpen }
        return handle
    }

    private func message(_ handle: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(handle))
    }

    /// Runs one or more statements with no parameters and no results.
    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        let handle = try requireHandle()
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let text = errorPointer.map { String(cString: $0) } ?? message(handle)
            sqlite3_free(errorPointer)
            throw SQLiteError.executeFailed(sql: sql, message: text)
        }
    }

    private func bind(_ statement: OpaquePointer, _ parameters: [SQLValue]) {
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null:
                sqlite3_bind_null(statement, index)
            case .integer(let v):
                sqlite3_bind_int64(statement, index, v)
            case .real(let v):
                sqlite3_bind_double(statement, index, v)
            case .text(let v):
                sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                if data.isEmpty {
                    sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    _ = data.withUnsafeBytes {
                        sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                    }
                }
            }
        }
    }

    /// Executes a parameterised statement that returns no rows.
    @discardableResult
    public func run(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let handle = try requireHandle()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(sql: sql, message: message(handle))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, parameters)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError.stepFailed(sql: sql, message: message(handle))
        }
        return Int(sqlite3_changes(handle))
    }

    /// Executes a parameterised query and materialises every row.
    public func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [Row] {
        lock.lock(); defer { lock.unlock() }
        let handle = try requireHandle()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(sql: sql, message: message(handle))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, parameters)

        let columnCount = Int(sqlite3_column_count(statement))
        var names: [String] = []
        names.reserveCapacity(columnCount)
        for index in 0..<columnCount {
            names.append(String(cString: sqlite3_column_name(statement, Int32(index))))
        }

        var rows: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteError.stepFailed(sql: sql, message: message(handle))
            }
            var values: [String: SQLValue] = [:]
            values.reserveCapacity(columnCount)
            for index in 0..<columnCount {
                let i = Int32(index)
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER:
                    values[names[index]] = .integer(sqlite3_column_int64(statement, i))
                case SQLITE_FLOAT:
                    values[names[index]] = .real(sqlite3_column_double(statement, i))
                case SQLITE_TEXT:
                    if let cString = sqlite3_column_text(statement, i) {
                        values[names[index]] = .text(String(cString: cString))
                    } else {
                        values[names[index]] = .null
                    }
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(statement, i))
                    if let pointer = sqlite3_column_blob(statement, i), length > 0 {
                        values[names[index]] = .blob(Data(bytes: pointer, count: length))
                    } else {
                        values[names[index]] = .blob(Data())
                    }
                default:
                    values[names[index]] = .null
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    public func queryOne(_ sql: String, _ parameters: [SQLValue] = []) throws -> Row? {
        try query(sql, parameters).first
    }

    public func scalarInt(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int {
        guard let row = try queryOne(sql, parameters),
              let first = row.values.values.first else { return 0 }
        switch first {
        case .integer(let v): return Int(v)
        case .real(let v): return Int(v)
        case .text(let v): return Int(v) ?? 0
        default: return 0
        }
    }

    public var lastInsertRowID: Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    // MARK: - Transactions

    /// Runs `body` inside a transaction, rolling back on any thrown error.
    /// Safe to nest: inner calls join the outer transaction via savepoints.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let name = "sp_\(abs(UUID().hashValue))"
        try execute("SAVEPOINT \(name);")
        do {
            let value = try body()
            try execute("RELEASE SAVEPOINT \(name);")
            return value
        } catch {
            try? execute("ROLLBACK TO SAVEPOINT \(name);")
            try? execute("RELEASE SAVEPOINT \(name);")
            throw error
        }
    }
}

// SQLITE_TRANSIENT tells SQLite to copy the bound bytes, which is what we want
// because the Swift strings go out of scope as soon as binding returns.
private let SQLITE_TRANSIENT = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self
)
