import Foundation

/// How, if at all, a published change can be confirmed on a destination.
public enum SyncVerificationStrategy: Sendable, Hashable {
    /// Re-import the destination's own export and look for the nights.
    case reimportSourceFeed(expectedWithin: TimeInterval, note: String)
    /// The same, but the platform's export cannot distinguish our block from
    /// anything else, so a match is suggestive rather than conclusive.
    case weakReimport(note: String)
    /// No way to check at all.
    case unsupported

    public var canEverVerify: Bool {
        if case .unsupported = self { return false }
        return true
    }

    public var note: String {
        switch self {
        case .reimportSourceFeed(_, let note), .weakReimport(let note): return note
        case .unsupported: return "There is no way to confirm a change on this platform."
        }
    }
}

/// What was actually observed about a destination.
///
/// The point of this type is the distinction it forces: writing a file is one
/// thing, a platform having read it is another, and only the second counts as
/// `verified`.
public struct VerificationEvidence: Sendable, Hashable {
    public enum Outcome: String, Sendable {
        /// The destination's export now shows the nights unavailable.
        case nightsAppearBlocked
        /// It does not, and enough time has passed that it should.
        case nightsStillOpen
        /// Not enough time has passed to expect anything yet.
        case tooEarly
        /// Could not look — feed unreachable, no URL, and so on.
        case couldNotCheck

        public var confirms: Bool { self == .nightsAppearBlocked }
    }

    public var destination: RentalPlatform
    public var outcome: Outcome
    public var checkedAt: Date
    /// False when the platform's own export cannot prove our feed caused it.
    public var isConclusive: Bool
    public var detail: String

    public init(
        destination: RentalPlatform,
        outcome: Outcome,
        checkedAt: Date = Date(),
        isConclusive: Bool,
        detail: String
    ) {
        self.destination = destination
        self.outcome = outcome
        self.checkedAt = checkedAt
        self.isConclusive = isConclusive
        self.detail = detail
    }

    /// Only a conclusive, positive observation is allowed to mark a decision
    /// verified. Everything else leaves it "published — awaiting confirmation".
    public var supportsVerified: Bool { outcome.confirms && isConclusive }
}

/// Decides whether a published decision may be called verified.
public struct SyncVerifier: Sendable {
    public init() {}

    /// Looks for the decision's nights in the destination's own imported events.
    ///
    /// - Parameter destinationEvents: source events most recently imported
    ///   *from the destination platform*.
    public func check(
        decision: AvailabilityDecision,
        destinationEvents: [ClassifiedEvent],
        strategy: SyncVerificationStrategy,
        now: Date = Date()
    ) -> VerificationEvidence {
        guard decision.action == .block else {
            return VerificationEvidence(
                destination: decision.destination,
                outcome: .couldNotCheck,
                checkedAt: now,
                isConclusive: false,
                detail: "Only blocks can be checked this way."
            )
        }

        switch strategy {
        case .unsupported:
            return VerificationEvidence(
                destination: decision.destination,
                outcome: .couldNotCheck,
                checkedAt: now,
                isConclusive: false,
                detail: strategy.note
            )

        case .weakReimport(let note):
            let covered = coversWholeRange(decision, destinationEvents)
            return VerificationEvidence(
                destination: decision.destination,
                outcome: covered ? .nightsAppearBlocked : .nightsStillOpen,
                checkedAt: now,
                // Deliberately never conclusive — see BookingComAdapter.
                isConclusive: false,
                detail: covered
                    ? "Those nights are closed on \(decision.destination.displayName), but "
                        + note
                    : "Those nights are still open on \(decision.destination.displayName)."
            )

        case .reimportSourceFeed(let expectedWithin, let note):
            let covered = coversWholeRange(decision, destinationEvents)
            if covered {
                return VerificationEvidence(
                    destination: decision.destination,
                    outcome: .nightsAppearBlocked,
                    checkedAt: now,
                    isConclusive: true,
                    detail: "\(decision.destination.displayName)'s own calendar now shows those "
                        + "nights as unavailable."
                )
            }
            guard let published = decision.publishedAt else {
                return VerificationEvidence(
                    destination: decision.destination,
                    outcome: .tooEarly,
                    checkedAt: now,
                    isConclusive: false,
                    detail: "Not published yet."
                )
            }
            let elapsed = now.timeIntervalSince(published)
            if elapsed < expectedWithin {
                let remaining = Int((expectedWithin - elapsed) / 3_600)
                return VerificationEvidence(
                    destination: decision.destination,
                    outcome: .tooEarly,
                    checkedAt: now,
                    isConclusive: false,
                    detail: "Published \(Int(elapsed / 3_600))h ago. "
                        + "\(decision.destination.displayName) may take up to \(remaining)h more. "
                        + note
                )
            }
            return VerificationEvidence(
                destination: decision.destination,
                outcome: .nightsStillOpen,
                checkedAt: now,
                isConclusive: true,
                detail: "\(decision.destination.displayName) has had long enough to read the feed "
                    + "and those nights are still open there. Check the feed URL is subscribed "
                    + "on that platform."
            )
        }
    }

    /// Every night of the decision must be covered by an imported event from
    /// the destination. Partial coverage is not confirmation.
    private func coversWholeRange(
        _ decision: AvailabilityDecision, _ events: [ClassifiedEvent]
    ) -> Bool {
        let relevant = events.filter {
            $0.event.platform == decision.destination && $0.event.isActive
        }
        guard !relevant.isEmpty else { return false }
        var night = DayMath.utcMidnight(decision.startDay)
        let end = DayMath.utcMidnight(decision.endDay)
        while night < end {
            let night2 = night
            guard relevant.contains(where: { $0.event.covers(day: night2) }) else { return false }
            night = DayMath.adding(days: 1, to: night)
        }
        return true
    }
}
