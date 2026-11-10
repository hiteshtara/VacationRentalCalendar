import Foundation

/// How sure we are that a "confirmed reservation" really is one.
///
/// This distinction exists because of rule R8: a classification the owner made
/// records their belief, not the platform's confirmation. Two owner-asserted
/// reservations overlapping is worth knowing about, but calling it a double
/// booking would overstate what the app actually knows.
public enum ReservationVerification: String, Sendable, Comparable {
    /// The platform supplied booking-specific evidence — a reservation link, a
    /// confirmation code, guest contact details, or a label it uses only for
    /// bookings.
    case platformEvidenced = "platform_evidenced"
    /// Classified as a reservation by the owner, with nothing from the platform
    /// to corroborate it.
    case ownerAsserted = "owner_asserted"

    private var rank: Int { self == .platformEvidenced ? 1 : 0 }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }

    public var label: String {
        self == .platformEvidenced ? "Verified by the platform" : "Your classification"
    }

    public static func of(_ item: ClassifiedEvent) -> ReservationVerification {
        FeedDiagnostics.identifiesReservation(
            summary: item.event.summary,
            details: item.event.details,
            platform: item.event.platform
        ) ? .platformEvidenced : .ownerAsserted
    }
}

/// The three categories, in priority order.
public enum ConflictCategory: String, CaseIterable, Sendable, Identifiable {
    /// Two independently verified reservations on one unit. Money at stake.
    case bookingConflict = "booking_conflict"
    /// A reservation overlap where at least one side is only the owner's
    /// classification, so the app cannot call it verified.
    case unverifiedBookingConflict = "unverified_booking_conflict"
    /// Overlapping blocks of any kind. Normal, and usually harmless.
    case calendarOverlap = "calendar_overlap"
    /// Platforms disagree about a date, or one of them cannot be seen.
    case availabilityDiscrepancy = "availability_discrepancy"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bookingConflict: return "Booking conflicts"
        case .unverifiedBookingConflict: return "Possible booking conflicts"
        case .calendarOverlap: return "Calendar overlaps"
        case .availabilityDiscrepancy: return "Availability differences"
        }
    }

    public var singular: String {
        switch self {
        case .bookingConflict: return "Booking conflict"
        case .unverifiedBookingConflict: return "Possible booking conflict"
        case .calendarOverlap: return "Calendar overlap"
        case .availabilityDiscrepancy: return "Availability difference"
        }
    }

    public var explanation: String {
        switch self {
        case .bookingConflict:
            return "Two reservations the platforms themselves confirmed cover the same nights in "
                + "the same unit. Someone is going to arrive and find it occupied."
        case .unverifiedBookingConflict:
            return "Reservations overlap, but at least one is a classification you made rather "
                + "than something the platform confirmed. Worth checking on the platform before "
                + "acting."
        case .calendarOverlap:
            return "Unavailable periods overlap. Stacked or duplicated blocks are normal and do "
                + "not mean anyone is double booked."
        case .availabilityDiscrepancy:
            return "A date reads differently on different platforms, or one platform cannot be "
                + "seen at all."
        }
    }

    /// Only the first demands immediate attention.
    public var isUrgent: Bool { self == .bookingConflict }

    public var severitySymbol: String {
        switch self {
        case .bookingConflict: return "exclamationmark.octagon.fill"
        case .unverifiedBookingConflict: return "exclamationmark.triangle.fill"
        case .calendarOverlap: return "rectangle.on.rectangle"
        case .availabilityDiscrepancy: return "questionmark.circle"
        }
    }
}

/// One finding.
public struct ConflictFinding: Identifiable, Sendable {
    public var category: ConflictCategory
    public var propertyID: Int64
    public var propertyName: String
    public var overlapStart: Date
    public var overlapEnd: Date
    public var sideA: ConflictSide
    public var sideB: ConflictSide
    public var verificationA: ReservationVerification?
    public var verificationB: ReservationVerification?
    public var detail: String
    public var acknowledged: Bool

    /// Order-independent, so acknowledgement survives a reordering.
    public var id: String {
        let keys = [sideA.eventKey, sideB.eventKey].sorted()
        return "\(category.rawValue)|\(keys[0])|\(keys[1])"
    }

    public var nights: Int { max(1, DayMath.daysBetween(overlapStart, overlapEnd)) }

    public var dateRangeDescription: String {
        "\(DayMath.mediumString(overlapStart)) – \(DayMath.mediumString(overlapEnd))"
    }
}

/// A single date, seen from every platform at once.
public struct AvailabilityDifference: Identifiable, Sendable {
    public var day: Date
    public var propertyID: Int64
    public var statuses: [RentalPlatform: PlatformDayStatus]

    public var id: String { "\(propertyID)-\(DayMath.icalDateString(day))" }

    public var knownPlatforms: [RentalPlatform] {
        statuses.filter { $0.value != .unknown }.keys.sorted { $0.rawValue < $1.rawValue }
    }
    public var unknownPlatforms: [RentalPlatform] {
        statuses.filter { $0.value == .unknown }.keys.sorted { $0.rawValue < $1.rawValue }
    }

    /// True when platforms that can be seen do not agree.
    public var platformsDisagree: Bool {
        let seen = Set(statuses.values.filter { $0 != .unknown })
        return seen.count > 1
    }

    public var hasUnknown: Bool { statuses.values.contains(.unknown) }

    public var summary: String {
        statuses
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.shortTag) \($0.value.shortLabel)" }
            .joined(separator: " · ")
    }
}

/// Produces the three categories.
///
/// The governing restraint: **an overlap of blocks is never a double booking.**
/// Reporting one as such trains the owner to ignore the warnings, which costs
/// more than the warning saves.
public struct ConflictAnalyzer: Sendable {
    public init() {}

    public func analyse(
        events: [ClassifiedEvent],
        listings: [PlatformListing] = [],
        acknowledgedIDs: Set<String> = [],
        now: Date = Date()
    ) -> [ConflictFinding] {
        var findings: [ConflictFinding] = []
        let active = events.filter { $0.event.isActive }

        var byProperty: [Int64: [ClassifiedEvent]] = [:]
        for item in active { byProperty[item.propertyID, default: []].append(item) }

        for (propertyID, group) in byProperty {
            let sorted = group.sorted { $0.event.checkIn < $1.event.checkIn }
            for i in sorted.indices {
                for j in sorted.index(after: i)..<sorted.endIndex {
                    let a = sorted[i], b = sorted[j]
                    if b.event.checkIn >= a.event.checkOut { break }
                    guard let overlap = a.event.overlap(with: b.event) else { continue }
                    // Two rows for one UID on one listing is a feed artefact.
                    if a.event.uid == b.event.uid, a.event.listingID == b.event.listingID {
                        continue
                    }

                    let aIsReservation = isConfirmedReservation(a)
                    let bIsReservation = isConfirmedReservation(b)

                    let category: ConflictCategory
                    var verificationA: ReservationVerification?
                    var verificationB: ReservationVerification?
                    var detail: String

                    if aIsReservation && bIsReservation {
                        let va = ReservationVerification.of(a)
                        let vb = ReservationVerification.of(b)
                        verificationA = va
                        verificationB = vb
                        if va == .platformEvidenced && vb == .platformEvidenced {
                            category = .bookingConflict
                            detail = "Both platforms supplied booking details for these nights."
                        } else {
                            category = .unverifiedBookingConflict
                            let unverified = [
                                va == .ownerAsserted ? a.event.platform.displayName : nil,
                                vb == .ownerAsserted ? b.event.platform.displayName : nil,
                            ].compactMap { $0 }.joined(separator: " and ")
                            detail = "\(unverified) \(unverified.contains(" and ") ? "are" : "is") "
                                + "classified as booked by you, not confirmed by the platform. "
                                + "Check there before treating this as a double booking."
                        }
                    } else {
                        category = .calendarOverlap
                        detail = "\(describe(a)) overlaps \(describe(b)). Overlapping blocks are "
                            + "normal and do not mean anyone is double booked."
                    }

                    findings.append(ConflictFinding(
                        category: category,
                        propertyID: propertyID,
                        propertyName: a.propertyName,
                        overlapStart: overlap.start,
                        overlapEnd: overlap.end,
                        sideA: side(a), sideB: side(b),
                        verificationA: verificationA, verificationB: verificationB,
                        detail: detail,
                        acknowledged: false
                    ))
                }
            }
        }

        return findings
            .map { finding in
                var updated = finding
                updated.acknowledged = acknowledgedIDs.contains(finding.id)
                    // Honour acknowledgements recorded under the older id form.
                    || acknowledgedIDs.contains(legacyID(finding))
                return updated
            }
            .sorted { lhs, rhs in
                let order = ConflictCategory.allCases
                let li = order.firstIndex(of: lhs.category) ?? 99
                let ri = order.firstIndex(of: rhs.category) ?? 99
                if li != ri { return li < ri }
                return lhs.overlapStart < rhs.overlapStart
            }
    }

    /// The identifier the previous conflict model used, so acknowledgement
    /// history recorded before this change is not lost.
    private func legacyID(_ finding: ConflictFinding) -> String {
        let keys = [finding.sideA.eventKey, finding.sideB.eventKey].sorted()
        return "\(keys[0])|\(keys[1])"
    }

    public func findings(
        _ category: ConflictCategory, in findings: [ConflictFinding]
    ) -> [ConflictFinding] {
        findings.filter { $0.category == category }
    }

    /// A reservation only counts if it is classified as one and settled.
    private func isConfirmedReservation(_ item: ClassifiedEvent) -> Bool {
        item.classification.kind == .confirmedReservation && !item.classification.needsReview
    }

    private func describe(_ item: ClassifiedEvent) -> String {
        "\(item.event.platform.displayName) "
            + "\(item.displayStatus.label.lowercased())"
    }

    private func side(_ item: ClassifiedEvent) -> ConflictSide {
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
