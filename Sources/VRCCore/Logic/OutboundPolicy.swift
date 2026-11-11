import Foundation

/// Which classifications may protect which platforms.
///
/// The constraint that shapes this: **Airbnb's export cannot distinguish an
/// owner block from a cancellation penalty.** Both read `Airbnb (Not
/// available)`. So an outbound calendar can never be a relay of an incoming
/// feed — relaying Airbnb to Vrbo would propagate penalties as ordinary
/// blocks and destroy sellable inventory, which is the failure this whole
/// project exists to prevent.
///
/// Outbound is therefore built from **classified evidence**: what the owner
/// or the classifier has established an event to be, not what a feed called
/// it. An ambiguous Airbnb block arrives needing review and protects nothing
/// until a person says which kind it is.
public struct OutboundPolicy: Sendable, Equatable {

    /// Why a block is not going somewhere.
    public enum BlockedReason: String, Sendable, Equatable {
        /// The kind is never exportable, at any setting.
        case neverExportable
        /// Undecided. Nothing ambiguous may protect another platform.
        case needsReview
        /// Exportable, but this destination was not selected for this kind.
        case destinationNotSelected
        /// A platform does not protect itself.
        case sameAsSource
    }

    public enum Decision: Sendable, Equatable {
        case propagate
        case blocked(reason: BlockedReason)
    }

    /// Where owner blocks go. Everywhere by default — an owner hold means the
    /// unit is not for sale.
    public var ownerBlockDestinations: Set<RentalPlatform>
    /// Where maintenance blocks go. **Empty by default**: the requirement is
    /// "only to platforms I select", so selection is opt-in rather than
    /// something to switch off after the fact.
    public var maintenanceDestinations: Set<RentalPlatform>

    public static let allPlatforms: Set<RentalPlatform> = [.airbnb, .vrbo, .bookingCom]

    public static let `default` = OutboundPolicy(
        ownerBlockDestinations: allPlatforms, maintenanceDestinations: [])

    /// For tests that need to prove a setting cannot unlock a forbidden kind.
    public static let everything = OutboundPolicy(
        ownerBlockDestinations: allPlatforms, maintenanceDestinations: allPlatforms)

    public init(
        ownerBlockDestinations: Set<RentalPlatform>,
        maintenanceDestinations: Set<RentalPlatform>
    ) {
        self.ownerBlockDestinations = ownerBlockDestinations
        self.maintenanceDestinations = maintenanceDestinations
    }

    /// The kinds that may ever leave, derived from the allow-list rather than
    /// restated — two lists that must agree would drift.
    public static var exportableKinds: Set<BlockKind> {
        Set(BlockKind.allCases.filter(\.describesGenuineUnavailability))
    }

    /// Kinds that can never become exportable, whatever anyone decides.
    ///
    /// Distinct from `unknownUnavailable`, which is merely UNDECIDED: the
    /// owner can establish what it is and it may then propagate. Reporting
    /// those two the same way would tell someone a reservation they could
    /// confirm in ten seconds is permanently forbidden.
    public static let permanentlyUnexportable: Set<BlockKind> =
        [.cancellationBlock, .platformRestriction]

    public func decision(_ item: ClassifiedEvent, to destination: RentalPlatform) -> Decision {
        if destination == item.event.platform { return .blocked(reason: .sameAsSource) }
        let kind = item.classification.kind

        // Settled and forbidden outranks everything: a cancellation penalty is
        // not something to review, it is something that never leaves.
        if Self.permanentlyUnexportable.contains(kind) {
            return .blocked(reason: .neverExportable)
        }
        // Undecided — either flagged for review, or unknown by classification.
        // Nothing ambiguous may protect another platform, and this is the
        // reason that tells the owner there is something they can do.
        if item.classification.needsReview || kind == .unknownUnavailable {
            return .blocked(reason: .needsReview)
        }
        guard Self.exportableKinds.contains(kind) else {
            return .blocked(reason: .neverExportable)
        }

        switch kind {
        case .confirmedReservation:
            return .propagate
        case .ownerBlock:
            return ownerBlockDestinations.contains(destination)
                ? .propagate : .blocked(reason: .destinationNotSelected)
        case .maintenanceBlock:
            return maintenanceDestinations.contains(destination)
                ? .propagate : .blocked(reason: .destinationNotSelected)
        case .cancellationBlock, .platformRestriction, .unknownUnavailable:
            return .blocked(reason: .neverExportable)
        }
    }

    public func propagates(_ item: ClassifiedEvent, to destination: RentalPlatform) -> Bool {
        decision(item, to: destination) == .propagate
    }

    /// The nights a protective block covers — checkout exclusive, so the
    /// departure day is released for someone else.
    public static func protectedNights(of item: ClassifiedEvent) -> [Date] {
        CalendarVisibility.occupiedNights(of: item.event)
    }

    /// Whether a protective block may be withdrawn.
    ///
    /// Only after an import that actually succeeded and no longer shows the
    /// source event. A failed, skipped or disconnected import says nothing
    /// about whether a guest is still staying, and withdrawing on its silence
    /// is how a confirmed reservation gets quietly reopened.
    public static func mayWithdraw(
        afterImportOutcome outcome: SyncOutcome, sourceStillPresent: Bool
    ) -> Bool {
        outcome == .success && !sourceStillPresent
    }

    /// And even then it is a proposal. Removals need the owner, exactly as
    /// additions do.
    public static let withdrawalRequiresApproval = true
}

/// Whether one destination has actually received one protective block.
///
/// "Published" is not "protected". The only evidence that counts is the
/// destination's own export showing the nights held — and only if that export
/// is current, because stale evidence is not evidence.
public enum DeliveryStatus: String, Sendable, Equatable {
    case protected
    case pending
    case failed
    case needsReview

    public var label: String {
        switch self {
        case .protected: return "Protected"
        case .pending: return "Pending"
        case .failed: return "Failed"
        case .needsReview: return "Needs review"
        }
    }

    public static func assess(
        item: ClassifiedEvent,
        destination: RentalPlatform,
        policy: OutboundPolicy,
        observedAtDestination: [ClassifiedEvent],
        destinationFeed: FeedFreshness,
        lastPublishFailed: Bool,
        now: Date = Date()
    ) -> DeliveryStatus {
        switch policy.decision(item, to: destination) {
        case .blocked(let reason) where reason == .needsReview:
            return .needsReview
        case .blocked:
            // Not going there by policy. Not a delivery problem.
            return .pending
        case .propagate:
            break
        }
        if lastPublishFailed { return .failed }
        // Stale evidence cannot confirm anything is in place now.
        guard !destinationFeed.isStale(now: now) else { return .pending }

        let needed = Set(OutboundPolicy.protectedNights(of: item))
        var held: Set<Date> = []
        for other in observedAtDestination
        where other.event.platform == destination
            && other.propertyID == item.propertyID
            && other.classification.kind.describesGenuineUnavailability {
            held.formUnion(CalendarVisibility.occupiedNights(of: other.event))
        }
        return needed.isSubset(of: held) ? .protected : .pending
    }
}
