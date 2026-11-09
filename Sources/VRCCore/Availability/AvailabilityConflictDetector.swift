import Foundation

/// Everything the validator needs to judge one proposed decision, gathered by
/// the caller so the detector itself touches no database and stays testable.
public struct AvailabilityContext: Sendable {
    public var property: Property
    /// Every active source event for this property, across all platforms.
    public var sourceEvents: [ClassifiedEvent]
    /// Decisions already recorded for this property.
    public var existingDecisions: [AvailabilityDecision]
    /// Listings, used to judge how stale each feed is.
    public var listings: [PlatformListing]
    /// What the destination platform can actually do.
    public var destinationCapability: PlatformCapability
    public var now: Date

    public init(
        property: Property,
        sourceEvents: [ClassifiedEvent],
        existingDecisions: [AvailabilityDecision],
        listings: [PlatformListing],
        destinationCapability: PlatformCapability,
        now: Date = Date()
    ) {
        self.property = property
        self.sourceEvents = sourceEvents
        self.existingDecisions = existingDecisions
        self.listings = listings
        self.destinationCapability = destinationCapability
        self.now = now
    }
}

/// Checks a proposed availability change before anybody is asked to approve it.
///
/// The six checks the brief asks for, in order: confirmed reservations,
/// overlapping unknown events, existing application-created blocks, stale
/// source calendars, pending operations, and whether the destination can do
/// what is being asked.
public struct AvailabilityConflictDetector: Sendable {

    /// A feed not refreshed within this window is treated as stale, because a
    /// decision taken against week-old availability may already be wrong.
    public static let stalenessThreshold: TimeInterval = 6 * 3_600

    public init() {}

    public func validate(
        _ decision: AvailabilityDecision,
        in context: AvailabilityContext
    ) -> ValidationResult {
        var result = ValidationResult()

        guard decision.nights > 0 else {
            result.add(RuleViolation(
                rule: .defaultToNoPublication,
                severity: .blocking,
                message: "That range covers no nights. Check-out must be after check-in."
            ))
            return result
        }

        // Nothing to check — an explicit decision to do nothing is always safe.
        guard decision.action != .leaveUnchanged else {
            result.notes.append(
                "\(decision.destination.displayName) is left exactly as it is."
            )
            return result
        }

        checkDestinationCapability(decision, context, &result)
        checkConfirmedReservations(decision, context, &result)
        checkUnknownOverlaps(decision, context, &result)
        checkExistingBlocks(decision, context, &result)
        checkStaleFeeds(decision, context, &result)
        checkPendingOperations(decision, context, &result)

        return result
    }

    // MARK: 6. Can the destination even do this?

    private func checkDestinationCapability(
        _ decision: AvailabilityDecision,
        _ context: AvailabilityContext,
        _ result: inout ValidationResult
    ) {
        let capability = context.destinationCapability
        guard capability.acceptsImportedCalendar else {
            result.add(RuleViolation(
                rule: .defaultToNoPublication,
                severity: .blocking,
                message: "\(decision.destination.displayName) cannot import a calendar feed, so "
                    + "this app has no supported way to change its availability."
            ))
            return
        }
        if !capability.supportsRemovingImportedBlocks && decision.action == .unblock {
            result.add(RuleViolation(
                rule: .neverOverridePlatformRestriction,
                severity: .requiresReview,
                message: "\(decision.destination.displayName) removes an imported block only on "
                    + "its own refresh schedule. Reopening is not immediate."
            ))
        }
        result.notes.append(capability.latencyNote)
    }

    // MARK: 1. Confirmed reservations

    private func checkConfirmedReservations(
        _ decision: AvailabilityDecision,
        _ context: AvailabilityContext,
        _ result: inout ValidationResult
    ) {
        let overlapping = context.sourceEvents.filter { item in
            item.event.isActive
                && item.classification.kind == .confirmedReservation
                && !item.classification.needsReview
                && item.event.checkIn < decision.endDay
                && decision.startDay < item.event.checkOut
        }
        guard !overlapping.isEmpty else { return }

        if decision.action == .unblock {
            // R7 — this is the one that must never be allowed through.
            let names = overlapping
                .map { "\($0.event.platform.displayName) \(DayMath.mediumString($0.event.checkIn))" }
                .joined(separator: ", ")
            result.add(RuleViolation(
                rule: .neverReopenConfirmedReservation,
                severity: .blocking,
                message: "Those nights include a confirmed reservation (\(names)). A booked night "
                    + "is never reopened.",
                relatedKeys: overlapping.map(\.event.eventKey)
            ))
            return
        }

        // Blocking nights that already hold a booking is harmless but pointless.
        let sameDestination = overlapping.filter { $0.event.platform == decision.destination }
        if !sameDestination.isEmpty {
            result.add(RuleViolation(
                rule: .defaultToNoPublication,
                severity: .advisory,
                message: "\(decision.destination.displayName) already has a confirmed reservation "
                    + "over part of this range, so blocking changes nothing there.",
                relatedKeys: sameDestination.map(\.event.eventKey)
            ))
        }
    }

    // MARK: 2. Overlapping unknown events

    private func checkUnknownOverlaps(
        _ decision: AvailabilityDecision,
        _ context: AvailabilityContext,
        _ result: inout ValidationResult
    ) {
        // Checked first and independently: a cancellation block is usually
        // *decided*, so it is not in the "unknown" set, and an earlier version
        // of this method returned before ever looking for one.
        let cancellations = context.sourceEvents.filter { item in
            item.event.isActive
                && item.classification.kind == .cancellationBlock
                && item.event.checkIn < decision.endDay
                && decision.startDay < item.event.checkOut
        }
        if !cancellations.isEmpty, decision.action == .block,
           decision.destination != .airbnb {
            let nights = cancellations.reduce(0) { $0 + $1.event.nights }
            result.add(RuleViolation(
                rule: .neverPropagateCancellationBlock,
                severity: .requiresReview,
                message: "These nights overlap \(nights) night\(nights == 1 ? "" : "s") Airbnb "
                    + "blocked after a cancellation. Those nights are still sellable on "
                    + "\(decision.destination.displayName) — this app would never take them off "
                    + "sale by itself, so make sure you mean to.",
                relatedKeys: cancellations.map(\.event.eventKey)
            ))
        }

        let unknown = context.sourceEvents.filter { item in
            item.event.isActive
                && (item.classification.needsReview
                    || item.classification.kind == .unknownUnavailable)
                && item.event.checkIn < decision.endDay
                && decision.startDay < item.event.checkOut
        }
        guard !unknown.isEmpty else { return }

        let nights = unknown.reduce(0) { $0 + $1.event.nights }
        if decision.action == .unblock {
            result.add(RuleViolation(
                rule: .neverPropagateUnknown,
                severity: .requiresReview,
                message: "\(unknown.count) undecided event\(unknown.count == 1 ? "" : "s") "
                    + "overlap\(unknown.count == 1 ? "s" : "") this range (\(nights) nights). One "
                    + "of them may be a real booking. Decide them before reopening these nights.",
                relatedKeys: unknown.map(\.event.eventKey)
            ))
        } else {
            result.add(RuleViolation(
                rule: .neverPropagateUnknown,
                severity: .advisory,
                message: "\(unknown.count) undecided event\(unknown.count == 1 ? "" : "s") "
                    + "overlap\(unknown.count == 1 ? "s" : "") this range. They are not what is "
                    + "being published — your block is — but they are worth deciding.",
                relatedKeys: unknown.map(\.event.eventKey)
            ))
        }

    }

    // MARK: 3. Existing application-created blocks

    private func checkExistingBlocks(
        _ decision: AvailabilityDecision,
        _ context: AvailabilityContext,
        _ result: inout ValidationResult
    ) {
        let liveBlocks = context.existingDecisions.filter {
            $0.id != decision.id
                && $0.destination == decision.destination
                && $0.action == .block
                && $0.status.contributesToFeed
                && $0.overlaps(decision)
        }

        switch decision.action {
        case .block where !liveBlocks.isEmpty:
            result.add(RuleViolation(
                rule: .defaultToNoPublication,
                severity: .advisory,
                message: "\(liveBlocks.count) block\(liveBlocks.count == 1 ? "" : "s") this app "
                    + "already created cover\(liveBlocks.count == 1 ? "s" : "") part of this "
                    + "range. The new one replaces them rather than stacking.",
                relatedKeys: liveBlocks.compactMap { $0.id.map(String.init) }
            ))
        case .unblock where liveBlocks.isEmpty:
            result.add(RuleViolation(
                rule: .neverOverridePlatformRestriction,
                severity: .blocking,
                message: "This app has not blocked any of those nights on "
                    + "\(decision.destination.displayName), so there is nothing of ours to "
                    + "remove. Anything blocking them there belongs to the platform or to you, "
                    + "and this app will not touch it."
            ))
        default:
            break
        }
    }

    // MARK: 4. Stale source calendars

    private func checkStaleFeeds(
        _ decision: AvailabilityDecision,
        _ context: AvailabilityContext,
        _ result: inout ValidationResult
    ) {
        var stale: [String] = []
        var never: [String] = []
        for listing in context.listings where listing.propertyID == decision.propertyID {
            guard let last = listing.lastSyncAt else {
                never.append(listing.platform.displayName)
                continue
            }
            if context.now.timeIntervalSince(last) > Self.stalenessThreshold {
                stale.append(listing.platform.displayName)
            }
        }

        if !never.isEmpty {
            result.add(RuleViolation(
                rule: .defaultToNoPublication,
                severity: .requiresReview,
                message: "\(never.joined(separator: " and ")) "
                    + "\(never.count == 1 ? "has" : "have") never been imported, so this app does "
                    + "not know what is booked there. Refresh before deciding."
            ))
        }
        if !stale.isEmpty {
            result.add(RuleViolation(
                rule: .defaultToNoPublication,
                severity: .requiresReview,
                message: "\(stale.joined(separator: " and ")) "
                    + "\(stale.count == 1 ? "was" : "were") last read more than six hours ago. A "
                    + "booking taken since then would not be visible here. Refresh first."
            ))
        }
    }

    // MARK: 5. Pending operations

    private func checkPendingOperations(
        _ decision: AvailabilityDecision,
        _ context: AvailabilityContext,
        _ result: inout ValidationResult
    ) {
        let pending = context.existingDecisions.filter {
            $0.id != decision.id
                && $0.destination == decision.destination
                && $0.status.isPending
                && $0.overlaps(decision)
        }
        guard !pending.isEmpty else { return }
        result.add(RuleViolation(
            rule: .defaultToNoPublication,
            severity: .requiresReview,
            message: "\(pending.count) other change\(pending.count == 1 ? "" : "s") to "
                + "\(decision.destination.displayName) over these nights "
                + "\(pending.count == 1 ? "is" : "are") still waiting. Settle "
                + "\(pending.count == 1 ? "it" : "them") first so the result is predictable.",
            relatedKeys: pending.compactMap { $0.id.map(String.init) }
        ))
    }
}
