import Foundation

/// What an unavailable date range actually *is*.
///
/// The distinction between `cancellationBlock` and `ownerBlock` is the whole
/// business case for this application: a cancellation block is dates Airbnb
/// took away as a penalty, which remain sellable elsewhere, whereas an owner
/// block is dates the owner genuinely wants held everywhere.
public enum BlockKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A real guest is staying. Safe to block everywhere.
    case confirmedReservation = "confirmed_reservation"
    /// The owner is holding the dates on purpose.
    case ownerBlock = "owner_block"
    /// Cleaning, repairs, renovation.
    case maintenanceBlock = "maintenance_block"
    /// Airbnb blocked the dates because of a host cancellation. NOT booked.
    /// Must never reach another platform.
    case cancellationBlock = "cancellation_block"
    /// Unavailable, cause unknown. Treated as unsafe to share.
    case unknownUnavailable = "unknown_unavailable"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .confirmedReservation: return "Confirmed reservation"
        case .ownerBlock: return "Owner block"
        case .maintenanceBlock: return "Maintenance block"
        case .cancellationBlock: return "Cancellation block"
        case .unknownUnavailable: return "Unknown unavailable"
        }
    }

    /// Longer text shown next to the choice in the review queue.
    public var guidance: String {
        switch self {
        case .confirmedReservation:
            return "A guest is actually staying. These dates will be blocked on your other platforms."
        case .ownerBlock:
            return "You are holding these dates yourself. They will be blocked on other platforms once approved."
        case .maintenanceBlock:
            return "The unit is unusable. These dates will be blocked on other platforms once approved."
        case .cancellationBlock:
            return "Airbnb took these dates away after a cancellation. They stay sellable on Vrbo and Booking.com and are never exported."
        case .unknownUnavailable:
            return "Cause unknown. Never exported until you decide what it is."
        }
    }

    /// Kinds that can, after human approval, legitimately block other platforms.
    public var describesGenuineUnavailability: Bool {
        switch self {
        case .confirmedReservation, .ownerBlock, .maintenanceBlock: return true
        case .cancellationBlock, .unknownUnavailable: return false
        }
    }
}

public enum ClassificationConfidence: String, Codable, CaseIterable, Sendable, Comparable {
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func < (a: ClassificationConfidence, b: ClassificationConfidence) -> Bool {
        a.rank < b.rank
    }

    public var displayName: String { rawValue.capitalized }
}

public enum ClassificationSource: String, Codable, CaseIterable, Sendable {
    /// Produced by the heuristic classifier from feed evidence.
    case automatic
    /// Chosen by the owner. Never overwritten by a later import.
    case manual

    public var displayName: String {
        self == .manual ? "You decided" : "Auto-detected"
    }
}

/// The classifier's opinion about one event, before it is stored.
public struct ClassificationProposal: Hashable, Sendable {
    public var kind: BlockKind
    public var confidence: ClassificationConfidence
    /// Human-readable explanation of what evidence drove the decision.
    public var rationale: String
    public var needsReview: Bool

    public init(
        kind: BlockKind,
        confidence: ClassificationConfidence,
        rationale: String,
        needsReview: Bool
    ) {
        self.kind = kind
        self.confidence = confidence
        self.rationale = rationale
        self.needsReview = needsReview
    }
}

/// A stored classification, keyed by the event's stable key so that it survives
/// re-imports, feed edits and database row recreation.
public struct EventClassification: Hashable, Sendable, Identifiable {
    public var eventKey: String
    public var kind: BlockKind
    public var confidence: ClassificationConfidence
    public var source: ClassificationSource
    /// True while the app is not confident enough to act on this by itself.
    public var needsReview: Bool
    public var rationale: String
    /// Free-text note from the owner.
    public var note: String
    /// Set when the owner explicitly approves a block for outbound export.
    /// Confirmed reservations do not need it; blocks do.
    public var exportApproved: Bool
    /// Lets the owner suppress an event from export even if policy would allow it.
    public var exportSuppressed: Bool
    public var decidedAt: Date

    public var id: String { eventKey }

    public init(
        eventKey: String,
        kind: BlockKind,
        confidence: ClassificationConfidence,
        source: ClassificationSource,
        needsReview: Bool,
        rationale: String = "",
        note: String = "",
        exportApproved: Bool = false,
        exportSuppressed: Bool = false,
        decidedAt: Date = Date()
    ) {
        self.eventKey = eventKey
        self.kind = kind
        self.confidence = confidence
        self.source = source
        self.needsReview = needsReview
        self.rationale = rationale
        self.note = note
        self.exportApproved = exportApproved
        self.exportSuppressed = exportSuppressed
        self.decidedAt = decidedAt
    }

    public init(eventKey: String, proposal: ClassificationProposal, decidedAt: Date = Date()) {
        self.init(
            eventKey: eventKey,
            kind: proposal.kind,
            confidence: proposal.confidence,
            source: .automatic,
            needsReview: proposal.needsReview,
            rationale: proposal.rationale,
            decidedAt: decidedAt
        )
    }

    /// A manual decision is authoritative: it is never re-derived on import.
    public var isLocked: Bool { source == .manual }
}

/// An event paired with its classification, which is what the UI actually works with.
public struct ClassifiedEvent: Identifiable, Hashable, Sendable {
    public var event: CalendarEvent
    public var classification: EventClassification
    public var listingLabel: String
    public var propertyID: Int64
    public var propertyName: String

    public var id: String { event.eventKey }

    public init(
        event: CalendarEvent,
        classification: EventClassification,
        listingLabel: String = "",
        propertyID: Int64 = 0,
        propertyName: String = ""
    ) {
        self.event = event
        self.classification = classification
        self.listingLabel = listingLabel
        self.propertyID = propertyID
        self.propertyName = propertyName
    }
}
