import Foundation

/// One side of a double booking.
public struct ConflictSide: Hashable, Sendable {
    public var eventKey: String
    public var platform: RentalPlatform
    public var listingLabel: String
    public var summary: String
    public var checkIn: Date
    public var checkOut: Date

    public init(
        eventKey: String,
        platform: RentalPlatform,
        listingLabel: String,
        summary: String,
        checkIn: Date,
        checkOut: Date
    ) {
        self.eventKey = eventKey
        self.platform = platform
        self.listingLabel = listingLabel
        self.summary = summary
        self.checkIn = checkIn
        self.checkOut = checkOut
    }
}

/// How serious an overlap is.
public enum ConflictSeverity: String, Codable, CaseIterable, Sendable {
    /// Two confirmed reservations on one unit. A real, money-losing problem.
    case doubleBooking
    /// Overlapping ranges where at least one side is not a confirmed booking —
    /// usually duplicated or stacked blocks. Worth seeing, not worth alarming over.
    case overlappingBlocks

    public var displayName: String {
        self == .doubleBooking ? "Double booking" : "Overlapping blocks"
    }

    public var isUrgent: Bool { self == .doubleBooking }
}

/// Two date ranges claiming the same physical unit at the same time.
public struct ReservationConflict: Identifiable, Hashable, Sendable {
    public var severity: ConflictSeverity
    public var propertyID: Int64
    public var propertyName: String
    public var overlapStart: Date
    public var overlapEnd: Date
    public var sideA: ConflictSide
    public var sideB: ConflictSide
    public var detectedAt: Date
    public var acknowledged: Bool

    /// Deterministic, order-independent id so the same conflict is not reported
    /// twice and acknowledgement survives a restart.
    public var id: String {
        let keys = [sideA.eventKey, sideB.eventKey].sorted()
        return "\(keys[0])|\(keys[1])"
    }

    public var overlapNights: Int {
        max(1, DayMath.daysBetween(overlapStart, overlapEnd))
    }

    public var platformsDescription: String {
        sideA.platform == sideB.platform
            ? sideA.platform.displayName
            : "\(sideA.platform.displayName) vs \(sideB.platform.displayName)"
    }

    public var dateRangeDescription: String {
        "\(DayMath.mediumString(overlapStart)) – \(DayMath.mediumString(overlapEnd))"
    }

    public init(
        propertyID: Int64,
        propertyName: String,
        overlapStart: Date,
        overlapEnd: Date,
        sideA: ConflictSide,
        sideB: ConflictSide,
        severity: ConflictSeverity = .doubleBooking,
        detectedAt: Date = Date(),
        acknowledged: Bool = false
    ) {
        self.severity = severity
        self.propertyID = propertyID
        self.propertyName = propertyName
        self.overlapStart = overlapStart
        self.overlapEnd = overlapEnd
        self.sideA = sideA
        self.sideB = sideB
        self.detectedAt = detectedAt
        self.acknowledged = acknowledged
    }
}
