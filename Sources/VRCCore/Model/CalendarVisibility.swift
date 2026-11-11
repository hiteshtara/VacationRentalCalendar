import Foundation

/// How one event is drawn — and the rule that it always is.
///
/// On 2026-11-11 a confirmed Booking.com reservation for 11–21 December 2026
/// imported correctly, linked to the right property, and appeared in Needs
/// Review — while the month view drew **nothing** for those dates. On a
/// calendar, blank is indistinguishable from available, so the one thing this
/// application exists to prevent was the thing its main view implied was safe.
///
/// The cause was a filter that hid `.needsReview` and `.unknown` by default,
/// conflating two different jobs: reducing clutter, and deciding what is true.
///
/// **A filter may change emphasis. It may never remove unavailability.**
///
/// Shape borrowed from channel managers that get this right: an available
/// night is marked *affirmatively* (a price, an occupancy) rather than left
/// empty, and an unavailable one is hatched. Nothing is ambiguous by being
/// blank.
public enum CalendarEmphasis: String, Sendable, Equatable, CaseIterable {
    /// A guest is staying. The strongest treatment.
    case reservation
    /// A deliberate hold — owner or maintenance.
    case block
    /// Unavailable on a source platform, not yet classified. Hatched, so it
    /// reads as "something is here and nobody has decided what".
    case undecided
    /// An Airbnb penalty after a host cancellation. Visible, distinct, and
    /// never exported — these nights stay sellable elsewhere.
    case cancellationPenalty
    /// The far edge of a booking window. Drawn, but quietest.
    case bookingWindow

    /// Every emphasis is drawn. There is no "hidden" case, by construction:
    /// an enum with no way to express invisibility cannot be used to hide
    /// something.
    public var isDrawn: Bool { true }

    /// Whether these nights must not be treated as free.
    public var impliesUnavailable: Bool { true }

    /// Whether the dates may ever protect another platform. Mirrors
    /// `describesGenuineUnavailability` rather than restating it.
    public var mayProtectOtherPlatforms: Bool {
        switch self {
        case .reservation, .block: return true
        case .undecided, .cancellationPenalty, .bookingWindow: return false
        }
    }

    public var label: String {
        switch self {
        case .reservation: return "Reserved"
        case .block: return "Blocked"
        case .undecided: return "Unavailable — undecided"
        case .cancellationPenalty: return "Cancellation block"
        case .bookingWindow: return "Booking window"
        }
    }
}

public enum CalendarVisibility {

    /// The default for the clutter toggle.
    ///
    /// `false` — show everything. The previous default was the setting that
    /// hid risk, which is the wrong way round for a tool whose purpose is
    /// preventing double bookings: the safe-looking state must not be the one
    /// that conceals unavailable inventory.
    public static let defaultReduceClutter = false

    /// What the calendar draws.
    ///
    /// Returns every event it is given, always. The parameter is kept because
    /// callers have a clutter setting, and keeping it here — visibly ignored
    /// for membership — is the point: there is no argument anyone can pass
    /// that drops an event. Emphasis is where the setting belongs.
    public static func visible(
        _ items: [ClassifiedEvent], reduceClutter: Bool
    ) -> [ClassifiedEvent] {
        _ = reduceClutter
        return items
    }

    /// How to draw one event.
    ///
    /// `needsReview` no longer swallows the kind. It did before, which is why
    /// an undecided reservation and an undecided booking-window edge were
    /// hidden by the same rule. A reviewed-but-undecided event is `undecided`;
    /// a cancellation penalty stays a cancellation penalty whether or not
    /// anyone has looked at it.
    public static func emphasis(for item: ClassifiedEvent) -> CalendarEmphasis {
        switch item.classification.kind {
        case .cancellationBlock: return .cancellationPenalty
        case .platformRestriction: return .bookingWindow
        case .unknownUnavailable: return .undecided
        case .confirmedReservation:
            return item.classification.needsReview ? .undecided : .reservation
        case .ownerBlock, .maintenanceBlock:
            return item.classification.needsReview ? .undecided : .block
        }
    }

    /// One line naming the platform and the nights actually occupied.
    ///
    /// Checkout-exclusive: a stay of 11–21 December occupies the nights of the
    /// 11th to the 20th and releases the 21st, so the badge says 11–20. Saying
    /// 21 would imply a night that is for sale is taken.
    public static func badge(for item: ClassifiedEvent) -> String {
        let nights = occupiedNights(of: item.event)
        let emphasis = emphasis(for: item)
        guard let first = nights.first, let last = nights.last else {
            return "\(item.event.platform.displayName) · \(emphasis.label)"
        }
        let range = first == last
            ? shortDate(first)
            : "\(shortDate(first))–\(shortDate(last))"
        return "\(item.event.platform.displayName) · \(range) · \(emphasis.label)"
    }

    /// The nights an event occupies, checkout exclusive.
    public static func occupiedNights(of event: CalendarEvent) -> [Date] {
        let start = DayMath.utcMidnight(event.checkIn)
        let end = DayMath.utcMidnight(event.checkOut)
        guard end > start else { return [start] }
        var nights: [Date] = []
        var cursor = start
        while cursor < end {
            nights.append(cursor)
            cursor = DayMath.adding(days: 1, to: cursor)
        }
        return nights
    }

    static func shortDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.day, .month], from: date)
        let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let month = months[min(max(parts.month ?? 1, 1), 12)]
        return "\(parts.day ?? 1) \(month)"
    }
}
