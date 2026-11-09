import Foundation

public enum SQLiteError: Error, LocalizedError, CustomStringConvertible {
    case openFailed(path: String, message: String)
    case prepareFailed(sql: String, message: String)
    case stepFailed(sql: String, message: String)
    case executeFailed(sql: String, message: String)
    case migrationFailed(version: Int, name: String, message: String)
    case notOpen

    public var description: String { errorDescription ?? "SQLite error" }

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let message):
            return "Could not open the database at \(path): \(message)"
        case .prepareFailed(let sql, let message):
            return "Could not prepare statement: \(message)\nSQL: \(sql)"
        case .stepFailed(let sql, let message):
            return "Statement failed: \(message)\nSQL: \(sql)"
        case .executeFailed(let sql, let message):
            return "Could not execute SQL: \(message)\nSQL: \(sql)"
        case .migrationFailed(let version, let name, let message):
            return "Migration \(version) (\(name)) failed: \(message)"
        case .notOpen:
            return "The database is not open."
        }
    }
}
