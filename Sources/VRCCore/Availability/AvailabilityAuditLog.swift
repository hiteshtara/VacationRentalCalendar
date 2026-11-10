import Foundation

/// One line in the permanent record.
public struct AuditEntry: Identifiable, Sendable, Hashable {
    public var id: Int64?
    public var decisionID: Int64?
    public var at: Date
    public var actor: String
    public var fromStatus: AvailabilityStatus?
    public var toStatus: AvailabilityStatus?
    /// Short machine-ish name: created, validated, approved, cancelled, …
    public var event: String
    public var detail: String

    public init(
        id: Int64? = nil,
        decisionID: Int64?,
        at: Date = Date(),
        actor: String = "owner",
        fromStatus: AvailabilityStatus? = nil,
        toStatus: AvailabilityStatus? = nil,
        event: String,
        detail: String = ""
    ) {
        self.id = id
        self.decisionID = decisionID
        self.at = at
        self.actor = actor
        self.fromStatus = fromStatus
        self.toStatus = toStatus
        self.event = event
        self.detail = detail
    }

    public var line: String {
        var text = "\(DayMath.mediumString(at))  \(event)"
        if let fromStatus, let toStatus {
            text += "  \(fromStatus.rawValue) → \(toStatus.rawValue)"
        }
        if !detail.isEmpty { text += "  — \(detail)" }
        return text
    }
}

/// Append-only history of every availability decision and approval.
///
/// Nothing in this type updates or deletes a row. If a decision is cancelled,
/// that is another entry, not an erasure — the question "what did I approve,
/// and when?" has to stay answerable afterwards.
public struct AvailabilityAuditLog: Sendable {
    let database: DataStore

    public init(database: DataStore) { self.database = database }

    @discardableResult
    public func record(_ entry: AuditEntry) throws -> AuditEntry {
        try database.run("""
            INSERT INTO availability_audit
                (decision_id, at, actor, from_status, to_status, event, detail)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """, [
                SQLValue(entry.decisionID), SQLValue(entry.at), .text(entry.actor),
                SQLValue(entry.fromStatus?.rawValue), SQLValue(entry.toStatus?.rawValue),
                .text(entry.event), .text(entry.detail),
            ])
        var stored = entry
        stored.id = database.lastInsertRowID
        return stored
    }

    private func decode(_ row: Row) -> AuditEntry {
        AuditEntry(
            id: row.int("id"),
            decisionID: row.int("decision_id"),
            at: row.dateValue("at"),
            actor: row.stringValue("actor"),
            fromStatus: row.string("from_status").flatMap(AvailabilityStatus.init(rawValue:)),
            toStatus: row.string("to_status").flatMap(AvailabilityStatus.init(rawValue:)),
            event: row.stringValue("event"),
            detail: row.stringValue("detail")
        )
    }

    public func entries(forDecision id: Int64) throws -> [AuditEntry] {
        try database.query(
            "SELECT * FROM availability_audit WHERE decision_id = ? ORDER BY at, id;",
            [.integer(id)]
        ).map(decode)
    }

    public func recent(limit: Int = 200) throws -> [AuditEntry] {
        try database.query(
            "SELECT * FROM availability_audit ORDER BY at DESC, id DESC LIMIT ?;",
            [.integer(Int64(limit))]
        ).map(decode)
    }

    public func count() throws -> Int {
        try database.scalarInt("SELECT COUNT(*) FROM availability_audit;")
    }
}
