import Foundation

/// Why a proposed feed holds fewer blocked nights than the one before it.
///
/// This distinction is the whole safeguard. A feed that shrinks because the
/// owner reopened dates is correct. A feed that shrinks because an import
/// failed, a platform's calendar was unreachable, or the database would not
/// open is a **data loss event wearing the costume of a decision** — and
/// publishing it would put genuinely booked nights back on sale.
public enum FeedReductionCause: Sendable, Hashable, Identifiable {
    /// The owner approved a reopen. Explained and intended.
    case intentionalReopen(decisionIDs: [Int64])
    /// The owner withdrew approval for a block.
    case approvalRevoked(decisionIDs: [Int64])
    /// A source event the feed carried was cancelled by its platform.
    case sourceEventCancelled(eventKeys: [String])
    /// A source event changed and is back under review.
    case sourceEventModified(eventKeys: [String])
    /// An inbound feed has not been read recently enough to be trusted.
    case staleInboundFeed(platforms: [RentalPlatform], hoursOld: Int)
    /// An inbound feed has never been read, or has no URL.
    case missingInboundFeed(platforms: [RentalPlatform])
    /// The last import attempt failed.
    case importFailure(platforms: [RentalPlatform], detail: String)
    /// The database could not be read.
    case databaseFailure(detail: String)
    /// Nothing accounts for it. Treated as the most dangerous case.
    case unexplained

    public var id: String { label }

    /// Whether this cause is a decision the owner made, as opposed to a
    /// malfunction upstream.
    public var isDeliberate: Bool {
        switch self {
        case .intentionalReopen, .approvalRevoked: return true
        default: return false
        }
    }

    /// Whether a reduction attributable to this cause may ever be published
    /// automatically. Only deliberate causes qualify, and even then an
    /// explicit approval is still required for the removal itself.
    public var permitsAutomaticPublication: Bool { isDeliberate }

    public var label: String {
        switch self {
        case .intentionalReopen: return "You reopened these dates"
        case .approvalRevoked: return "You withdrew approval"
        case .sourceEventCancelled: return "A platform cancelled a reservation"
        case .sourceEventModified: return "A source event changed and needs review"
        case .staleInboundFeed: return "An inbound calendar is stale"
        case .missingInboundFeed: return "An inbound calendar is missing"
        case .importFailure: return "An import failed"
        case .databaseFailure: return "The database could not be read"
        case .unexplained: return "Unexplained reduction"
        }
    }

    public var detail: String {
        switch self {
        case .intentionalReopen(let ids):
            return "Approved reopen\(ids.count == 1 ? "" : "s") "
                + ids.map(String.init).joined(separator: ", ") + "."
        case .approvalRevoked(let ids):
            return "Approval withdrawn for decision"
                + "\(ids.count == 1 ? "" : "s") " + ids.map(String.init).joined(separator: ", ")
                + "."
        case .sourceEventCancelled(let keys):
            return "\(keys.count) event\(keys.count == 1 ? "" : "s") "
                + "no longer present in the source calendar. That may be a genuine cancellation "
                + "or a feed problem — this app cannot tell which."
        case .sourceEventModified(let keys):
            return "\(keys.count) event\(keys.count == 1 ? "" : "s") changed and returned to the "
                + "review queue, so they are no longer eligible for publication."
        case .staleInboundFeed(let platforms, let hours):
            return "\(platforms.map(\.displayName).joined(separator: ", ")) last read \(hours)h "
                + "ago. A booking taken since then would not be visible, so removing nights now "
                + "could put a booked night back on sale."
        case .missingInboundFeed(let platforms):
            return "\(platforms.map(\.displayName).joined(separator: ", ")) "
                + "\(platforms.count == 1 ? "has" : "have") never been read successfully."
        case .importFailure(let platforms, let detail):
            return "\(platforms.map(\.displayName).joined(separator: ", ")): \(detail)"
        case .databaseFailure(let detail):
            return detail
        case .unexplained:
            return "The feed is smaller than the last one published and nothing accounts for it. "
                + "Treated as a fault until you say otherwise."
        }
    }
}

/// The verdict on a proposed publication.
public enum PublicationVerdict: String, Sendable {
    /// Nothing is removed, or the only changes are additions.
    case safe
    /// Removals are present and explained. The owner must approve them.
    case requiresRemovalApproval = "requires_removal_approval"
    /// Something upstream failed. Never published, approved or not.
    case refused
}

public struct PublicationSafetyReport: Sendable {
    public var destination: RentalPlatform
    public var diff: FeedDiff
    public var causes: [FeedReductionCause]
    public var verdict: PublicationVerdict
    public var reasons: [String]
    public var lastKnownGood: FeedSnapshot?
    /// Reservations and undecided events the removals would expose.
    public var reservationWarnings: [String] = []

    public var blockingCauses: [FeedReductionCause] {
        causes.filter { !$0.permitsAutomaticPublication }
    }

    public var headline: String {
        switch verdict {
        case .safe:
            return diff.isFirstPublication
                ? "First publication: \(diff.proposedEntryCount) entries."
                : "Safe to publish. \(diff.summary)"
        case .requiresRemovalApproval:
            return "This would put \(diff.removedNights) previously blocked night"
                + "\(diff.removedNights == 1 ? "" : "s") back on sale. Approve the removal first."
        case .refused:
            return "Refused: \(blockingCauses.first?.label ?? "upstream problem"). "
                + "Publishing now could put booked nights back on sale."
        }
    }
}

/// Everything needed to judge whether a reduction is intended.
public struct PublicationContext: Sendable {
    public var listings: [PlatformListing]
    public var recentSyncRuns: [SyncRun]
    public var decisions: [AvailabilityDecision]
    public var sourceEvents: [ClassifiedEvent]
    /// Events that were tombstoned since the last snapshot.
    public var tombstonedEventKeys: Set<String>
    public var now: Date

    public init(
        listings: [PlatformListing],
        recentSyncRuns: [SyncRun],
        decisions: [AvailabilityDecision],
        sourceEvents: [ClassifiedEvent],
        tombstonedEventKeys: Set<String> = [],
        now: Date = Date()
    ) {
        self.listings = listings
        self.recentSyncRuns = recentSyncRuns
        self.decisions = decisions
        self.sourceEvents = sourceEvents
        self.tombstonedEventKeys = tombstonedEventKeys
        self.now = now
    }
}

/// Decides whether a proposed feed may be published.
///
/// The governing rule, stated once: **a feed never shrinks because something
/// broke.** Additions are safe. Removals need the owner. Removals that
/// coincide with an upstream failure are refused outright, because the app
/// cannot distinguish "you reopened these nights" from "we lost sight of a
/// booking" — and the cost of guessing wrong is a double booking.
public struct FeedPublicationSafety: Sendable {

    /// Beyond this, an inbound feed is too old to justify removing anything.
    public static let stalenessThreshold: TimeInterval = 6 * 3_600

    public init() {}

    public func assess(
        proposed: DestinationFeed,
        lastKnownGood: FeedSnapshot?,
        context: PublicationContext
    ) -> PublicationSafetyReport {
        let diff = FeedDiff.between(previous: lastKnownGood, proposed: proposed)
        var causes: [FeedReductionCause] = []
        var reasons: [String] = []

        // Upstream health is assessed whether or not the feed shrank, because
        // a stale calendar makes any removal unsafe.
        causes.append(contentsOf: upstreamProblems(context: context))

        var reservationWarnings: [String] = []
        if diff.removesPublishedDates || diff.wouldEmptyFeed {
            causes.append(contentsOf: explainRemovals(
                removed: diff.removed, proposed: proposed, context: context
            ))
            reservationWarnings = checkRemovalsAgainstBookings(
                removed: diff.removed, context: context
            )
        }

        // --- Verdict ----------------------------------------------------

        // Nothing removed: additions and no-ops are always safe, even if a
        // feed is stale. Adding a block cannot release a booked night.
        guard diff.removesPublishedDates || diff.wouldEmptyFeed else {
            if !causes.isEmpty {
                reasons.append("Upstream problems noted, but nothing is being removed, so "
                    + "publishing cannot release a booked night.")
            }
            return PublicationSafetyReport(
                destination: proposed.destination, diff: diff,
                causes: causes.filter { !$0.isDeliberate }, verdict: .safe,
                reasons: reasons, lastKnownGood: lastKnownGood,
                reservationWarnings: []
            )
        }

        let unsafe = causes.filter { !$0.permitsAutomaticPublication }
        if !unsafe.isEmpty {
            reasons.append("Something upstream is wrong, and the proposed feed removes "
                + "\(diff.removedNights) night\(diff.removedNights == 1 ? "" : "s"). Until the "
                + "cause is understood this app will not publish a smaller feed.")
            for cause in unsafe { reasons.append("\(cause.label): \(cause.detail)") }
            if let good = lastKnownGood {
                reasons.append("The last good feed (revision \(good.revision), "
                    + "\(good.entryCount) entries) stays in place.")
            }
            return PublicationSafetyReport(
                destination: proposed.destination, diff: diff, causes: causes,
                verdict: .refused, reasons: reasons, lastKnownGood: lastKnownGood,
                reservationWarnings: reservationWarnings
            )
        }

        reasons.append("Every removal is accounted for by a decision you made.")
        for cause in causes where cause.isDeliberate {
            reasons.append("\(cause.label): \(cause.detail)")
        }
        reasons.append("Removing published blocks still needs your explicit approval.")
        return PublicationSafetyReport(
            destination: proposed.destination, diff: diff, causes: causes,
            verdict: .requiresRemovalApproval, reasons: reasons, lastKnownGood: lastKnownGood,
            reservationWarnings: reservationWarnings
        )
    }

    // MARK: - Upstream health

    private func upstreamProblems(context: PublicationContext) -> [FeedReductionCause] {
        var causes: [FeedReductionCause] = []

        var stale: [RentalPlatform] = []
        var staleHours = 0
        var missing: [RentalPlatform] = []
        for listing in context.listings {
            guard let last = listing.lastSyncAt else {
                missing.append(listing.platform)
                continue
            }
            let age = context.now.timeIntervalSince(last)
            if age > Self.stalenessThreshold {
                stale.append(listing.platform)
                staleHours = max(staleHours, Int(age / 3_600))
            }
        }
        if !missing.isEmpty { causes.append(.missingInboundFeed(platforms: missing)) }
        if !stale.isEmpty {
            causes.append(.staleInboundFeed(platforms: stale, hoursOld: staleHours))
        }

        // The most recent run per listing; a failure there means the picture
        // may be incomplete.
        var latestByListing: [Int64: SyncRun] = [:]
        for run in context.recentSyncRuns {
            if let existing = latestByListing[run.listingID],
               existing.startedAt >= run.startedAt { continue }
            latestByListing[run.listingID] = run
        }
        let failures = latestByListing.values.filter { $0.outcome == .failure }
        if !failures.isEmpty {
            let platforms = failures.compactMap { run in
                context.listings.first { $0.id == run.listingID }?.platform
            }
            causes.append(.importFailure(
                platforms: platforms.isEmpty ? [.other] : platforms,
                detail: failures.first?.errorMessage ?? "the last import did not complete"
            ))
        }

        return causes
    }

    // MARK: - What the removals would expose

    /// Nights about to go back on sale are checked against what is actually
    /// known to occupy them. A removal over an undecided event is the sharp
    /// case: the event might be a real booking nobody has confirmed yet.
    private func checkRemovalsAgainstBookings(
        removed: [SnapshotEntry], context: PublicationContext
    ) -> [String] {
        var warnings: [String] = []
        for entry in removed {
            let overlapping = context.sourceEvents.filter {
                $0.event.isActive
                    && $0.event.checkIn < entry.endDay && entry.startDay < $0.event.checkOut
            }
            let confirmed = overlapping.filter {
                $0.classification.kind == .confirmedReservation && !$0.classification.needsReview
            }
            let undecided = overlapping.filter { $0.classification.needsReview }

            if !confirmed.isEmpty {
                warnings.append(
                    "\(entry.rangeDescription): a confirmed reservation covers part of these "
                        + "nights. Removing our block does not cancel it — the reservation keeps "
                        + "them blocked — but check that is what you expect."
                )
            }
            if !undecided.isEmpty {
                warnings.append(
                    "\(entry.rangeDescription): \(undecided.count) undecided event"
                        + "\(undecided.count == 1 ? "" : "s") overlap these nights. If any is a "
                        + "real booking, putting them back on sale risks a double booking. "
                        + "Decide them first."
                )
            }
        }
        return warnings
    }

    // MARK: - Explaining removals

    private func explainRemovals(
        removed: [SnapshotEntry],
        proposed: DestinationFeed,
        context: PublicationContext
    ) -> [FeedReductionCause] {
        var causes: [FeedReductionCause] = []
        var accountedFor = Set<String>()

        // A removal matching an approved reopen, or a withdrawn approval, is
        // deliberate. Matching is by the entry UID the decision would produce.
        var reopenIDs: [Int64] = []
        var revokedIDs: [Int64] = []
        for decision in context.decisions
        where decision.destination == proposed.destination {
            guard removed.contains(where: { $0.uid == decision.publicationUID }) else { continue }
            if decision.action == .unblock, decision.status.contributesToFeed {
                reopenIDs.append(decision.id ?? 0)
                accountedFor.insert(decision.publicationUID)
            } else if decision.action == .block,
                      decision.status == .cancelled || !decision.status.contributesToFeed {
                revokedIDs.append(decision.id ?? 0)
                accountedFor.insert(decision.publicationUID)
            }
        }
        if !reopenIDs.isEmpty { causes.append(.intentionalReopen(decisionIDs: reopenIDs)) }
        if !revokedIDs.isEmpty { causes.append(.approvalRevoked(decisionIDs: revokedIDs)) }

        // Removals traceable to a source event that vanished or changed.
        let cancelledKeys = context.tombstonedEventKeys
        if !cancelledKeys.isEmpty {
            causes.append(.sourceEventCancelled(eventKeys: Array(cancelledKeys)))
        }
        let reReviewed = context.sourceEvents
            .filter { $0.classification.needsReview && $0.classification.source == .manual }
            .map(\.event.eventKey)
        if !reReviewed.isEmpty {
            causes.append(.sourceEventModified(eventKeys: reReviewed))
        }

        // Anything left unexplained is the dangerous case.
        let unexplained = removed.filter { !accountedFor.contains($0.uid) }
        if !unexplained.isEmpty && causes.allSatisfy(\.isDeliberate) && cancelledKeys.isEmpty
            && reReviewed.isEmpty {
            causes.append(.unexplained)
        }

        return causes
    }
}
