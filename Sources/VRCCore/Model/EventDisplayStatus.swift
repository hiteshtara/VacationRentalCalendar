import Foundation

/// The single label the interface shows for an event.
///
/// `BlockKind` and `needsReview` are orthogonal in the data — an event can be a
/// maintenance block that still needs review. For a person scanning a calendar
/// that distinction is noise, so the two collapse into one status with one
/// colour and one name, and "needs review" wins whenever it is set: an
/// undecided event is undecided no matter what the classifier guessed.
public enum EventDisplayStatus: String, CaseIterable, Sendable, Identifiable {
    case confirmed
    case ownerBlock
    case maintenance
    case cancellationBlock
    case needsReview
    case unknown

    public var id: String { rawValue }

    public static func status(for classification: EventClassification) -> EventDisplayStatus {
        if classification.needsReview { return .needsReview }
        switch classification.kind {
        case .confirmedReservation: return .confirmed
        case .ownerBlock: return .ownerBlock
        case .maintenanceBlock: return .maintenance
        case .cancellationBlock: return .cancellationBlock
        case .unknownUnavailable: return .unknown
        }
    }

    public var label: String {
        switch self {
        case .confirmed: return "Confirmed"
        case .ownerBlock: return "Owner block"
        case .maintenance: return "Maintenance"
        case .cancellationBlock: return "Cancellation block"
        case .needsReview: return "Needs review"
        case .unknown: return "Unknown"
        }
    }

    /// Shown in the detail panel under the status, in plain terms.
    public var consequence: String {
        switch self {
        case .confirmed:
            return "A guest is staying. These nights are blocked on your other platforms."
        case .ownerBlock:
            return "You are holding these nights. They are shared once you approve them."
        case .maintenance:
            return "The unit is unusable. These nights are shared once you approve them."
        case .cancellationBlock:
            return "Airbnb took these nights after a cancellation. They stay on sale on Vrbo and "
                + "Booking.com, and are never exported."
        case .needsReview:
            return "Undecided, so these nights stay on sale everywhere else until you say what "
                + "they are."
        case .unknown:
            return "Unavailable for an unknown reason, so these nights are never exported."
        }
    }

    /// Whether the nights remain sellable on other platforms. Drives the one
    /// visual rule that runs through the whole app: solid means genuinely gone,
    /// hollow means still yours to sell.
    public var isSellableElsewhere: Bool {
        switch self {
        case .confirmed, .ownerBlock, .maintenance: return false
        case .cancellationBlock, .needsReview, .unknown: return true
        }
    }

    /// SF Symbol name.
    public var symbolName: String {
        switch self {
        case .confirmed: return "person.fill.checkmark"
        case .ownerBlock: return "house.fill"
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .cancellationBlock: return "arrow.uturn.backward"
        case .needsReview: return "questionmark"
        case .unknown: return "questionmark.diamond"
        }
    }

    /// The kind a person choosing this status means, where one exists.
    public var correspondingKind: BlockKind? {
        switch self {
        case .confirmed: return .confirmedReservation
        case .ownerBlock: return .ownerBlock
        case .maintenance: return .maintenanceBlock
        case .cancellationBlock: return .cancellationBlock
        case .needsReview, .unknown: return nil
        }
    }
}

public extension ClassifiedEvent {
    var displayStatus: EventDisplayStatus {
        EventDisplayStatus.status(for: classification)
    }
}
