import Foundation

public struct SyncRunRepository: Sendable {
    let database: DataStore
    public init(database: DataStore) { self.database = database }

    private func decode(_ row: Row) -> SyncRun {
        SyncRun(
            id: row.int("id"),
            listingID: row.int("listing_id") ?? 0,
            startedAt: row.dateValue("started_at"),
            finishedAt: row.date("finished_at"),
            outcome: SyncOutcome(rawValue: row.stringValue("outcome")) ?? .success,
            httpStatus: row.int("http_status").map(Int.init),
            eventsSeen: row.intValue("events_seen"),
            eventsInserted: row.intValue("events_inserted"),
            eventsUpdated: row.intValue("events_updated"),
            eventsTombstoned: row.intValue("events_tombstoned"),
            eventsNeedingReview: row.intValue("events_needing_review"),
            errorMessage: row.string("error_message")
        )
    }

    @discardableResult
    public func record(_ run: SyncRun) throws -> SyncRun {
        try database.run("""
            INSERT INTO sync_runs
                (listing_id, started_at, finished_at, outcome, http_status, events_seen,
                 events_inserted, events_updated, events_tombstoned,
                 events_needing_review, error_message)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .integer(run.listingID), SQLValue(run.startedAt), SQLValue(run.finishedAt),
                .text(run.outcome.rawValue), SQLValue(run.httpStatus),
                .integer(Int64(run.eventsSeen)), .integer(Int64(run.eventsInserted)),
                .integer(Int64(run.eventsUpdated)), .integer(Int64(run.eventsTombstoned)),
                .integer(Int64(run.eventsNeedingReview)), SQLValue(run.errorMessage),
            ])
        var stored = run
        stored.id = database.lastInsertRowID
        return stored
    }

    public func recent(limit: Int = 50) throws -> [SyncRun] {
        try database.query(
            "SELECT * FROM sync_runs ORDER BY started_at DESC LIMIT ?;",
            [.integer(Int64(limit))]
        ).map(decode)
    }

    public func forListing(_ listingID: Int64, limit: Int = 20) throws -> [SyncRun] {
        try database.query("""
            SELECT * FROM sync_runs WHERE listing_id = ?
            ORDER BY started_at DESC LIMIT ?;
            """, [.integer(listingID), .integer(Int64(limit))]).map(decode)
    }

    public func count() throws -> Int {
        try database.scalarInt("SELECT COUNT(*) FROM sync_runs;")
    }
}
