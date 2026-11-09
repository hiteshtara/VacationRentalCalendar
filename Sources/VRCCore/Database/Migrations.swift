import Foundation

/// One forward-only schema step.
public struct Migration: Sendable {
    public let version: Int
    public let name: String
    public let sql: String
}

/// Forward-only migration runner.
///
/// Every step is applied inside a transaction together with the bookkeeping row
/// that records it, so a half-applied migration cannot be left behind.
public enum Migrator {
    public static let migrations: [Migration] = [
        Migration(version: 1, name: "core_schema", sql: """
        CREATE TABLE properties (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            name        TEXT NOT NULL,
            address     TEXT NOT NULL DEFAULT '',
            notes       TEXT NOT NULL DEFAULT '',
            created_at  REAL NOT NULL,
            updated_at  REAL NOT NULL
        );

        CREATE TABLE platform_listings (
            id                   INTEGER PRIMARY KEY AUTOINCREMENT,
            property_id          INTEGER NOT NULL
                                 REFERENCES properties(id) ON DELETE CASCADE,
            platform             TEXT NOT NULL,
            label                TEXT NOT NULL DEFAULT '',
            ical_url             TEXT NOT NULL DEFAULT '',
            auto_refresh_enabled INTEGER NOT NULL DEFAULT 1,
            last_sync_at         REAL,
            last_sync_summary    TEXT NOT NULL DEFAULT '',
            created_at           REAL NOT NULL,
            updated_at           REAL NOT NULL
        );
        CREATE INDEX idx_listings_property ON platform_listings(property_id);

        CREATE TABLE events (
            id                         INTEGER PRIMARY KEY AUTOINCREMENT,
            listing_id                 INTEGER NOT NULL
                                       REFERENCES platform_listings(id) ON DELETE CASCADE,
            event_key                  TEXT NOT NULL UNIQUE,
            uid                        TEXT NOT NULL,
            recurrence_id              TEXT,
            platform                   TEXT NOT NULL,
            summary                    TEXT NOT NULL DEFAULT '',
            details                    TEXT NOT NULL DEFAULT '',
            location                   TEXT NOT NULL DEFAULT '',
            check_in                   REAL NOT NULL,
            check_out                  REAL NOT NULL,
            is_all_day                 INTEGER NOT NULL DEFAULT 1,
            feed_status                TEXT NOT NULL DEFAULT 'confirmed',
            sequence                   INTEGER NOT NULL DEFAULT 0,
            last_modified              REAL,
            content_hash               TEXT NOT NULL DEFAULT '',
            first_seen_at              REAL NOT NULL,
            last_seen_at               REAL NOT NULL,
            is_tombstoned              INTEGER NOT NULL DEFAULT 0,
            has_unsupported_recurrence INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX idx_events_listing ON events(listing_id);
        CREATE INDEX idx_events_range   ON events(check_in, check_out);

        -- Keyed by event_key and deliberately NOT a foreign key onto events:
        -- a decision the owner made must outlive the row it was made about, so
        -- that a feed removing and re-adding an event cannot erase it.
        CREATE TABLE classifications (
            event_key         TEXT PRIMARY KEY,
            kind              TEXT NOT NULL,
            confidence        TEXT NOT NULL,
            source            TEXT NOT NULL,
            needs_review      INTEGER NOT NULL DEFAULT 1,
            rationale         TEXT NOT NULL DEFAULT '',
            note              TEXT NOT NULL DEFAULT '',
            export_approved   INTEGER NOT NULL DEFAULT 0,
            export_suppressed INTEGER NOT NULL DEFAULT 0,
            decided_at        REAL NOT NULL
        );

        CREATE TABLE sync_runs (
            id                     INTEGER PRIMARY KEY AUTOINCREMENT,
            listing_id             INTEGER NOT NULL,
            started_at             REAL NOT NULL,
            finished_at            REAL,
            outcome                TEXT NOT NULL,
            http_status            INTEGER,
            events_seen            INTEGER NOT NULL DEFAULT 0,
            events_inserted        INTEGER NOT NULL DEFAULT 0,
            events_updated         INTEGER NOT NULL DEFAULT 0,
            events_tombstoned      INTEGER NOT NULL DEFAULT 0,
            events_needing_review  INTEGER NOT NULL DEFAULT 0,
            error_message          TEXT
        );
        """),

        Migration(version: 2, name: "conflicts_and_settings", sql: """
        CREATE TABLE conflict_acknowledgements (
            conflict_id     TEXT PRIMARY KEY,
            acknowledged_at REAL NOT NULL,
            note            TEXT NOT NULL DEFAULT ''
        );

        CREATE TABLE app_settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """),

        Migration(version: 3, name: "query_indexes", sql: """
        CREATE INDEX IF NOT EXISTS idx_classifications_review
            ON classifications(needs_review);
        CREATE INDEX IF NOT EXISTS idx_sync_runs_listing
            ON sync_runs(listing_id, started_at DESC);
        CREATE INDEX IF NOT EXISTS idx_events_tombstone
            ON events(listing_id, is_tombstoned);
        """),

        Migration(version: 5, name: "cloudkit_sync_metadata", sql: """
        -- Every synchronised row carries when it last changed and the CloudKit
        -- change tag it was last seen with, so a merge can tell which side is
        -- newer and whether the server copy has moved on.
        ALTER TABLE properties        ADD COLUMN modified_at REAL NOT NULL DEFAULT 0;
        ALTER TABLE properties        ADD COLUMN cloud_tag TEXT NOT NULL DEFAULT '';
        ALTER TABLE platform_listings ADD COLUMN modified_at REAL NOT NULL DEFAULT 0;
        ALTER TABLE platform_listings ADD COLUMN cloud_tag TEXT NOT NULL DEFAULT '';
        ALTER TABLE events            ADD COLUMN modified_at REAL NOT NULL DEFAULT 0;
        ALTER TABLE events            ADD COLUMN cloud_tag TEXT NOT NULL DEFAULT '';
        ALTER TABLE classifications   ADD COLUMN modified_at REAL NOT NULL DEFAULT 0;
        ALTER TABLE classifications   ADD COLUMN cloud_tag TEXT NOT NULL DEFAULT '';
        -- Which device made a decision, used only to break an exact timestamp
        -- tie so that two devices reach the same answer independently.
        ALTER TABLE classifications   ADD COLUMN device_id TEXT NOT NULL DEFAULT '';

        CREATE TABLE sync_state (
            zone_name     TEXT PRIMARY KEY,
            change_token  BLOB,
            last_sync_at  REAL,
            last_error    TEXT
        );

        -- When two devices disagree about what a block is, the merge takes the
        -- safe option and records the disagreement here rather than silently
        -- picking a winner the owner never sees.
        CREATE TABLE sync_conflicts (
            event_key     TEXT PRIMARY KEY,
            local_kind    TEXT NOT NULL,
            remote_kind   TEXT NOT NULL,
            resolved_kind TEXT NOT NULL,
            detected_at   REAL NOT NULL,
            resolved      INTEGER NOT NULL DEFAULT 0
        );
        """),

        Migration(version: 4, name: "secure_feed_urls", sql: """
        -- A platform iCal export URL is a bearer credential: whoever holds it
        -- can read the listing's whole booking calendar. It therefore moves out
        -- of this file and into the Keychain, leaving only a reference behind.
        ALTER TABLE platform_listings
            ADD COLUMN url_storage TEXT NOT NULL DEFAULT 'database';
        ALTER TABLE platform_listings
            ADD COLUMN credential_ref TEXT NOT NULL DEFAULT '';
        """),
    ]

    public static var latestVersion: Int {
        migrations.map(\.version).max() ?? 0
    }

    /// Brings `database` up to the newest schema version. Idempotent.
    @discardableResult
    public static func migrate(_ database: Database) throws -> [Int] {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version    INTEGER PRIMARY KEY,
            name       TEXT NOT NULL,
            applied_at REAL NOT NULL
        );
        """)

        let applied = Set(
            try database.query("SELECT version FROM schema_migrations;")
                .compactMap { $0.int("version").map(Int.init) }
        )

        var performed: [Int] = []
        for migration in migrations.sorted(by: { $0.version < $1.version })
        where !applied.contains(migration.version) {
            do {
                try database.transaction {
                    try database.execute(migration.sql)
                    try database.run(
                        "INSERT INTO schema_migrations (version, name, applied_at) VALUES (?, ?, ?);",
                        [.integer(Int64(migration.version)), .text(migration.name), SQLValue(Date())]
                    )
                }
                performed.append(migration.version)
            } catch {
                throw SQLiteError.migrationFailed(
                    version: migration.version,
                    name: migration.name,
                    message: String(describing: error)
                )
            }
        }
        return performed
    }

    public static func currentVersion(_ database: Database) throws -> Int {
        let rows = try database.query(
            "SELECT COALESCE(MAX(version), 0) AS v FROM schema_migrations;"
        )
        return rows.first?.intValue("v") ?? 0
    }
}
