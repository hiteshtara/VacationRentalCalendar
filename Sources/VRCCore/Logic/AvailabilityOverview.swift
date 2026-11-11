import Foundation

/// What one platform says about one night.
///
/// The case that earns its keep is `unknown`. If a feed is disconnected,
/// stale, or was never imported, the honest answer is that the app does not
/// know — and showing "Available" there would invite the owner to sell a night
/// that may already be booked. Absence of a block is only evidence of
/// availability when the calendar behind it is actually being read.
public enum PlatformDayStatus: String, CaseIterable, Sendable, Hashable {
    /// A reservation the platform itself confirmed.
    case confirmedBooked = "confirmed_booked"
    /// Classified as booked by the owner, not corroborated by the platform.
    case bookedUnverified = "booked_unverified"
    /// Blocked by the owner, or for maintenance.
    case ownerBlocked = "owner_blocked"
    /// The platform will not take bookings — booking window, or a restriction.
    case platformRestricted = "platform_restricted"
    /// Unavailable for a reason nobody has established yet.
    case uncertain
    /// Genuinely open, on a calendar the app can currently see.
    case available
    /// The app cannot see this platform's calendar, so it has no idea.
    case unknown

    public var label: String {
        switch self {
        case .confirmedBooked: return "Booked"
        case .bookedUnverified: return "Booked (not confirmed)"
        case .ownerBlocked: return "Blocked by you"
        case .platformRestricted: return "Booking window"
        case .uncertain: return "Unavailable, reason undecided"
        case .available: return "Available"
        case .unknown: return "Unknown"
        }
    }

    public var shortLabel: String {
        switch self {
        case .confirmedBooked: return "booked"
        case .bookedUnverified: return "booked?"
        case .ownerBlocked: return "blocked"
        case .platformRestricted: return "window"
        case .uncertain: return "unsure"
        case .available: return "open"
        case .unknown: return "unknown"
        }
    }

    /// Whether the night could be sold here. Deliberately false for `unknown`:
    /// not knowing is not the same as being free.
    public var isSellable: Bool { self == .available }

    /// Whether the app actually has information, as opposed to a gap.
    public var isEstablished: Bool { self != .unknown }

    public var explanation: String {
        switch self {
        case .confirmedBooked:
            return "The platform confirmed a reservation for this night."
        case .bookedUnverified:
            return "You classified this as booked. The platform did not supply booking details, "
                + "so it is not independently confirmed."
        case .ownerBlocked:
            return "You are holding this night."
        case .platformRestricted:
            return "The platform will not take bookings for this night, usually because it is "
                + "past the end of your booking window there."
        case .uncertain:
            return "The platform says this night is unavailable but not why. Until you decide, "
                + "it is not shared anywhere and not treated as sellable."
        case .available:
            return "Open for booking, on a calendar that was read recently."
        case .unknown:
            return "This platform's calendar cannot be read at the moment, so its availability "
                + "is unknown. It is not shown as available, because it may not be."
        }
    }
}

/// One night across every platform for one property.
public struct DayAvailability: Identifiable, Sendable {
    public var day: Date
    public var propertyID: Int64
    public var statuses: [RentalPlatform: PlatformDayStatus]
    /// Events covering this night, for the inspector.
    public var eventKeys: [RentalPlatform: String]

    public var id: String { "\(propertyID)-\(DayMath.icalDateString(day))" }

    public func status(for platform: RentalPlatform) -> PlatformDayStatus {
        statuses[platform] ?? .unknown
    }

    /// The single most important thing about the night, for a calendar cell.
    public var headline: PlatformDayStatus {
        let order: [PlatformDayStatus] = [
            .confirmedBooked, .bookedUnverified, .ownerBlocked,
            .uncertain, .platformRestricted, .unknown, .available,
        ]
        for candidate in order where statuses.values.contains(candidate) { return candidate }
        return .unknown
    }

    public var isFullyAvailable: Bool {
        !statuses.isEmpty && statuses.values.allSatisfy { $0 == .available }
    }

    public var hasUnknown: Bool { statuses.values.contains(.unknown) }

    /// Platforms that can be seen disagree with each other.
    public var isDiscrepant: Bool {
        let established = Set(statuses.values.filter(\.isEstablished))
        return established.count > 1
    }
}

/// Builds the per-platform availability picture.
public struct AvailabilityOverview: Sendable {

    /// Beyond this a feed is too old for its silence to mean "available".
    public static let freshnessWindow: TimeInterval = 24 * 3_600

    public init() {}

    /// Whether a platform's calendar can currently be trusted to say a night
    /// is free. A disconnected or never-imported feed cannot.
    public func isReadable(_ listing: PlatformListing, now: Date) -> Bool {
        guard !listing.connectionState.isDisconnected else { return false }
        guard listing.connectionState != .notConfigured else { return false }
        guard let last = listing.lastSyncAt else { return false }
        return now.timeIntervalSince(last) <= Self.freshnessWindow
    }

    public func day(
        _ date: Date,
        propertyID: Int64,
        events: [ClassifiedEvent],
        listings: [PlatformListing],
        now: Date = Date()
    ) -> DayAvailability {
        let target = DayMath.utcMidnight(date)
        var statuses: [RentalPlatform: PlatformDayStatus] = [:]
        var keys: [RentalPlatform: String] = [:]

        for listing in listings where listing.propertyID == propertyID {
            let platform = listing.platform
            let covering = events.first {
                $0.propertyID == propertyID
                    && $0.event.platform == platform
                    && $0.event.isActive
                    && $0.event.covers(day: target)
            }

            if let covering {
                statuses[platform] = status(for: covering)
                keys[platform] = covering.event.eventKey
            } else if isReadable(listing, now: now) {
                // No event, and the calendar is current — genuinely open.
                statuses[platform] = .available
            } else {
                // No event, but the calendar cannot be trusted. Not "available".
                statuses[platform] = .unknown
            }
        }

        return DayAvailability(day: target, propertyID: propertyID, statuses: statuses, eventKeys: keys)
    }

    public func range(
        from start: Date,
        days: Int,
        propertyID: Int64,
        events: [ClassifiedEvent],
        listings: [PlatformListing],
        now: Date = Date()
    ) -> [DayAvailability] {
        (0..<days).map { offset in
            day(
                DayMath.adding(days: offset, to: start),
                propertyID: propertyID, events: events, listings: listings, now: now
            )
        }
    }

    /// Dates where platforms disagree or one cannot be seen.
    public func differences(
        from start: Date,
        days: Int,
        propertyID: Int64,
        events: [ClassifiedEvent],
        listings: [PlatformListing],
        now: Date = Date()
    ) -> [AvailabilityDifference] {
        range(
            from: start, days: days, propertyID: propertyID,
            events: events, listings: listings, now: now
        )
        .filter { $0.isDiscrepant || $0.hasUnknown }
        .map {
            AvailabilityDifference(day: $0.day, propertyID: $0.propertyID, statuses: $0.statuses)
        }
    }

    private func status(for item: ClassifiedEvent) -> PlatformDayStatus {
        if item.classification.needsReview { return .uncertain }
        switch item.classification.kind {
        case .confirmedReservation:
            return ReservationVerification.of(item) == .platformEvidenced
                ? .confirmedBooked : .bookedUnverified
        case .ownerBlock, .maintenanceBlock:
            return .ownerBlocked
        case .platformRestriction:
            return .platformRestricted
        case .cancellationBlock, .unknownUnavailable:
            return .uncertain
        }
    }
}
