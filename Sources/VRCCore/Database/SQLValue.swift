import Foundation

/// A value that can cross the SQLite boundary.
public enum SQLValue: Hashable, Sendable, ExpressibleByStringLiteral,
                      ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
                      ExpressibleByNilLiteral {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int) { self = .integer(Int64(value)) }
    public init(booleanLiteral value: Bool) { self = .integer(value ? 1 : 0) }
    public init(nilLiteral: ()) { self = .null }

    public init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    public init(_ value: Int64?) { self = value.map { .integer($0) } ?? .null }
    public init(_ value: Int?) { self = value.map { .integer(Int64($0)) } ?? .null }
    public init(_ value: Bool) { self = .integer(value ? 1 : 0) }
    public init(_ value: Double?) { self = value.map { .real($0) } ?? .null }

    /// Dates are stored as fractional unix seconds — sortable, time-zone free.
    public init(_ value: Date?) { self = value.map { .real($0.timeIntervalSince1970) } ?? .null }
}

/// One result row, addressed by column name.
public struct Row: Sendable {
    public let values: [String: SQLValue]

    public init(values: [String: SQLValue]) { self.values = values }

    public func int(_ column: String) -> Int64? {
        switch values[column] {
        case .integer(let v): return v
        case .real(let v): return Int64(v)
        case .text(let v): return Int64(v)
        default: return nil
        }
    }

    public func intValue(_ column: String, default fallback: Int = 0) -> Int {
        int(column).map { Int($0) } ?? fallback
    }

    public func bool(_ column: String, default fallback: Bool = false) -> Bool {
        int(column).map { $0 != 0 } ?? fallback
    }

    public func double(_ column: String) -> Double? {
        switch values[column] {
        case .real(let v): return v
        case .integer(let v): return Double(v)
        case .text(let v): return Double(v)
        default: return nil
        }
    }

    public func string(_ column: String) -> String? {
        switch values[column] {
        case .text(let v): return v
        case .integer(let v): return String(v)
        case .real(let v): return String(v)
        default: return nil
        }
    }

    public func stringValue(_ column: String, default fallback: String = "") -> String {
        string(column) ?? fallback
    }

    public func date(_ column: String) -> Date? {
        double(column).map { Date(timeIntervalSince1970: $0) }
    }

    public func dateValue(_ column: String, default fallback: Date = Date()) -> Date {
        date(column) ?? fallback
    }
}
