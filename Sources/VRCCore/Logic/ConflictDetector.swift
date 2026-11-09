import Foundation

/// Finds date ranges that collide on the same physical unit.
///
/// Two deliberate choices:
///
/// - Overlap is half-open, `[checkIn, checkOut)`. A guest leaving on the 14th
///   and another arriving on the 14th is an ordinary turnover, and reporting it
///   as a double booking would train the owner to ignore the warnings.
/// - Only two *confirmed reservations* are a double booking. Overlapping blocks
///   are reported separately, because stacked blocks are normal and harmless.
public struct ConflictDetector: Sendable {
    public init() {}

    public func detect(
        in events: [ClassifiedEvent],
        acknowledgedIDs: Set<String> = [],
        detectedAt: Date = Date()
    ) -> [ReservationConflict] {
        let active = events.filter { $0.event.isActive }
        var byProperty: [Int64: [ClassifiedEvent]] = [:]
        for item in active {
            byProperty[item.propertyID, default: []].append(item)
        }

        var conflicts: [ReservationConflict] = []

        for (propertyID, group) in byProperty {
            let sorted = group.sorted { $0.event.checkIn < $1.event.checkIn }
            for i in sorted.indices {
                for j in sorted.index(after: i)..<sorted.endIndex {
                    let a = sorted[i]
                    let b = sorted[j]
                    // Sorted by start, so once b starts at or after a ends,
                    // nothing further can overlap a.
                    if b.event.checkIn >= a.event.checkOut { break }
                    guard let overlap = a.event.overlap(with: b.event) else { continue }

                    let bothConfirmed = a.classification.kind == .confirmedReservation
                        && b.classification.kind == .confirmedReservation
                    // Two rows for the same UID on the same listing is a feed
                    // artefact, not a collision.
                    if a.event.uid == b.event.uid, a.event.listingID == b.event.listingID {
                        continue
                    }

                    let conflict = ReservationConflict(
                        propertyID: propertyID,
                        propertyName: a.propertyName,
                        overlapStart: overlap.start,
                        overlapEnd: overlap.end,
                        sideA: side(from: a),
                        sideB: side(from: b),
                        severity: bothConfirmed ? .doubleBooking : .overlappingBlocks,
                        detectedAt: detectedAt
                    )
                    conflicts.append(conflict)
                }
            }
        }

        return conflicts
            .map { conflict -> ReservationConflict in
                var updated = conflict
                updated.acknowledged = acknowledgedIDs.contains(conflict.id)
                return updated
            }
            .sorted { lhs, rhs in
                if lhs.severity.isUrgent != rhs.severity.isUrgent { return lhs.severity.isUrgent }
                return lhs.overlapStart < rhs.overlapStart
            }
    }

    /// Only the double bookings — what the notification and the red badge use.
    public func doubleBookings(in events: [ClassifiedEvent], acknowledgedIDs: Set<String> = []) -> [ReservationConflict] {
        detect(in: events, acknowledgedIDs: acknowledgedIDs)
            .filter { $0.severity == .doubleBooking }
    }

    private func side(from item: ClassifiedEvent) -> ConflictSide {
        ConflictSide(
            eventKey: item.event.eventKey,
            platform: item.event.platform,
            listingLabel: item.listingLabel,
            summary: item.event.summary.isEmpty ? "(no title)" : item.event.summary,
            checkIn: item.event.checkIn,
            checkOut: item.event.checkOut
        )
    }
}
