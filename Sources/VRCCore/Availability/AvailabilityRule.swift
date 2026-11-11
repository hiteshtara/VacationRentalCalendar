import Foundation

/// The ten protections, written down once, in one place, each with an
/// identifier so a refusal can name the rule that caused it.
///
/// They are kept as data rather than scattered through `if` statements so that
/// a test can assert the whole set is enforced, and so a future change has to
/// edit a named rule rather than quietly weaken a condition somewhere.
public enum AvailabilityRule: String, CaseIterable, Sendable, Identifiable {
    /// An imported unavailable event is never auto-promoted to a confirmed
    /// reservation; only positive booking evidence or a human does that.
    case neverAutoConfirm = "R1"
    /// An Airbnb cancellation-related restriction never reaches another platform.
    case neverPropagateCancellationBlock = "R2"
    /// An unknown Airbnb unavailable event never propagates without review and
    /// approval.
    case neverPropagateUnknown = "R3"
    /// Manual classifications survive imports and restarts.
    case preserveManualClassification = "R4"
    /// A materially changed source event returns for review.
    case rereviewOnMaterialChange = "R5"
    /// Platform-imposed restrictions are never overridden.
    case neverOverridePlatformRestriction = "R6"
    /// A date held by a confirmed reservation is never reopened.
    case neverReopenConfirmedReservation = "R7"
    /// A manual classification is the owner's belief, not platform verification.
    case manualIsNotVerification = "R8"
    /// Source events and availability decisions stay separate records.
    case separateSourceFromDecision = "R9"
    /// Anything uncertain defaults to not being published.
    case defaultToNoPublication = "R10"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .neverAutoConfirm:
            return "Never auto-confirm an imported block"
        case .neverPropagateCancellationBlock:
            return "Never propagate a cancellation block"
        case .neverPropagateUnknown:
            return "Never propagate an unreviewed block"
        case .preserveManualClassification:
            return "Keep your classifications"
        case .rereviewOnMaterialChange:
            return "Re-review a materially changed event"
        case .neverOverridePlatformRestriction:
            return "Never override a platform restriction"
        case .neverReopenConfirmedReservation:
            return "Never reopen a booked night"
        case .manualIsNotVerification:
            return "Your classification is not platform verification"
        case .separateSourceFromDecision:
            return "Imported events are never edited"
        case .defaultToNoPublication:
            return "When uncertain, publish nothing"
        }
    }

    public var detail: String {
        switch self {
        case .neverAutoConfirm:
            return "An imported unavailable event is only treated as a confirmed reservation "
                + "when the platform supplied booking-specific evidence, or when you said so."
        case .neverPropagateCancellationBlock:
            return "Dates Airbnb blocked after a cancellation are not booked. They stay on sale "
                + "on Vrbo and Booking.com, and no approval can override that."
        case .neverPropagateUnknown:
            return "An unavailable event whose cause is unknown is never shared with another "
                + "platform until you classify it and approve it."
        case .preserveManualClassification:
            return "A classification you made survives every later import and every restart."
        case .rereviewOnMaterialChange:
            return "If the platform changes an event's dates or wording, your earlier decision "
                + "may no longer describe it, so it comes back for review."
        case .neverOverridePlatformRestriction:
            return "A restriction the platform imposed is theirs. This app can only withdraw "
                + "blocks it created itself."
        case .neverReopenConfirmedReservation:
            return "A night held by a confirmed reservation is never reopened, whatever is asked."
        case .manualIsNotVerification:
            return "Saying an event is a booking records your belief. It is not confirmation from "
                + "the platform, and is never presented as such."
        case .separateSourceFromDecision:
            return "Imported events record what a platform said. Availability decisions record "
                + "what you want. The first is never edited to express the second."
        case .defaultToNoPublication:
            return "Wherever classification or synchronisation state is uncertain, the safe answer "
                + "is to publish nothing."
        }
    }
}

/// Why something was refused or held back, naming the rule responsible.
public struct RuleViolation: Hashable, Sendable, Identifiable {
    public enum Severity: String, Sendable, Comparable {
        /// Cannot proceed. No approval overrides this.
        case blocking
        /// Proceed only after the owner looks.
        case requiresReview
        /// Worth saying, not worth stopping for.
        case advisory

        private var rank: Int {
            switch self {
            case .advisory: return 0
            case .requiresReview: return 1
            case .blocking: return 2
            }
        }
        public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }

    public var rule: AvailabilityRule
    public var severity: Severity
    public var message: String
    /// Source events or decisions the owner should look at.
    public var relatedKeys: [String]

    public var id: String { "\(rule.rawValue)-\(message)" }

    public init(
        rule: AvailabilityRule,
        severity: Severity,
        message: String,
        relatedKeys: [String] = []
    ) {
        self.rule = rule
        self.severity = severity
        self.message = message
        self.relatedKeys = relatedKeys
    }
}

/// The verdict on one proposed decision.
public struct ValidationResult: Sendable {
    public var violations: [RuleViolation]
    /// Things worth telling the owner that are not rule violations.
    public var notes: [String]

    public init(violations: [RuleViolation] = [], notes: [String] = []) {
        self.violations = violations
        self.notes = notes
    }

    public var blocking: [RuleViolation] { violations.filter { $0.severity == .blocking } }
    public var needingReview: [RuleViolation] {
        violations.filter { $0.severity == .requiresReview }
    }
    public var advisories: [RuleViolation] { violations.filter { $0.severity == .advisory } }

    /// Refused outright — no approval can proceed.
    public var isRefused: Bool { !blocking.isEmpty }
    /// May proceed, but only with the owner's eyes on it first.
    public var needsReview: Bool { !needingReview.isEmpty }
    public var canProceed: Bool { !isRefused }

    public var headline: String {
        if isRefused { return blocking[0].message }
        if needsReview { return needingReview[0].message }
        return "No conflicts found."
    }

    public mutating func add(_ violation: RuleViolation) { violations.append(violation) }
}
