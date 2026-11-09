import Foundation

/// Reads and writes listings, routing the iCal URL through the credential store
/// whenever the listing is marked as Keychain-backed.
public struct ListingRepository: Sendable {
    let database: Database
    let credentials: FeedCredentialStore

    public init(database: Database, credentials: FeedCredentialStore) {
        self.database = database
        self.credentials = credentials
    }

    /// Deterministic, readable Keychain account name.
    public static func credentialReference(platform: RentalPlatform, listingLabel: String) -> String {
        let slug = listingLabel
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(platform.rawValue)-\(slug.isEmpty ? UUID().uuidString.lowercased() : slug)"
    }

    /// Decodes a row **without** touching the credential store.
    ///
    /// Reading the Keychain here would mean every listing query triggers a
    /// Keychain call, and on an unsigned local build each of those can block on
    /// an authorisation prompt. URLs are therefore resolved lazily, only when an
    /// import or the settings screen actually needs one — see `resolveURL`.
    private func decode(_ row: Row) -> PlatformListing {
        let storage = FeedURLStorage(rawValue: row.stringValue("url_storage")) ?? .database
        let reference = row.stringValue("credential_ref")
        let url = storage == .database ? row.stringValue("ical_url") : ""
        return PlatformListing(
            id: row.int("id"),
            propertyID: row.int("property_id") ?? 0,
            platform: RentalPlatform(rawValue: row.stringValue("platform")) ?? .other,
            label: row.stringValue("label"),
            icalURL: url,
            urlStorage: storage,
            credentialRef: reference,
            autoRefreshEnabled: row.bool("auto_refresh_enabled", default: true),
            lastSyncAt: row.date("last_sync_at"),
            lastSyncSummary: row.stringValue("last_sync_summary"),
            createdAt: row.dateValue("created_at"),
            updatedAt: row.dateValue("updated_at")
        )
    }

    /// Splits a listing into the part that may be persisted and the part that
    /// must go to the credential store. Returns the value for `ical_url`.
    private func persistURL(_ listing: PlatformListing) throws -> (column: String, reference: String) {
        switch listing.urlStorage {
        case .database:
            return (listing.icalURL, listing.credentialRef)
        case .keychain:
            let reference = listing.credentialRef.isEmpty
                ? Self.credentialReference(platform: listing.platform, listingLabel: listing.label)
                : listing.credentialRef
            if listing.hasURL {
                try credentials.save(url: listing.icalURL, reference: reference)
            }
            // Deliberately store nothing in the database column.
            return ("", reference)
        }
    }

    @discardableResult
    public func insert(_ listing: PlatformListing) throws -> PlatformListing {
        let now = Date()
        let (column, reference) = try persistURL(listing)
        try database.run("""
            INSERT INTO platform_listings
                (property_id, platform, label, ical_url, url_storage, credential_ref,
                 auto_refresh_enabled, last_sync_at, last_sync_summary,
                 created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .integer(listing.propertyID), .text(listing.platform.rawValue),
                .text(listing.label), .text(column), .text(listing.urlStorage.rawValue),
                .text(reference), SQLValue(listing.autoRefreshEnabled),
                SQLValue(listing.lastSyncAt), .text(listing.lastSyncSummary),
                SQLValue(now), SQLValue(now),
            ])
        var stored = listing
        stored.id = database.lastInsertRowID
        stored.credentialRef = reference
        return stored
    }

    public func update(_ listing: PlatformListing) throws {
        guard let id = listing.id else { return }
        let (column, reference) = try persistURL(listing)
        try database.run("""
            UPDATE platform_listings
            SET property_id = ?, platform = ?, label = ?, ical_url = ?,
                url_storage = ?, credential_ref = ?, auto_refresh_enabled = ?,
                updated_at = ?
            WHERE id = ?;
            """, [
                .integer(listing.propertyID), .text(listing.platform.rawValue),
                .text(listing.label), .text(column), .text(listing.urlStorage.rawValue),
                .text(reference), SQLValue(listing.autoRefreshEnabled),
                SQLValue(Date()), .integer(id),
            ])
    }

    public func recordSync(listingID: Int64, at date: Date, summary: String) throws {
        try database.run("""
            UPDATE platform_listings SET last_sync_at = ?, last_sync_summary = ?, updated_at = ?
            WHERE id = ?;
            """, [SQLValue(date), .text(summary), SQLValue(Date()), .integer(listingID)])
    }

    public func delete(id: Int64) throws {
        if let listing = try find(id: id), listing.urlStorage == .keychain,
           !listing.credentialRef.isEmpty {
            try? credentials.delete(reference: listing.credentialRef)
        }
        try database.run("DELETE FROM platform_listings WHERE id = ?;", [.integer(id)])
    }

    public func all() throws -> [PlatformListing] {
        try database.query("SELECT * FROM platform_listings ORDER BY property_id, platform;")
            .map(decode)
    }

    public func forProperty(_ propertyID: Int64) throws -> [PlatformListing] {
        try database.query(
            "SELECT * FROM platform_listings WHERE property_id = ? ORDER BY platform;",
            [.integer(propertyID)]
        ).map(decode)
    }

    public func find(id: Int64) throws -> PlatformListing? {
        try database.queryOne("SELECT * FROM platform_listings WHERE id = ?;", [.integer(id)])
            .map(decode)
    }

    /// Fetches the listing's feed URL, reading the credential store only when
    /// the listing is Keychain-backed. Call this at the moment a URL is needed.
    public func resolveURL(for listing: PlatformListing) throws -> String {
        switch listing.urlStorage {
        case .database:
            return listing.icalURL
        case .keychain:
            guard !listing.credentialRef.isEmpty else { return listing.icalURL }
            if !listing.icalURL.isEmpty { return listing.icalURL }
            return try credentials.url(reference: listing.credentialRef) ?? ""
        }
    }

    /// Whether a URL is stored for this listing. Safe to call while drawing the
    /// interface: it never reads the credential itself, so it never prompts.
    public func hasCredential(for listing: PlatformListing) -> Bool {
        switch listing.urlStorage {
        case .database: return !listing.icalURL.isEmpty
        case .keychain:
            guard !listing.credentialRef.isEmpty else { return !listing.icalURL.isEmpty }
            return credentials.exists(reference: listing.credentialRef)
        }
    }

    /// Same as `resolveURL` but never throws, for display paths where a missing
    /// URL is simply "not configured".
    public func resolvedURLIfAvailable(for listing: PlatformListing) -> String {
        (try? resolveURL(for: listing)) ?? ""
    }

    public func count() throws -> Int {
        try database.scalarInt("SELECT COUNT(*) FROM platform_listings;")
    }

    /// Confirms that the database file holds no feed URL for Keychain-backed
    /// listings. Used by the tests and by the app's own self-check.
    public func databaseLeaksAnyKeychainURL() throws -> Bool {
        let rows = try database.query("""
            SELECT ical_url FROM platform_listings
            WHERE url_storage = 'keychain' AND ical_url != '';
            """)
        return !rows.isEmpty
    }
}
