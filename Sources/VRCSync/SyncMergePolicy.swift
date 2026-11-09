import Foundation
import VRCCore

/// What a merge decided, and why — kept so the owner can be shown it rather
/// than having a silent winner picked for them.
public struct MergeOutcome<T>: Sendable where T: Sendable {
    public enum Resolution: String, Sendable {
        case localWins
        case remoteWins
        case identical
        /// The two sides disagreed about something that matters, so the safe
        /// option was taken and the owner is asked to look.
        case escalatedToReview
    }

    public var value: T
    public var resolution: Resolution
    public var explanation: String

    public init(value: T, resolution: Resolution, explanation: String) {
        self.value = value
        self.resolution = resolution
        self.explanation = explanation
    }
}

/// How two devices reconcile a disagreement.
///
/// Plain last-writer-wins is not good enough here, because the thing being
/// merged decides whether nights get blocked on another platform. Three rules
/// sit on top of it:
///
/// 1. **A human decision always beats an automatic one**, regardless of
///    timestamps. An import on the Mac must never overwrite a classification
///    made by hand on the phone.
/// 2. **If two human decisions disagree about what a block *is*, nobody wins.**
///    Export approval is withdrawn and the item goes back to the review queue.
///    Two devices contradicting each other is exactly when the app should stop
///    and ask rather than guess.
/// 3. **Export approval never merges upward.** It can be withdrawn by a merge;
///    it can never be granted by one.
///
/// The rules are deterministic and symmetric, so two devices merging the same
/// pair independently reach the same answer without talking to each other.
public struct SyncMergePolicy: Sendable {
    public init() {}

    public func merge(
        local: EventClassification,
        remote: EventClassification,
        localDeviceID: String,
        remoteDeviceID: String
    ) -> MergeOutcome<EventClassification> {

        if local == remote {
            return MergeOutcome(value: local, resolution: .identical,
                                explanation: "Both devices already agreed.")
        }

        // Rule 1 — a human decision outranks an automatic one.
        switch (local.source, remote.source) {
        case (.manual, .automatic):
            return MergeOutcome(
                value: local, resolution: .localWins,
                explanation: "This device's own decision was kept; the other copy was only "
                    + "auto-detected."
            )
        case (.automatic, .manual):
            return MergeOutcome(
                value: remote, resolution: .remoteWins,
                explanation: "A decision you made on another device was kept in preference to "
                    + "this one's automatic guess."
            )
        default:
            break
        }

        // Both automatic: newest wins, nothing is at stake because neither is
        // exportable anyway.
        if local.source == .automatic {
            let newer = local.decidedAt >= remote.decidedAt ? local : remote
            return MergeOutcome(
                value: newer,
                resolution: newer == local ? .localWins : .remoteWins,
                explanation: "Both were auto-detected, so the more recent import was kept."
            )
        }

        // Both manual.
        if local.kind != remote.kind {
            // Rule 2 — a genuine disagreement about what this is. Take the more
            // recent kind for display, but withdraw approval and ask.
            let newer = pickNewer(local, remote, localDeviceID, remoteDeviceID)
            var safe = newer
            safe.needsReview = true
            safe.exportApproved = false
            safe.rationale = "Two of your devices classified this differently — "
                + "\(describe(local)) here, \(describe(remote)) on the other. It is not shared "
                + "with any platform until you confirm which is right."
            return MergeOutcome(
                value: safe, resolution: .escalatedToReview,
                explanation: safe.rationale
            )
        }

        // Both manual and they agree on the kind. Newest wins, but approval is
        // only kept if both sides had granted it (rule 3).
        var winner = pickNewer(local, remote, localDeviceID, remoteDeviceID)
        winner.exportApproved = local.exportApproved && remote.exportApproved
        winner.exportSuppressed = local.exportSuppressed || remote.exportSuppressed
        return MergeOutcome(
            value: winner,
            resolution: winner.decidedAt == local.decidedAt ? .localWins : .remoteWins,
            explanation: "Both devices agreed on the classification; the more recent edit was kept."
                + (winner.exportApproved ? "" : " Sharing stays off until you approve it again.")
        )
    }

    /// Deterministic even when the timestamps are identical, so two devices
    /// merging independently cannot diverge.
    private func pickNewer(
        _ local: EventClassification, _ remote: EventClassification,
        _ localDeviceID: String, _ remoteDeviceID: String
    ) -> EventClassification {
        if local.decidedAt != remote.decidedAt {
            return local.decidedAt > remote.decidedAt ? local : remote
        }
        return localDeviceID <= remoteDeviceID ? local : remote
    }

    private func describe(_ classification: EventClassification) -> String {
        classification.kind.displayName.lowercased()
    }

    // MARK: - Plain records

    /// Properties and listings are ordinary editable records with nothing
    /// safety-critical attached, so last-writer-wins is appropriate.
    public func mergeProperty(
        local: Property, remote: Property, localModified: Date, remoteModified: Date
    ) -> MergeOutcome<Property> {
        if localModified >= remoteModified {
            return MergeOutcome(value: local, resolution: .localWins,
                                explanation: "This device had the more recent edit.")
        }
        return MergeOutcome(value: remote, resolution: .remoteWins,
                            explanation: "Another device had the more recent edit.")
    }

    /// Events come from the platforms, so whichever device imported most
    /// recently has the better copy. Nothing a human typed is at stake.
    public func mergeEvent(local: CalendarEvent, remote: CalendarEvent) -> MergeOutcome<CalendarEvent> {
        if local.contentHash == remote.contentHash {
            // Same content: keep the one that has seen the feed most recently.
            let newer = local.lastSeenAt >= remote.lastSeenAt ? local : remote
            return MergeOutcome(value: newer, resolution: .identical,
                                explanation: "Both devices imported the same event.")
        }
        let newer = local.lastSeenAt >= remote.lastSeenAt ? local : remote
        return MergeOutcome(
            value: newer,
            resolution: newer.eventKey == local.eventKey && newer.lastSeenAt == local.lastSeenAt
                ? .localWins : .remoteWins,
            explanation: "Kept the copy from the more recent import."
        )
    }
}
