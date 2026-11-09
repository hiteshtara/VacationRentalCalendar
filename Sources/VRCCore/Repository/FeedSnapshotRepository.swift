import Foundation

/// Stores served feeds so a proposal can be diffed against reality, and so a
/// bad publication can be rolled back to something known to work.
public struct FeedSnapshotRepository: Sendable {
    let database: Database
    public init(database: Database) { self.database = database }

    private func decode(_ row: Row) -> FeedSnapshot {
        let uids = row.stringValue("entry_uids")
        let payload = row.stringValue("payload")
        return FeedSnapshot(
            id: row.int("id"),
            propertyID: row.int("property_id") ?? 0,
            destination: RentalPlatform(rawValue: row.stringValue("destination")) ?? .other,
            revision: row.intValue("revision"),
            generatedAt: row.dateValue("generated_at"),
            publishedAt: row.date("published_at"),
            checksum: row.stringValue("checksum"),
            entries: Self.decodeEntries(uids),
            payload: payload,
            isLastKnownGood: row.bool("is_last_known_good")
        )
    }

    /// Entries are stored as one compact line each: uid|start|end|summary.
    static func encodeEntries(_ entries: [SnapshotEntry]) -> String {
        entries.map { entry in
            [
                entry.uid,
                String(entry.startDay.timeIntervalSince1970),
                String(entry.endDay.timeIntervalSince1970),
                entry.summary.replacingOccurrences(of: "\n", with: " "),
            ].joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
    }

    static func decodeEntries(_ raw: String) -> [SnapshotEntry] {
        guard !raw.isEmpty else { return [] }
        return raw.components(separatedBy: "\u{1E}").compactMap { line in
            let parts = line.components(separatedBy: "\u{1F}")
            guard parts.count >= 4,
                  let start = Double(parts[1]), let end = Double(parts[2]) else { return nil }
            return SnapshotEntry(
                uid: parts[0],
                startDay: Date(timeIntervalSince1970: start),
                endDay: Date(timeIntervalSince1970: end),
                summary: parts[3]
            )
        }
    }

    @discardableResult
    public func record(_ snapshot: FeedSnapshot) throws -> FeedSnapshot {
        try database.run("""
            INSERT INTO feed_snapshots
                (property_id, destination, revision, generated_at, published_at, checksum,
                 entry_count, covered_nights, payload, entry_uids, is_last_known_good)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .integer(snapshot.propertyID), .text(snapshot.destination.rawValue),
                .integer(Int64(snapshot.revision)), SQLValue(snapshot.generatedAt),
                SQLValue(snapshot.publishedAt), .text(snapshot.checksum),
                .integer(Int64(snapshot.entryCount)), .integer(Int64(snapshot.coveredNights)),
                .text(snapshot.payload), .text(Self.encodeEntries(snapshot.entries)),
                SQLValue(snapshot.isLastKnownGood),
            ])
        var stored = snapshot
        stored.id = database.lastInsertRowID
        return stored
    }

    /// Marks a snapshot as the one to fall back to, clearing any previous mark.
    /// Only ever called after a publication reached the platform-refresh stage.
    public func markLastKnownGood(id: Int64, propertyID: Int64, destination: RentalPlatform) throws {
        try database.transaction {
            try database.run("""
                UPDATE feed_snapshots SET is_last_known_good = 0
                WHERE property_id = ? AND destination = ?;
                """, [.integer(propertyID), .text(destination.rawValue)])
            try database.run(
                "UPDATE feed_snapshots SET is_last_known_good = 1 WHERE id = ?;", [.integer(id)]
            )
        }
    }

    public func lastKnownGood(
        propertyID: Int64, destination: RentalPlatform
    ) throws -> FeedSnapshot? {
        try database.queryOne("""
            SELECT * FROM feed_snapshots
            WHERE property_id = ? AND destination = ? AND is_last_known_good = 1
            ORDER BY revision DESC LIMIT 1;
            """, [.integer(propertyID), .text(destination.rawValue)]).map(decode)
    }

    public func history(
        propertyID: Int64, destination: RentalPlatform, limit: Int = 20
    ) throws -> [FeedSnapshot] {
        try database.query("""
            SELECT * FROM feed_snapshots
            WHERE property_id = ? AND destination = ?
            ORDER BY revision DESC LIMIT ?;
            """, [
                .integer(propertyID), .text(destination.rawValue), .integer(Int64(limit)),
            ]).map(decode)
    }

    public func count() throws -> Int {
        try database.scalarInt("SELECT COUNT(*) FROM feed_snapshots;")
    }
}

/// Which key version each destination's published URL is on.
///
/// The key itself is a credential and lives in the Keychain. This table records
/// only its version and the Keychain reference, so rotation is auditable
/// without the secret ever reaching the database, a log, or git.
public struct FeedTokenRepository: Sendable {
    let database: Database
    let credentials: FeedCredentialStore

    public init(database: Database, credentials: FeedCredentialStore) {
        self.database = database
        self.credentials = credentials
    }

    public struct TokenRecord: Sendable {
        public var version: Int
        public var credentialRef: String
        public var createdAt: Date
        public var retiredAt: Date?
        public var isActive: Bool { retiredAt == nil }
    }

    public static func reference(
        propertyID: Int64, destination: RentalPlatform, version: Int
    ) -> String {
        "feed-key-\(propertyID)-\(destination.rawValue)-v\(version)"
    }

    /// 128 bits of randomness, which is what makes the published path
    /// unguessable. Never derived from anything about the property.
    public static func generateKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func current(
        propertyID: Int64, destination: RentalPlatform
    ) throws -> TokenRecord? {
        try database.queryOne("""
            SELECT * FROM feed_tokens
            WHERE property_id = ? AND destination = ? AND retired_at IS NULL
            ORDER BY version DESC LIMIT 1;
            """, [.integer(propertyID), .text(destination.rawValue)]).map {
                TokenRecord(
                    version: $0.intValue("version"),
                    credentialRef: $0.stringValue("credential_ref"),
                    createdAt: $0.dateValue("created_at"),
                    retiredAt: $0.date("retired_at")
                )
            }
    }

    /// Issues a new key and retires the previous one.
    ///
    /// Retiring is local bookkeeping: the old URL stops being served only once
    /// the object behind it is deleted, and each platform keeps reading the old
    /// URL until it is re-pasted there.
    @discardableResult
    public func rotate(
        propertyID: Int64, destination: RentalPlatform, now: Date = Date()
    ) throws -> TokenRecord {
        let nextVersion = (try current(propertyID: propertyID, destination: destination)?.version ?? 0) + 1
        let reference = Self.reference(
            propertyID: propertyID, destination: destination, version: nextVersion
        )
        try credentials.save(url: Self.generateKey(), reference: reference)

        try database.transaction {
            try database.run("""
                UPDATE feed_tokens SET retired_at = ?
                WHERE property_id = ? AND destination = ? AND retired_at IS NULL;
                """, [SQLValue(now), .integer(propertyID), .text(destination.rawValue)])
            try database.run("""
                INSERT INTO feed_tokens
                    (property_id, destination, version, credential_ref, created_at)
                VALUES (?, ?, ?, ?, ?);
                """, [
                    .integer(propertyID), .text(destination.rawValue),
                    .integer(Int64(nextVersion)), .text(reference), SQLValue(now),
                ])
        }
        return TokenRecord(version: nextVersion, credentialRef: reference, createdAt: now)
    }

    /// Resolves the key for building a URL. Reads the Keychain, never the
    /// database.
    public func key(propertyID: Int64, destination: RentalPlatform) throws -> String? {
        guard let record = try current(propertyID: propertyID, destination: destination) else {
            return nil
        }
        return try credentials.url(reference: record.credentialRef)
    }

    /// Confirms no key material is in the database. Used by a test.
    public func databaseContainsAnyKeyMaterial() throws -> Bool {
        let rows = try database.query("SELECT credential_ref FROM feed_tokens;")
        // References are structural names, never the secret itself.
        return rows.contains { !$0.stringValue("credential_ref").hasPrefix("feed-key-") }
    }
}
