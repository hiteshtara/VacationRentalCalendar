import Foundation

/// What one platform feed is actually telling you — and, more usefully, what it
/// is not.
public struct FeedDiagnostic: Identifiable, Sendable {
    public var listingID: Int64
    public var platform: RentalPlatform
    public var listingLabel: String
    public var totalEvents: Int
    /// Events carrying something that positively identifies a booking.
    public var identifiableReservations: Int
    public var awaitingDecision: Int
    public var nightsAwaitingDecision: Int
    public var lastSyncAt: Date?

    public var id: Int64 { listingID }

    /// True when the feed carried nothing at all that could distinguish a
    /// booking from a block.
    public var cannotIdentifyReservations: Bool {
        totalEvents > 0 && identifiableReservations == 0
    }

    /// Plain-language warning, or nil when the feed is informative enough.
    ///
    /// Worth saying out loud because the silence is the dangerous part: a feed
    /// of identical "not available" entries looks like a working import right
    /// up until something propagates one of them.
    public var warning: String? {
        guard cannotIdentifyReservations else { return nil }
        let entries = "\(totalEvents) " + (totalEvents == 1 ? "entry" : "entries")
        switch platform {
        case .airbnb:
            return "Airbnb sent \(entries) for this listing and not one of them says whether it "
                + "is a booking, a block you made, or dates Airbnb took back after a "
                + "cancellation. They all read the same. Nothing here can be shared with "
                + "another platform until you say what it is."
        case .vrbo:
            return "Vrbo sent \(entries) for this listing, all labelled only \"Blocked\", with "
                + "nothing to separate a booking from dates you are holding. Nothing here is "
                + "shared until you decide."
        case .bookingCom:
            return "Booking.com sent \(entries) for this listing. Its export labels bookings and "
                + "owner blocks identically, so none of these can be identified automatically."
        case .other:
            return "This feed sent \(entries), none carrying anything that identifies a booking."
        }
    }

    public var summaryLine: String {
        guard totalEvents > 0 else { return "Nothing imported yet" }
        var parts = ["\(totalEvents) imported"]
        if identifiableReservations > 0 {
            parts.append("\(identifiableReservations) identifiable as bookings")
        }
        if awaitingDecision > 0 { parts.append("\(awaitingDecision) awaiting your decision") }
        return parts.joined(separator: ", ")
    }
}

public enum FeedDiagnostics {

    /// Whether a stored event carries positive evidence of a real booking.
    ///
    /// Mirrors the classifier's rule rather than re-deriving it: a description
    /// with booking-specific data, or a summary the platform reserves for
    /// bookings. Absence is never treated as evidence of anything.
    public static func identifiesReservation(
        summary: String, details: String, platform: RentalPlatform
    ) -> Bool {
        let haystack = (summary + "\n" + details).lowercased()
        if haystack.contains("reservation url")
            || haystack.contains("/reservations/details")
            || haystack.contains("confirmation code")
            || haystack.contains("phone number")
            || haystack.contains("last 4 digits")
            || haystack.contains("guest name") {
            return true
        }
        // Airbnb and Vrbo use "Reserved" only for real bookings.
        if platform == .airbnb || platform == .vrbo {
            return summary.range(of: #"^\s*reserved\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return false
    }

    public static func diagnose(
        listing: PlatformListing, events: [ClassifiedEvent]
    ) -> FeedDiagnostic {
        let mine = events.filter { $0.event.listingID == listing.id && $0.event.isActive }
        let identifiable = mine.filter {
            identifiesReservation(
                summary: $0.event.summary, details: $0.event.details, platform: $0.event.platform
            )
        }
        let pending = mine.filter { $0.classification.needsReview }
        return FeedDiagnostic(
            listingID: listing.id ?? 0,
            platform: listing.platform,
            listingLabel: listing.label,
            totalEvents: mine.count,
            identifiableReservations: identifiable.count,
            awaitingDecision: pending.count,
            nightsAwaitingDecision: pending.reduce(0) { $0 + $1.event.nights },
            lastSyncAt: listing.lastSyncAt
        )
    }

    public static func diagnoseAll(
        listings: [PlatformListing], events: [ClassifiedEvent]
    ) -> [FeedDiagnostic] {
        listings.map { diagnose(listing: $0, events: events) }
    }
}
