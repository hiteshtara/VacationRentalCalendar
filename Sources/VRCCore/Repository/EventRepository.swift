import Foundation

/// What an upsert did, so the import service can report accurate counts and so
/// test 7 (re-import makes no duplicates) and test 8 (edits update in place)
/// have something concrete to assert on.
public enum UpsertResult: String, Sendable {
    case inserted
    case updated
    case unchanged
}

public struct EventRepository: Sendable {
    let database: DataStore
    public init(database: DataStore) { self.database = database }

    /// Explicit column list rather than `SELECT *`.
    ///
    /// The Postgres schema adds generated `stay daterange` and
    /// `last_seen_ts timestamptz` columns for the exclusion constraints. The
    /// RDS Data API refuses to return a `daterange` in a result set (HTTP 400),
    /// so `SELECT *` breaks over the Data API even though it is fine on SQLite.
    /// Naming the base columns keeps both backends identical. Found by B5.
    static let columns = "id, listing_id, event_key, uid, recurrence_id, platform, summary, details, location, check_in, check_out, is_all_day, feed_status, sequence, last_modified, content_hash, first_seen_at, last_seen_at, is_tombstoned, has_unsupported_recurrence"

    private func decode(_ row: Row) -> CalendarEvent {
        CalendarEvent(
            id: row.int("id"),
            listingID: row.int("listing_id") ?? 0,
            eventKey: row.stringValue("event_key"),
            uid: row.stringValue("uid"),
            recurrenceID: row.string("recurrence_id"),
            platform: RentalPlatform(rawValue: row.stringValue("platform")) ?? .other,
            summary: row.stringValue("summary"),
            details: row.stringValue("details"),
            location: row.stringValue("location"),
            checkIn: row.dateValue("check_in"),
            checkOut: row.dateValue("check_out"),
            isAllDay: row.bool("is_all_day", default: true),
            feedStatus: FeedEventStatus(rawValue: row.stringValue("feed_status")) ?? .confirmed,
            sequence: row.intValue("sequence"),
            lastModified: row.date("last_modified"),
            contentHash: row.stringValue("content_hash"),
            firstSeenAt: row.dateValue("first_seen_at"),
            lastSeenAt: row.dateValue("last_seen_at"),
            isTombstoned: row.bool("is_tombstoned"),
            hasUnsupportedRecurrence: row.bool("has_unsupported_recurrence")
        )
    }

    /// Inserts a new event or updates the existing row with the same
    /// `event_key`. Identity is the stable key, never the row id, which is what
    /// makes re-importing a feed idempotent.
    @discardableResult
    public func upsert(_ event: CalendarEvent, seenAt: Date = Date()) throws -> UpsertResult {
        if let existing = try find(eventKey: event.eventKey) {
            let unchanged = existing.contentHash == event.contentHash
                && existing.isTombstoned == event.isTombstoned
            try database.run("""
                UPDATE events
                SET listing_id = ?, uid = ?, recurrence_id = ?, platform = ?,
                    summary = ?, details = ?, location = ?, check_in = ?, check_out = ?,
                    is_all_day = ?, feed_status = ?, sequence = ?, last_modified = ?,
                    content_hash = ?, last_seen_at = ?, is_tombstoned = ?,
                    has_unsupported_recurrence = ?
                WHERE event_key = ?;
                """, [
                    .integer(event.listingID), .text(event.uid),
                    SQLValue(event.recurrenceID), .text(event.platform.rawValue),
                    .text(event.summary), .text(event.details), .text(event.location),
                    SQLValue(event.checkIn), SQLValue(event.checkOut),
                    SQLValue(event.isAllDay), .text(event.feedStatus.rawValue),
                    .integer(Int64(event.sequence)), SQLValue(event.lastModified),
                    .text(event.contentHash), SQLValue(seenAt),
                    SQLValue(event.isTombstoned), SQLValue(event.hasUnsupportedRecurrence),
                    .text(event.eventKey),
                ])
            return unchanged ? .unchanged : .updated
        }

        try database.run("""
            INSERT INTO events
                (listing_id, event_key, uid, recurrence_id, platform, summary, details,
                 location, check_in, check_out, is_all_day, feed_status, sequence,
                 last_modified, content_hash, first_seen_at, last_seen_at,
                 is_tombstoned, has_unsupported_recurrence)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .integer(event.listingID), .text(event.eventKey), .text(event.uid),
                SQLValue(event.recurrenceID), .text(event.platform.rawValue),
                .text(event.summary), .text(event.details), .text(event.location),
                SQLValue(event.checkIn), SQLValue(event.checkOut),
                SQLValue(event.isAllDay), .text(event.feedStatus.rawValue),
                .integer(Int64(event.sequence)), SQLValue(event.lastModified),
                .text(event.contentHash), SQLValue(seenAt), SQLValue(seenAt),
                SQLValue(event.isTombstoned), SQLValue(event.hasUnsupportedRecurrence),
            ])
        return .inserted
    }

    public func find(eventKey: String) throws -> CalendarEvent? {
        try database.queryOne("SELECT \(Self.columns) FROM events WHERE event_key = ?;", [.text(eventKey)])
            .map(decode)
    }

    /// Marks events that are no longer present in a feed. They are kept so that
    /// history and the owner's decisions survive.
    @discardableResult
    public func tombstoneMissing(
        listingID: Int64,
        keysStillPresent: Set<String>,
        at date: Date = Date()
    ) throws -> Int {
        let existing = try forListing(listingID, includeTombstoned: false)
        var count = 0
        for event in existing where !keysStillPresent.contains(event.eventKey) {
            try database.run("""
                UPDATE events SET is_tombstoned = 1, last_seen_at = last_seen_at
                WHERE event_key = ?;
                """, [.text(event.eventKey)])
            count += 1
        }
        return count
    }

    public func forListing(_ listingID: Int64, includeTombstoned: Bool = false) throws -> [CalendarEvent] {
        let clause = includeTombstoned ? "" : "AND is_tombstoned = 0"
        return try database.query("""
            SELECT \(Self.columns) FROM events WHERE listing_id = ? \(clause) ORDER BY check_in;
            """, [.integer(listingID)]).map(decode)
    }

    public func allActive() throws -> [CalendarEvent] {
        try database.query("""
            SELECT \(Self.columns) FROM events
            WHERE is_tombstoned = 0 AND feed_status != 'cancelled'
            ORDER BY check_in;
            """).map(decode)
    }

    public func all(includeTombstoned: Bool = true) throws -> [CalendarEvent] {
        let clause = includeTombstoned ? "" : "WHERE is_tombstoned = 0"
        return try database.query("SELECT \(Self.columns) FROM events \(clause) ORDER BY check_in;")
            .map(decode)
    }

    /// Half-open overlap against `[start, end)`.
    public func inRange(start: Date, end: Date, includeTombstoned: Bool = false) throws -> [CalendarEvent] {
        let clause = includeTombstoned ? "" : "AND is_tombstoned = 0"
        return try database.query("""
            SELECT \(Self.columns) FROM events
            WHERE check_in < ? AND check_out > ? \(clause)
            ORDER BY check_in;
            """, [SQLValue(end), SQLValue(start)]).map(decode)
    }

    public func count(includeTombstoned: Bool = true) throws -> Int {
        let clause = includeTombstoned ? "" : "WHERE is_tombstoned = 0"
        return try database.scalarInt("SELECT COUNT(*) FROM events \(clause);")
    }

    public func countForListing(_ listingID: Int64) throws -> Int {
        try database.scalarInt(
            "SELECT COUNT(*) FROM events WHERE listing_id = ? AND is_tombstoned = 0;",
            [.integer(listingID)]
        )
    }

    public func deleteForListing(_ listingID: Int64) throws {
        try database.run("DELETE FROM events WHERE listing_id = ?;", [.integer(listingID)])
    }
}
