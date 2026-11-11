import Foundation
import VRCCore

/// Reconciles a changed payload into the system of record.
///
/// Classification is `BlockClassifier` — the same one the Mac runs, proved to
/// produce identical results on both platforms. Nothing here re-decides what a
/// block means.
///
/// The reconciliation is deliberately conservative about *removal*. Adding an
/// observation is cheap and reversible. Withdrawing one can reopen a night, so
/// it goes through the database's guards, and a refusal is recorded as
/// something for the owner to look at rather than retried into success.
public struct ProcessHandler {
    let context: ServiceContext
    let objects: ObjectStore

    public init(context: ServiceContext, objects: ObjectStore) {
        self.context = context
        self.objects = objects
    }

    public struct Outcome: Sendable {
        public var source: String
        public var seen = 0
        public var inserted = 0
        public var updated = 0
        public var withdrawn = 0
        public var withdrawalRefused: String?
        public var classificationsPreserved = 0
        public var detail = ""
    }

    public func run(source: String, payloadKey: String, store: DataStore) throws -> Outcome {
        var outcome = Outcome(source: source)

        let payload = try objects.get(key: payloadKey)
        guard let text = String(data: payload, encoding: .utf8) else {
            throw LambdaRuntime.HandlerError(
                type: "BadPayload", message: "payload \(payloadKey) is not UTF-8 text")
        }
        let parsed = try ICalParser.parse(text)
        outcome.seen = parsed.events.count

        // An empty parse is never a reason to withdraw anything. The database
        // would refuse it anyway; refusing here means not even asking.
        guard !parsed.events.isEmpty else {
            outcome.detail = "the feed parsed to zero events — nothing was withdrawn, "
                + "because an empty feed is not evidence that dates are free"
            return outcome
        }

        let classifier = BlockClassifier()

        try store.transaction {
            guard let listing = try store.queryOne("""
                SELECT pl.id AS id, pl.channel AS channel, pl.property_id AS property_id
                  FROM platform_listings pl
                  JOIN properties p ON p.id = pl.property_id
                 WHERE pl.channel = ?
                 LIMIT 1
                """, [.text(source)]) else {
                throw LambdaRuntime.HandlerError(
                    type: "UnknownSource", message: "no listing configured for \(source)")
            }
            let listingID = listing.stringValue("id")
            let platform = RentalPlatform(rawValue: listing.stringValue("channel")) ?? .other

            var seenKeys: [String] = []

            for event in parsed.events {
                guard let checkIn = event.resolvedCheckIn,
                      let checkOut = event.resolvedCheckOut else { continue }
                let nights = max(1, DayMath.daysBetween(checkIn, checkOut))
                let key = EventKey.sha256("\(source)\u{1F}\(event.uid)\u{1F}\(event.recurrenceID ?? "")")
                seenKeys.append(key)

                let proposal = classifier.classify(
                    event: event, platform: platform, nights: nights)

                // Observation. ON CONFLICT so a re-import is a no-op, and
                // withdrawn_at is cleared because the event is present again.
                let affected = try store.run("""
                    INSERT INTO source_events
                        (listing_id, event_key, source_uid, stay, summary, raw_status,
                         first_seen_at, last_seen_at)
                    VALUES (?, ?, ?, daterange(?::date, ?::date, '[)'), ?, ?, now(), now())
                    ON CONFLICT (listing_id, event_key) DO UPDATE
                       SET stay = EXCLUDED.stay,
                           summary = EXCLUDED.summary,
                           raw_status = EXCLUDED.raw_status,
                           last_seen_at = now(),
                           withdrawn_at = NULL
                    """, [
                        .text(listingID), .text(key), .text(event.uid),
                        .text(DayMath.icalDateString(checkIn)),
                        .text(DayMath.icalDateString(checkOut)),
                        .text(event.summary), .text(event.status ?? ""),
                    ])
                if affected > 0 { outcome.updated += 1 }

                // Classification: an owner's decision is never overwritten.
                // `locked` is what protects it, and the WHERE clause means the
                // importer does not even attempt the write.
                let preserved = try store.scalarInt("""
                    SELECT count(*) FROM classifications c
                      JOIN source_events e ON e.id = c.source_event_id
                     WHERE e.listing_id = ? AND e.event_key = ? AND c.locked
                    """, [.text(listingID), .text(key)])
                if preserved > 0 {
                    outcome.classificationsPreserved += 1
                    continue
                }

                _ = try store.run("""
                    INSERT INTO classifications
                        (source_event_id, kind, needs_review, set_by, note, decided_at, locked)
                    SELECT e.id, ?::block_kind, ?, 'inferred', ?, now(), false
                      FROM source_events e
                     WHERE e.listing_id = ? AND e.event_key = ?
                    ON CONFLICT (source_event_id) DO UPDATE
                       SET kind = EXCLUDED.kind,
                           needs_review = EXCLUDED.needs_review,
                           decided_at = now()
                     WHERE NOT classifications.locked
                    """, [
                        .text(postgresKind(proposal.kind)),
                        .integer(proposal.needsReview ? 1 : 0),
                        .text(proposal.rationale),
                        .text(listingID), .text(key),
                    ])
            }

            // Withdrawal: anything live for this listing that the feed no
            // longer mentions. The guards in migration 002 decide whether this
            // is allowed; a refusal is caught and surfaced, not worked around.
            let placeholders = seenKeys.isEmpty
                ? "''" : seenKeys.map { _ in "?" }.joined(separator: ", ")
            var parameters: [SQLValue] = [.text(listingID)]
            parameters.append(contentsOf: seenKeys.map { SQLValue.text($0) })
            do {
                outcome.withdrawn = try store.run("""
                    UPDATE source_events
                       SET withdrawn_at = now()
                     WHERE listing_id = ?
                       AND withdrawn_at IS NULL
                       AND event_key NOT IN (\(placeholders))
                    """, parameters)
            } catch {
                // This is the protection working. Record it where the owner
                // will see it rather than letting the import look clean.
                outcome.withdrawalRefused =
                    (error as? LocalizedError)?.errorDescription ?? "\(error)"
                _ = try? store.run("""
                    INSERT INTO conflicts (property_id, category, stay, detail)
                    VALUES (?, 'availability_discrepancy',
                            daterange(current_date, current_date + 1, '[)'), ?)
                    """, [
                        .text(listing.stringValue("property_id")),
                        .text("an import of \(source) tried to withdraw more events than the "
                              + "safety rules allow, so nothing was withdrawn: "
                              + (outcome.withdrawalRefused ?? "")),
                    ])
            }

            _ = try store.run("""
                INSERT INTO import_runs
                    (listing_id, started_at, finished_at, outcome, events_seen, raw_object_key)
                VALUES (?, now(), now(), ?, ?, ?)
                """, [
                    .text(listingID),
                    .text(outcome.withdrawalRefused == nil ? "ok" : "partial"),
                    .integer(Int64(outcome.seen)), .text(payloadKey),
                ])
        }

        outcome.detail = outcome.withdrawalRefused == nil
            ? "reconciled \(outcome.seen) event(s)"
            : "reconciled \(outcome.seen) event(s); a withdrawal was refused by the safety rules"
        return outcome
    }

    /// `BlockKind` is spelled in camelCase in Swift and snake_case in the
    /// `block_kind` enum. Mapped explicitly rather than by string mangling, so
    /// adding a case forces a decision here instead of failing at runtime.
    public func postgresKind(_ kind: BlockKind) -> String {
        switch kind {
        case .confirmedReservation: return "confirmed_reservation"
        case .ownerBlock: return "owner_block"
        case .maintenanceBlock: return "maintenance_block"
        case .cancellationBlock: return "cancellation_block"
        case .platformRestriction: return "platform_restriction"
        case .unknownUnavailable: return "unknown_unavailable"
        }
    }
}
