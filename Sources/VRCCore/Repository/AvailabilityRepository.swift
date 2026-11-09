import Foundation

public struct AvailabilityRepository: Sendable {
    let database: DataStore
    public init(database: DataStore) { self.database = database }

    private func decode(_ row: Row) -> AvailabilityDecision {
        AvailabilityDecision(
            id: row.int("id"),
            propertyID: row.int("property_id") ?? 0,
            destination: RentalPlatform(rawValue: row.stringValue("destination")) ?? .other,
            action: AvailabilityAction(rawValue: row.stringValue("action")) ?? .leaveUnchanged,
            startDay: row.dateValue("start_day"),
            endDay: row.dateValue("end_day"),
            status: AvailabilityStatus(rawValue: row.stringValue("status")) ?? .unknown,
            reason: row.stringValue("reason"),
            publicationUID: row.stringValue("publication_uid"),
            createdAt: row.dateValue("created_at"),
            updatedAt: row.dateValue("updated_at"),
            validatedAt: row.date("validated_at"),
            approvedAt: row.date("approved_at"),
            approvedBy: row.string("approved_by"),
            publishedAt: row.date("published_at"),
            refreshExpectedBy: row.date("refresh_expected_by"),
            verifiedAt: row.date("verified_at"),
            cancelledAt: row.date("cancelled_at"),
            failureReason: row.string("failure_reason"),
            supersedesID: row.int("supersedes_id"),
            createdBy: row.stringValue("created_by")
        )
    }

    @discardableResult
    public func insert(_ decision: AvailabilityDecision) throws -> AvailabilityDecision {
        try database.run("""
            INSERT INTO availability_decisions
                (property_id, destination, action, start_day, end_day, status, reason,
                 publication_uid, created_at, updated_at, validated_at, approved_at,
                 approved_by, published_at, refresh_expected_by, verified_at, cancelled_at,
                 failure_reason, supersedes_id, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .integer(decision.propertyID), .text(decision.destination.rawValue),
                .text(decision.action.rawValue), SQLValue(decision.startDay),
                SQLValue(decision.endDay), .text(decision.status.rawValue),
                .text(decision.reason), .text(decision.publicationUID),
                SQLValue(decision.createdAt), SQLValue(decision.updatedAt),
                SQLValue(decision.validatedAt), SQLValue(decision.approvedAt),
                SQLValue(decision.approvedBy), SQLValue(decision.publishedAt),
                SQLValue(decision.refreshExpectedBy), SQLValue(decision.verifiedAt),
                SQLValue(decision.cancelledAt), SQLValue(decision.failureReason),
                SQLValue(decision.supersedesID), .text(decision.createdBy),
            ])
        var stored = decision
        stored.id = database.lastInsertRowID
        return stored
    }

    public func update(_ decision: AvailabilityDecision) throws {
        guard let id = decision.id else { return }
        try database.run("""
            UPDATE availability_decisions
            SET destination = ?, action = ?, start_day = ?, end_day = ?, status = ?,
                reason = ?, updated_at = ?, validated_at = ?, approved_at = ?, approved_by = ?,
                published_at = ?, refresh_expected_by = ?, verified_at = ?, cancelled_at = ?,
                failure_reason = ?, supersedes_id = ?
            WHERE id = ?;
            """, [
                .text(decision.destination.rawValue), .text(decision.action.rawValue),
                SQLValue(decision.startDay), SQLValue(decision.endDay),
                .text(decision.status.rawValue), .text(decision.reason), SQLValue(Date()),
                SQLValue(decision.validatedAt), SQLValue(decision.approvedAt),
                SQLValue(decision.approvedBy), SQLValue(decision.publishedAt),
                SQLValue(decision.refreshExpectedBy), SQLValue(decision.verifiedAt),
                SQLValue(decision.cancelledAt), SQLValue(decision.failureReason),
                SQLValue(decision.supersedesID), .integer(id),
            ])
    }

    public func find(id: Int64) throws -> AvailabilityDecision? {
        try database.queryOne(
            "SELECT * FROM availability_decisions WHERE id = ?;", [.integer(id)]
        ).map(decode)
    }

    public func all() throws -> [AvailabilityDecision] {
        try database.query(
            "SELECT * FROM availability_decisions ORDER BY start_day, destination;"
        ).map(decode)
    }

    public func forProperty(_ propertyID: Int64) throws -> [AvailabilityDecision] {
        try database.query("""
            SELECT * FROM availability_decisions WHERE property_id = ?
            ORDER BY start_day, destination;
            """, [.integer(propertyID)]).map(decode)
    }

    /// Decisions whose entries belong in a destination's feed right now.
    public func liveForFeed(
        propertyID: Int64, destination: RentalPlatform
    ) throws -> [AvailabilityDecision] {
        let statuses = AvailabilityStatus.allCases
            .filter(\.contributesToFeed)
            .map { "'\($0.rawValue)'" }
            .joined(separator: ", ")
        return try database.query("""
            SELECT * FROM availability_decisions
            WHERE property_id = ? AND destination = ? AND action = 'block'
              AND status IN (\(statuses))
            ORDER BY start_day;
            """, [.integer(propertyID), .text(destination.rawValue)]).map(decode)
    }

    public func pending() throws -> [AvailabilityDecision] {
        let statuses = AvailabilityStatus.allCases
            .filter(\.isPending)
            .map { "'\($0.rawValue)'" }
            .joined(separator: ", ")
        return try database.query("""
            SELECT * FROM availability_decisions WHERE status IN (\(statuses))
            ORDER BY created_at DESC;
            """).map(decode)
    }

    public func count() throws -> Int {
        try database.scalarInt("SELECT COUNT(*) FROM availability_decisions;")
    }

    /// Hard delete, used only for a draft the owner abandons before it is ever
    /// validated. Anything further along is cancelled, not removed, so the
    /// audit trail stays intact.
    public func deleteDraft(id: Int64) throws {
        try database.run(
            "DELETE FROM availability_decisions WHERE id = ? AND status = 'draft';",
            [.integer(id)]
        )
    }
}
