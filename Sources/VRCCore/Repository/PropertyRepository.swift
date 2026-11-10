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
            createdAt: row.dateValue("created_at"),
            updatedAt: row.dateValue("updated_at")
        )
    }

    @discardableResult
    public func insert(_ property: Property) throws -> Property {
        let now = Date()
        try database.run("""
            INSERT INTO properties (name, address, notes, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?);
            """, [
                .text(property.name), .text(property.address), .text(property.notes),
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
            UPDATE properties SET name = ?, address = ?, notes = ?, updated_at = ?
            WHERE id = ?;
            """, [
                .text(property.name), .text(property.address), .text(property.notes),
                SQLValue(Date()), .integer(id),
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

    public func count() throws -> Int {
        try database.scalarInt("SELECT COUNT(*) FROM properties;")
    }
}
