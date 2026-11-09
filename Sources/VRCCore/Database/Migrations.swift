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

        Migration(version: 4, name: "secure_feed_urls", sql: """
        -- A platform iCal export URL is a bearer credential: whoever holds it
        -- can read the listing's whole booking calendar. It therefore moves out
        -- of this file and into the Keychain, leaving only a reference behind.
        ALTER TABLE platform_listings
            ADD COLUMN url_storage TEXT NOT NULL DEFAULT 'database';
        ALTER TABLE platform_listings
            ADD COLUMN credential_ref TEXT NOT NULL DEFAULT '';
        """),

        // Versions 5-9 are reserved for the in-flight iOS/CloudKit branch, which
        // already claims 5. Availability starts at 10 so the two can merge
        // without renumbering either one.
        Migration(version: 10, name: "availability_decisions", sql: """
        -- A property's nights are counted in its own time zone, so a decision
        -- made for "10-15 December" means the same nights wherever the owner is.
        ALTER TABLE properties ADD COLUMN time_zone TEXT NOT NULL DEFAULT 'UTC';

        -- An availability decision is the owner's intent. It is deliberately a
        -- separate table from `events`: imported source events are a record of
        -- what a platform said, and must never be edited to express something
        -- the owner wants.
        CREATE TABLE availability_decisions (
            id                    INTEGER PRIMARY KEY AUTOINCREMENT,
            property_id           INTEGER NOT NULL
                                  REFERENCES properties(id) ON DELETE CASCADE,
            destination           TEXT NOT NULL,
            action                TEXT NOT NULL,
            start_day             REAL NOT NULL,
            end_day               REAL NOT NULL,
            status                TEXT NOT NULL,
            reason                TEXT NOT NULL DEFAULT '',
            publication_uid       TEXT NOT NULL,
            created_at            REAL NOT NULL,
            updated_at            REAL NOT NULL,
            validated_at          REAL,
            approved_at           REAL,
            approved_by           TEXT,
            published_at          REAL,
            refresh_expected_by   REAL,
            verified_at           REAL,
            cancelled_at          REAL,
            failure_reason        TEXT,
            supersedes_id         INTEGER,
            created_by            TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX idx_decisions_property ON availability_decisions(property_id, destination);
        CREATE INDEX idx_decisions_range    ON availability_decisions(start_day, end_day);
        CREATE INDEX idx_decisions_status   ON availability_decisions(status);
        CREATE UNIQUE INDEX idx_decisions_uid ON availability_decisions(publication_uid);

        -- Append-only. Rows are never updated or deleted, so the history of who
        -- approved what, and when, survives any later change of mind.
        CREATE TABLE availability_audit (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            decision_id  INTEGER,
            at           REAL NOT NULL,
            actor        TEXT NOT NULL DEFAULT '',
            from_status  TEXT,
            to_status    TEXT,
            event        TEXT NOT NULL,
            detail       TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX idx_audit_decision ON availability_audit(decision_id, at);

        -- The third concept: what was actually written into a destination feed.
        -- Kept so a published entry can be traced back to the decision or source
        -- event that justified it, and so stable UIDs survive regeneration.
        CREATE TABLE feed_publications (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            destination   TEXT NOT NULL,
            property_id   INTEGER NOT NULL,
            revision      INTEGER NOT NULL,
            generated_at  REAL NOT NULL,
            entry_count   INTEGER NOT NULL DEFAULT 0,
            checksum      TEXT NOT NULL DEFAULT '',
            status        TEXT NOT NULL DEFAULT 'generated',
            published_at  REAL,
            detail        TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX idx_publications_dest
            ON feed_publications(property_id, destination, revision DESC);

        CREATE TABLE published_feed_entries (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            publication_id  INTEGER NOT NULL
                            REFERENCES feed_publications(id) ON DELETE CASCADE,
            entry_uid       TEXT NOT NULL,
            origin          TEXT NOT NULL,
            source_event_key TEXT,
            decision_id     INTEGER,
            start_day       REAL NOT NULL,
            end_day         REAL NOT NULL,
            summary         TEXT NOT NULL
        );
        CREATE INDEX idx_entries_publication ON published_feed_entries(publication_id);
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
