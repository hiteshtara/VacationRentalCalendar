import Foundation

public enum AvailabilityError: Error, LocalizedError {
    case refused([RuleViolation])
    case illegalTransition(from: AvailabilityStatus, to: AvailabilityStatus)
    case notFound(Int64)
    case outboundDisabled
    case notApproved

    public var errorDescription: String? {
        switch self {
        case .refused(let violations):
            return violations.first?.message ?? "That change was refused."
        case .illegalTransition(let from, let to):
            return "A decision cannot go from \(from.displayName.lowercased()) to "
                + "\(to.displayName.lowercased())."
        case .notFound(let id):
            return "Decision \(id) no longer exists."
        case .outboundDisabled:
            return OutboundSyncGate.explanation
        case .notApproved:
            return "That decision has not been approved, so it cannot be published."
        }
    }
}

/// A set of per-platform choices made together for one date range.
public struct AvailabilityPlan: Sendable {
    public var propertyID: Int64
    public var startDay: Date
    public var endDay: Date
    public var reason: String
    /// One entry per destination the owner touched. Missing platforms are
    /// untouched, which is not the same as `leaveUnchanged` — that is an
    /// explicit, recorded choice.
    public var actions: [RentalPlatform: AvailabilityAction]

    public init(
        propertyID: Int64,
        startDay: Date,
        endDay: Date,
        reason: String = "",
        actions: [RentalPlatform: AvailabilityAction]
    ) {
        self.propertyID = propertyID
        self.startDay = DayMath.utcMidnight(startDay)
        self.endDay = DayMath.utcMidnight(endDay)
        self.reason = reason
        self.actions = actions
    }

    public var nights: Int { max(0, DayMath.daysBetween(startDay, endDay)) }
}

/// What a plan would do, before anything is written.
public struct AvailabilityPreview: Sendable {
    public struct Line: Sendable, Identifiable {
        public var destination: RentalPlatform
        public var action: AvailabilityAction
        public var validation: ValidationResult
        public var decision: AvailabilityDecision
        public var id: String { destination.rawValue }

        public var canProceed: Bool { validation.canProceed }
    }

    public var lines: [Line]
    public var propertyName: String
    public var startDay: Date
    public var endDay: Date

    public var nights: Int { max(0, DayMath.daysBetween(startDay, endDay)) }
    public var isRefusedAnywhere: Bool { lines.contains { !$0.canProceed } }
    public var needsReviewAnywhere: Bool { lines.contains { $0.validation.needsReview } }
    public var actionable: [Line] { lines.filter { $0.canProceed && $0.action != .leaveUnchanged } }

    /// Plain description of the nights, to remove any doubt about the end date.
    public var nightsDescription: String {
        guard nights > 0 else { return "No nights selected." }
        let lastNight = DayMath.adding(days: -1, to: endDay)
        if nights == 1 { return "The night of \(DayMath.mediumString(startDay))." }
        return "The nights of \(DayMath.mediumString(startDay)) to "
            + "\(DayMath.mediumString(lastNight)) — \(nights) nights. "
            + "\(DayMath.mediumString(endDay)) stays free for an arrival."
    }
}

/// Creates, validates, approves and cancels availability decisions.
///
/// Every state change goes through here, and every one writes an audit entry.
/// The state machine in `AvailabilityStatus.allowedTransitions` is enforced on
/// the way, so nothing can skip from draft to published.
public final class AvailabilityManager: @unchecked Sendable {
    let decisions: AvailabilityRepository
    let audit: AvailabilityAuditLog
    let detector: AvailabilityConflictDetector
    let properties: PropertyRepository
    let listings: ListingRepository
    private let eventsProvider: @Sendable () throws -> [ClassifiedEvent]

    public init(
        decisions: AvailabilityRepository,
        audit: AvailabilityAuditLog,
        properties: PropertyRepository,
        listings: ListingRepository,
        detector: AvailabilityConflictDetector = AvailabilityConflictDetector(),
        eventsProvider: @escaping @Sendable () throws -> [ClassifiedEvent]
    ) {
        self.decisions = decisions
        self.audit = audit
        self.properties = properties
        self.listings = listings
        self.detector = detector
        self.eventsProvider = eventsProvider
    }

    // MARK: - Context

    public func context(
        propertyID: Int64, destination: RentalPlatform, now: Date = Date()
    ) throws -> AvailabilityContext {
        let property = try properties.find(id: propertyID)
            ?? Property(id: propertyID, name: "Property \(propertyID)")
        return AvailabilityContext(
            property: property,
            sourceEvents: try eventsProvider().filter { $0.propertyID == propertyID },
            existingDecisions: try decisions.forProperty(propertyID),
            listings: try listings.all(),
            destinationCapability: PlatformAdapters.capability(for: destination),
            now: now
        )
    }

    // MARK: - Preview

    /// Works out what a plan would do. Writes nothing.
    public func preview(_ plan: AvailabilityPlan, now: Date = Date()) throws -> AvailabilityPreview {
        let property = try properties.find(id: plan.propertyID)
        var lines: [AvailabilityPreview.Line] = []

        for destination in RentalPlatform.allCases where plan.actions[destination] != nil {
            let action = plan.actions[destination]!
            let candidate = AvailabilityDecision(
                propertyID: plan.propertyID,
                destination: destination,
                action: action,
                startDay: plan.startDay,
                endDay: plan.endDay,
                reason: plan.reason
            )
            let validation = detector.validate(
                candidate,
                in: try context(propertyID: plan.propertyID, destination: destination, now: now)
            )
            lines.append(AvailabilityPreview.Line(
                destination: destination, action: action,
                validation: validation, decision: candidate
            ))
        }

        return AvailabilityPreview(
            lines: lines.sorted { $0.destination.displayName < $1.destination.displayName },
            propertyName: property?.name ?? "Property \(plan.propertyID)",
            startDay: plan.startDay,
            endDay: plan.endDay
        )
    }

    // MARK: - Creating

    /// Saves a plan as drafts, validates each, and moves the clean ones to
    /// `awaitingApproval`. Refused lines are stored as `failed` so the reason
    /// survives rather than vanishing.
    @discardableResult
    public func submit(
        _ plan: AvailabilityPlan, actor: String = "owner", now: Date = Date()
    ) throws -> [AvailabilityDecision] {
        var stored: [AvailabilityDecision] = []

        for destination in RentalPlatform.allCases {
            guard let action = plan.actions[destination] else { continue }

            var decision = try decisions.insert(AvailabilityDecision(
                propertyID: plan.propertyID,
                destination: destination,
                action: action,
                startDay: plan.startDay,
                endDay: plan.endDay,
                status: .draft,
                reason: plan.reason,
                createdAt: now,
                updatedAt: now,
                createdBy: actor
            ))
            try audit.record(AuditEntry(
                decisionID: decision.id, at: now, actor: actor,
                toStatus: .draft, event: "created",
                detail: decision.summaryLine
            ))

            let validation = detector.validate(
                decision,
                in: try context(propertyID: plan.propertyID, destination: destination, now: now)
            )

            if validation.isRefused {
                decision = try transition(
                    decision, to: .failed, actor: actor, now: now,
                    detail: validation.blocking.map(\.message).joined(separator: " ")
                )
                decision.failureReason = validation.blocking.first?.message
                try decisions.update(decision)
                stored.append(decision)
                continue
            }

            decision = try transition(
                decision, to: .validated, actor: actor, now: now,
                detail: validation.needsReview
                    ? validation.needingReview.map(\.message).joined(separator: " ")
                    : "No conflicts found."
            )
            decision.validatedAt = now
            try decisions.update(decision)

            decision = try transition(
                decision, to: .awaitingApproval, actor: actor, now: now,
                detail: "Waiting for approval. Nothing is published until then."
            )
            stored.append(decision)
        }

        return stored
    }

    // MARK: - Approving

    /// Records the owner's approval. Re-validates first, because the world may
    /// have moved since the plan was written — a booking may have arrived.
    @discardableResult
    public func approve(
        decisionID: Int64, actor: String = "owner", now: Date = Date()
    ) throws -> AvailabilityDecision {
        guard var decision = try decisions.find(id: decisionID) else {
            throw AvailabilityError.notFound(decisionID)
        }
        let validation = detector.validate(
            decision,
            in: try context(
                propertyID: decision.propertyID, destination: decision.destination, now: now
            )
        )
        guard !validation.isRefused else {
            let updated = try transition(
                decision, to: .failed, actor: actor, now: now,
                detail: "Re-checked at approval and refused: "
                    + validation.blocking.map(\.message).joined(separator: " ")
            )
            var failed = updated
            failed.failureReason = validation.blocking.first?.message
            try decisions.update(failed)
            throw AvailabilityError.refused(validation.blocking)
        }

        decision = try transition(
            decision, to: .approved, actor: actor, now: now,
            detail: "Approved by \(actor). Not yet published."
        )
        decision.approvedAt = now
        decision.approvedBy = actor
        try decisions.update(decision)
        return decision
    }

    @discardableResult
    public func cancel(
        decisionID: Int64, actor: String = "owner", reason: String = "", now: Date = Date()
    ) throws -> AvailabilityDecision {
        guard let decision = try decisions.find(id: decisionID) else {
            throw AvailabilityError.notFound(decisionID)
        }
        var cancelled = try transition(
            decision, to: .cancelled, actor: actor, now: now,
            detail: reason.isEmpty ? "Cancelled before publication." : reason
        )
        cancelled.cancelledAt = now
        try decisions.update(cancelled)
        return cancelled
    }

    /// Cancels every still-pending decision for a property and range — the
    /// "cancel pending changes" the editor offers.
    @discardableResult
    public func cancelPending(
        propertyID: Int64, actor: String = "owner", now: Date = Date()
    ) throws -> Int {
        let pending = try decisions.forProperty(propertyID).filter { $0.status.isPending }
        for decision in pending {
            guard let id = decision.id else { continue }
            _ = try cancel(decisionID: id, actor: actor, reason: "Pending changes cleared.", now: now)
        }
        return pending.count
    }

    // MARK: - Publication bookkeeping

    /// Marks an approved decision as published. Refuses while the outbound gate
    /// is shut, which is the whole point of the gate.
    @discardableResult
    public func markPublished(
        decisionID: Int64, actor: String = "system", now: Date = Date()
    ) throws -> AvailabilityDecision {
        guard OutboundSyncGate.isEnabled else { throw AvailabilityError.outboundDisabled }
        guard var decision = try decisions.find(id: decisionID) else {
            throw AvailabilityError.notFound(decisionID)
        }
        guard decision.status == .approved else { throw AvailabilityError.notApproved }

        let capability = PlatformAdapters.capability(for: decision.destination)
        decision = try transition(
            decision, to: .published, actor: actor, now: now,
            detail: "Included in a published feed. " + capability.latencyNote
        )
        decision.publishedAt = now
        decision.refreshExpectedBy = now.addingTimeInterval(capability.worstCaseRefreshInterval)
        try decisions.update(decision)
        return decision
    }

    /// Applies verification evidence. Only conclusive, positive evidence is
    /// allowed to produce `verified`.
    @discardableResult
    public func applyVerification(
        decisionID: Int64, evidence: VerificationEvidence, actor: String = "system"
    ) throws -> AvailabilityDecision {
        guard var decision = try decisions.find(id: decisionID) else {
            throw AvailabilityError.notFound(decisionID)
        }
        if evidence.supportsVerified {
            decision = try transition(
                decision, to: .verified, actor: actor, now: evidence.checkedAt,
                detail: evidence.detail
            )
            decision.verifiedAt = evidence.checkedAt
        } else if decision.status == .published {
            decision = try transition(
                decision, to: .awaitingPlatformRefresh, actor: actor, now: evidence.checkedAt,
                detail: evidence.detail
            )
        } else {
            try audit.record(AuditEntry(
                decisionID: decision.id, at: evidence.checkedAt, actor: actor,
                fromStatus: decision.status, toStatus: decision.status,
                event: "verification-checked", detail: evidence.detail
            ))
            return decision
        }
        try decisions.update(decision)
        return decision
    }

    // MARK: - Transitions

    /// The only way a decision changes state. Refuses illegal moves and always
    /// writes an audit entry.
    @discardableResult
    func transition(
        _ decision: AvailabilityDecision,
        to target: AvailabilityStatus,
        actor: String,
        now: Date,
        detail: String
    ) throws -> AvailabilityDecision {
        guard decision.status.allowedTransitions.contains(target) else {
            try audit.record(AuditEntry(
                decisionID: decision.id, at: now, actor: actor,
                fromStatus: decision.status, toStatus: target,
                event: "transition-refused", detail: detail
            ))
            throw AvailabilityError.illegalTransition(from: decision.status, to: target)
        }
        var updated = decision
        updated.status = target
        updated.updatedAt = now
        try decisions.update(updated)
        try audit.record(AuditEntry(
            decisionID: decision.id, at: now, actor: actor,
            fromStatus: decision.status, toStatus: target,
            event: "status-changed", detail: detail
        ))
        return updated
    }
}
