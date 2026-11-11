import Foundation

/// How recently a feed actually told us something.
///
/// A calendar's silence is only meaningful if the feed is current. Airbnb's
/// and Vrbo's were seventeen hours old while a Booking.com reservation for
/// 11–21 December sat unprotected, so their silence about those nights meant
/// nothing — and the interface had no way to say so.
public struct FeedFreshness: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable {
        case success, failure
    }

    public let platform: RentalPlatform
    public let lastSuccess: Date?
    public let lastOutcome: Outcome?

    /// Three hours. Platforms republish on their own schedule — typically
    /// tens of minutes to a few hours — so anything older than this may
    /// simply not have heard about a booking yet.
    public static let staleAfter: TimeInterval = 3 * 3600

    public init(platform: RentalPlatform, lastSuccess: Date?, lastOutcome: Outcome?) {
        self.platform = platform
        self.lastSuccess = lastSuccess
        self.lastOutcome = lastOutcome
    }

    public func isStale(now: Date = Date()) -> Bool {
        guard let lastSuccess else { return true }
        if lastOutcome == .failure { return true }
        return now.timeIntervalSince(lastSuccess) > Self.staleAfter
    }

    public func describe(now: Date = Date()) -> String {
        guard let lastSuccess else { return "\(platform.displayName): never fetched" }
        let hours = Int(now.timeIntervalSince(lastSuccess) / 3600)
        let age = hours < 1 ? "under an hour ago" : "\(hours)h ago"
        if lastOutcome == .failure {
            return "\(platform.displayName): last fetch FAILED, newest data \(age)"
        }
        return "\(platform.displayName): fetched \(age)"
    }
}

/// What one night in the grid is entitled to claim.
public enum NightState: String, Sendable, Equatable {
    /// A bar covers it.
    case occupied
    /// Nothing covers it AND the feed is current, so it really is for sale.
    case available
    /// Nothing covers it, but the feed is stale, failed, or never ran.
    ///
    /// **Not available.** No observation is not evidence of availability, and
    /// drawing this the same as a verified free night is the claim that let a
    /// double booking look safe.
    case unknownStaleFeed

    /// Whether the interface may render this as reassuring — green, open,
    /// bookable. Only a verified free night qualifies.
    public var isReassuring: Bool { self == .available }

    public static func of(
        occupied: Bool, freshness: FeedFreshness, now: Date = Date()
    ) -> NightState {
        if occupied { return .occupied }
        return freshness.isStale(now: now) ? .unknownStaleFeed : .available
    }
}

/// Whether a reservation's nights are actually unavailable on the other
/// platforms — judged from those platforms' own feeds, never assumed.
public struct ProtectionAssessment: Sendable, Equatable {

    public enum State: Sendable, Equatable {
        /// Every night of the stay is covered by a genuine hold there.
        case covered
        /// Some or all nights are still sellable there.
        case notCovered
        /// That platform's feed is stale or failed, so neither answer is
        /// earned. Never counted as protection.
        case unverified(reason: String)
    }

    public struct DestinationStatus: Sendable, Equatable {
        public let platform: RentalPlatform
        public let state: State
    }

    public let reservation: ClassifiedEvent
    public let destinations: [DestinationStatus]

    public var isFullyProtected: Bool {
        !destinations.isEmpty && destinations.allSatisfy { $0.state == .covered }
    }

    /// Stated rather than implied, because a person looking at this screen
    /// may otherwise assume the application is handling it. It is not.
    public static let mechanismNote =
        "This app does not publish availability — outbound sync is off. Nights are "
        + "protected by blocking them on each platform manually, or by connecting the "
        + "source calendar directly in that platform's settings."

    public var headline: String {
        let notCovered = destinations.filter { $0.state == .notCovered }.map(\.platform.displayName)
        let unverified = destinations.filter {
            if case .unverified = $0.state { return true }
            return false
        }.map(\.platform.displayName)

        if !notCovered.isEmpty && !unverified.isEmpty {
            return "Not protected on \(notCovered.joined(separator: ", ")). "
                + "Unverified on \(unverified.joined(separator: ", "))."
        }
        if !notCovered.isEmpty {
            return "Not protected on \(notCovered.joined(separator: ", "))."
        }
        if !unverified.isEmpty {
            return "Unverified on \(unverified.joined(separator: ", ")) — "
                + "that feed is stale, so neither answer is earned."
        }
        return "Protected on \(destinations.map(\.platform.displayName).joined(separator: ", "))."
    }

    /// Assesses one reservation against the other platforms for its property.
    ///
    /// Coverage must be COMPLETE and must come from a genuine hold. Partial
    /// coverage leaves nights sellable, and a cancellation penalty is not a
    /// hold anyone placed — counting either would report protection that does
    /// not exist.
    public static func assess(
        reservation: ClassifiedEvent,
        others: [ClassifiedEvent],
        freshness: [FeedFreshness],
        now: Date = Date()
    ) -> ProtectionAssessment {
        let nights = Set(CalendarVisibility.occupiedNights(of: reservation.event))
        let destinations = freshness
            .map(\.platform)
            .filter { $0 != reservation.event.platform }
            .sorted { $0.displayName < $1.displayName }

        var statuses: [DestinationStatus] = []
        for platform in destinations {
            let feed = freshness.first { $0.platform == platform }
            if let feed, feed.isStale(now: now) {
                statuses.append(DestinationStatus(
                    platform: platform, state: .unverified(reason: feed.describe(now: now))))
                continue
            }
            var covered: Set<Date> = []
            for other in others
            where other.event.platform == platform
                && other.propertyID == reservation.propertyID
                && other.classification.kind.describesGenuineUnavailability {
                covered.formUnion(CalendarVisibility.occupiedNights(of: other.event))
            }
            statuses.append(DestinationStatus(
                platform: platform,
                state: nights.isSubset(of: covered) ? .covered : .notCovered))
        }
        return ProtectionAssessment(reservation: reservation, destinations: statuses)
    }
}
