import Foundation

/// A booking channel the owner lists on.
public enum RentalPlatform: String, Codable, CaseIterable, Sendable, Identifiable {
    case airbnb
    case vrbo
    case bookingCom = "booking_com"
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .airbnb: return "Airbnb"
        case .vrbo: return "Vrbo"
        case .bookingCom: return "Booking.com"
        case .other: return "Other"
        }
    }

    /// Short tag used in dense calendar cells.
    public var shortTag: String {
        switch self {
        case .airbnb: return "ABB"
        case .vrbo: return "VRBO"
        case .bookingCom: return "BDC"
        case .other: return "OTHER"
        }
    }

    /// Best-effort platform guess from an iCal UID or feed host. Advisory only —
    /// the platform is really determined by which listing the feed is attached
    /// to, never by feed content.
    public static func inferred(fromUID uid: String, host: String?) -> RentalPlatform? {
        let haystack = (uid + " " + (host ?? "")).lowercased()
        if haystack.contains("airbnb") { return .airbnb }
        if haystack.contains("homeaway") || haystack.contains("vrbo") { return .vrbo }
        if haystack.contains("booking.com") || haystack.contains("bookingcom") { return .bookingCom }
        return nil
    }
}
