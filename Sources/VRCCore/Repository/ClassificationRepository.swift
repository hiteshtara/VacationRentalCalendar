import Foundation

public struct ClassificationRepository: Sendable {
    let database: DataStore
    public init(database: DataStore) { self.database = database }

    private func decode(_ row: Row) -> EventClassification {
        EventClassification(
            eventKey: row.stringValue("event_key"),
            kind: BlockKind(rawValue: row.stringValue("kind")) ?? .unknownUnavailable,
            confidence: ClassificationConfidence(rawValue: row.stringValue("confidence")) ?? .low,
            source: ClassificationSource(rawValue: row.stringValue("source")) ?? .automatic,
            needsReview: row.bool("needs_review", default: true),
            rationale: row.stringValue("rationale"),
            note: row.stringValue("note"),
            exportApproved: row.bool("export_approved"),
            exportSuppressed: row.bool("export_suppressed"),
            decidedAt: row.dateValue("decided_at")
        )
    }

    public func save(_ classification: EventClassification) throws {
        try database.run("""
            INSERT INTO classifications
                (event_key, kind, confidence, source, needs_review, rationale, note,
                 export_approved, export_suppressed, decided_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(event_key) DO UPDATE SET
                kind = excluded.kind,
                confidence = excluded.confidence,
                source = excluded.source,
                needs_review = excluded.needs_review,
                rationale = excluded.rationale,
                note = excluded.note,
                export_approved = excluded.export_approved,
                export_suppressed = excluded.export_suppressed,
                decided_at = excluded.decided_at;
            """, [
                .text(classification.eventKey), .text(classification.kind.rawValue),
                .text(classification.confidence.rawValue), .text(classification.source.rawValue),
                SQLValue(classification.needsReview), .text(classification.rationale),
                .text(classification.note), SQLValue(classification.exportApproved),
                SQLValue(classification.exportSuppressed), SQLValue(classification.decidedAt),
            ])
    }

    /// Stores an automatic proposal **only** when the owner has not already
    /// decided. This is the guarantee behind test 9: a manual classification is
    /// never overwritten by a later import.
    @discardableResult
    public func saveAutomaticIfNotDecided(
        eventKey: String,
        proposal: ClassificationProposal
    ) throws -> EventClassification {
        if let existing = try find(eventKey: eventKey), existing.isLocked {
            return existing
        }
        let classification = EventClassification(eventKey: eventKey, proposal: proposal)
        try save(classification)
        return classification
    }

    public func find(eventKey: String) throws -> EventClassification? {
        try database.queryOne(
            "SELECT * FROM classifications WHERE event_key = ?;", [.text(eventKey)]
        ).map(decode)
    }

    public func all() throws -> [String: EventClassification] {
        var result: [String: EventClassification] = [:]
        for row in try database.query("SELECT * FROM classifications;") {
            let value = decode(row)
            result[value.eventKey] = value
        }
        return result
    }

    public func needsReviewKeys() throws -> Set<String> {
        Set(
            try database.query("SELECT event_key FROM classifications WHERE needs_review = 1;")
                .map { $0.stringValue("event_key") }
        )
    }

    public func count() throws -> Int {
        try database.scalarInt("SELECT COUNT(*) FROM classifications;")
    }

    public func manualCount() throws -> Int {
        try database.scalarInt("SELECT COUNT(*) FROM classifications WHERE source = 'manual';")
    }
}
