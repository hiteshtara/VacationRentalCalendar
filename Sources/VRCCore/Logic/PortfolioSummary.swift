import Foundation

/// One property's line in the portfolio.
///
/// A rollup, not a view model: it is computed in `VRCCore` so the portfolio can
/// be asserted in tests rather than inspected on screen. The SwiftUI side
/// renders these fields and adds nothing to them.
public struct PortfolioRow: Sendable, Identifiable, Equatable {
    public var property: Property
    /// Platform connections configured for this property.
    public var listingCount: Int
    /// Connections currently importing.
    public var connectedCount: Int
    /// Connections that are revoked, unreadable, or failing — anything the
    /// owner would want to see without opening the property.
    public var troubledCount: Int
    public var activeEventCount: Int
    public var needsReviewCount: Int
    public var conflictCount: Int
    /// The next check-in on or after today, across every platform.
    public var nextArrival: Date?

    public var id: Int64 { property.id ?? 0 }

    /// Worth surfacing in the portfolio without drilling in.
    public var needsAttention: Bool {
        troubledCount > 0 || needsReviewCount > 0 || conflictCount > 0
    }

    public init(
        property: Property, listingCount: Int, connectedCount: Int, troubledCount: Int,
        activeEventCount: Int, needsReviewCount: Int, conflictCount: Int, nextArrival: Date?
    ) {
        self.property = property
        self.listingCount = listingCount
        self.connectedCount = connectedCount
        self.troubledCount = troubledCount
        self.activeEventCount = activeEventCount
        self.needsReviewCount = needsReviewCount
        self.conflictCount = conflictCount
        self.nextArrival = nextArrival
    }
}

extension RentalStore {

    /// The portfolio: one row per ACTIVE property.
    ///
    /// Archived properties are excluded deliberately — that is what archiving
    /// is for — while `properties.all()` still returns them, so history,
    /// audits and past publications stay reachable.
    ///
    /// Everything is counted per property. No figure here is derived from a
    /// global total, because a portfolio that quietly mixes two properties'
    /// numbers is worse than no portfolio.
    public func portfolio(now: Date = Date()) throws -> [PortfolioRow] {
        let active = try properties.active()
        let allListings = try listings.all()
        let events = try classifiedEvents()
        let allConflicts = try conflicts()
        let today = DayMath.utcMidnight(now)

        return active.map { property in
            let id = property.id ?? 0
            let mine = allListings.filter { $0.propertyID == id }
            let myEvents = events.filter { $0.propertyID == id && $0.event.isActive }

            return PortfolioRow(
                property: property,
                listingCount: mine.count,
                connectedCount: mine.filter { $0.connectionState == .connected }.count,
                troubledCount: mine.filter {
                    $0.connectionState == .revoked
                        || $0.connectionState == .credentialUnreadable
                        || $0.connectionState == .failing
                }.count,
                activeEventCount: myEvents.count,
                needsReviewCount: myEvents.filter { $0.classification.needsReview }.count,
                conflictCount: allConflicts.filter { $0.propertyID == id }.count,
                nextArrival: myEvents
                    .map { DayMath.utcMidnight($0.event.checkIn) }
                    .filter { $0 >= today }
                    .min()
            )
        }
    }
}
