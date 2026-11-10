import Foundation

public struct PropertyRepository: Sendable {
    let database: DataStore
    public init(database: DataStore) { self.database = database }

    private func decode(_ row: Row) -> Property {
        Property(
            id: row.int("id"),
            name: row.stringValue("name"),
            address: row.stringValue("address"),
            notes: row.stringValue("notes"),
            timeZone: {
                let zone = row.stringValue("time_zone")
                return zone.isEmpty ? "UTC" : zone
            }(),
            archivedAt: row.date("archived_at"),
            createdAt: row.dateValue("created_at"),
            updatedAt: row.dateValue("updated_at")
        )
    }

    @discardableResult
    public func insert(_ property: Property) throws -> Property {
        let now = Date()
        try database.run("""
            INSERT INTO properties
                (name, address, notes, time_zone, archived_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """, [
                .text(property.name), .text(property.address), .text(property.notes),
                .text(property.timeZone), SQLValue(property.archivedAt),
                SQLValue(now), SQLValue(now),
            ])
        var stored = property
        stored.id = database.lastInsertRowID
        stored.createdAt = now
        stored.updatedAt = now
        return stored
    }

    public func update(_ property: Property) throws {
        guard let id = property.id else { return }
        try database.run("""
            UPDATE properties
               SET name = ?, address = ?, notes = ?, time_zone = ?, updated_at = ?
             WHERE id = ?;
            """, [
                .text(property.name), .text(property.address), .text(property.notes),
                .text(property.timeZone), SQLValue(Date()), .integer(id),
            ])
    }

    public func delete(id: Int64) throws {
        try database.run("DELETE FROM properties WHERE id = ?;", [.integer(id)])
    }

    public func all() throws -> [Property] {
        // lower(name) rather than COLLATE NOCASE: the collation is a SQLite
        // name that PostgreSQL does not have, and lower() gives the same
        // case-insensitive ordering on both. One code path beats a dialect
        // branch for something this small.
        try database.query("SELECT * FROM properties ORDER BY lower(name);")
            .map(decode)
    }

    public func find(id: Int64) throws -> Property? {
        try database.queryOne("SELECT * FROM properties WHERE id = ?;", [.integer(id)])
            .map(decode)
    }

    /// The active portfolio — everything not archived.
    ///
    /// `all()` deliberately still returns archived properties: history, audits
    /// and past publications must stay reachable, and a view that needs them
    /// should not have to go around the repository to get them.
    public func active() throws -> [Property] {
        try database.query("""
            SELECT * FROM properties WHERE archived_at IS NULL ORDER BY lower(name);
            """).map(decode)
    }

    /// Removes a property from the active portfolio without destroying
    /// anything. Archiving is never deletion: its observations, decisions and
    /// audit rows are exactly what explain what happened to nights now past.
    public func archive(id: Int64, at date: Date = Date()) throws {
        try database.run(
            "UPDATE properties SET archived_at = ?, updated_at = ? WHERE id = ?;",
            [SQLValue(date), SQLValue(Date()), .integer(id)])
    }

    public func unarchive(id: Int64) throws {
        try database.run("""
            UPDATE properties SET archived_at = NULL, updated_at = ? WHERE id = ?;
            """, [SQLValue(Date()), .integer(id)])
    }

    public func count() throws -> Int {
        try database.scalarInt("SELECT COUNT(*) FROM properties;")
    }
}
