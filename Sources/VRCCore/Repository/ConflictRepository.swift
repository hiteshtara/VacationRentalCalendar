import Foundation

/// Conflicts are recomputed from events on demand rather than stored, because a
/// stored conflict can go stale the moment a feed changes. Only the owner's
/// acknowledgement is persisted.
public struct ConflictRepository: Sendable {
    let database: Database
    public init(database: Database) { self.database = database }

    public func acknowledge(conflictID: String, note: String = "") throws {
        try database.run("""
            INSERT INTO conflict_acknowledgements (conflict_id, acknowledged_at, note)
            VALUES (?, ?, ?)
            ON CONFLICT(conflict_id) DO UPDATE SET
                acknowledged_at = excluded.acknowledged_at,
                note = excluded.note;
            """, [.text(conflictID), SQLValue(Date()), .text(note)])
    }

    public func unacknowledge(conflictID: String) throws {
        try database.run(
            "DELETE FROM conflict_acknowledgements WHERE conflict_id = ?;", [.text(conflictID)]
        )
    }

    public func acknowledgedIDs() throws -> Set<String> {
        Set(
            try database.query("SELECT conflict_id FROM conflict_acknowledgements;")
                .map { $0.stringValue("conflict_id") }
        )
    }
}
