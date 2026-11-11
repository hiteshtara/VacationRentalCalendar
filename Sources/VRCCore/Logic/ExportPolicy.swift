import Foundation

public enum ExportDecision: Sendable, Equatable {
    case include(reason: String)
    case exclude(reason: String)

    public var isIncluded: Bool {
        if case .include = self { return true }
        return false
    }

    public var reason: String {
        switch self {
        case .include(let reason), .exclude(let reason): return reason
        }
    }
}

/// The gate every date must pass to appear in an outbound feed.
///
/// This is deliberately a separate layer that re-checks the rule from scratch
/// rather than trusting a stored "exportable" flag. The flag could be wrong; the
/// rule cannot be, because it is the only place that decides.
///
/// Four exclusions are absolute and have no override anywhere in the app:
/// cancellation blocks, unknown blocks, anything still awaiting review, and
/// anything the owner suppressed.
public struct ExportPolicy: Sendable {
    public init() {}

    /// - Parameter destination: the platform the feed is being produced for.
    ///   Events that came from that same platform are left out, since it already
    ///   knows its own calendar and re-importing them invites a feedback loop.
    public func decide(
        event: CalendarEvent,
        classification: EventClassification,
        destination: RentalPlatform? = nil
    ) -> ExportDecision {

        if event.isTombstoned {
            return .exclude(reason: "No longer present in the source calendar.")
        }
        if event.feedStatus == .cancelled {
            return .exclude(reason: "The source calendar marked this event cancelled.")
        }

        // --- Absolute exclusions. Nothing below may override these. ---

        if classification.exportSuppressed {
            return .exclude(reason: "You excluded this one by hand.")
        }
        if classification.kind == .cancellationBlock {
            return .exclude(
                reason: "Cancellation blocks are never exported. These dates are not booked, so "
                    + "they stay sellable on your other platforms."
            )
        }
        if classification.kind == .unknownUnavailable {
            return .exclude(
                reason: "The reason for these dates being unavailable is unknown, so exporting "
                    + "them could block dates you could still sell."
            )
        }
        if classification.kind == .platformRestriction {
            return .exclude(
                reason: "\(event.platform.displayName) will not take bookings for these dates, "
                    + "but that is its limit and not the property's. Every platform sets its own "
                    + "booking window, so this is never copied elsewhere."
            )
        }
        if classification.needsReview {
            return .exclude(reason: "Waiting for your review.")
        }

        // --- Destination filtering ---

        if let destination, event.platform == destination {
            return .exclude(
                reason: "\(destination.displayName) is the source of this event and already has it."
            )
        }

        // --- Positive inclusion ---

        switch classification.kind {
        case .confirmedReservation:
            if classification.source == .manual {
                return .include(reason: "You confirmed this is a real reservation.")
            }
            if classification.confidence == .high {
                return .include(
                    reason: "\(event.platform.displayName) supplied booking-specific evidence for "
                        + "these dates."
                )
            }
            return .exclude(
                reason: "Looks like a reservation but was not confirmed with high confidence."
            )

        case .ownerBlock, .maintenanceBlock:
            guard classification.source == .manual else {
                return .exclude(
                    reason: "Blocks are only exported after you classify them yourself. This one "
                        + "was auto-detected."
                )
            }
            guard classification.exportApproved else {
                return .exclude(
                    reason: "You classified this as a \(classification.kind.displayName.lowercased()) "
                        + "but have not approved it for export yet."
                )
            }
            return .include(
                reason: "You classified and approved this \(classification.kind.displayName.lowercased())."
            )

        case .cancellationBlock, .platformRestriction, .unknownUnavailable:
            // Already handled above; kept exhaustive so a new kind cannot slip
            // through by default.
            return .exclude(reason: "Not eligible for export.")
        }
    }
}

/// The outbound kill switch.
///
/// Phase 4 of this project is research only: no code anywhere writes to a
/// platform's availability, and this gate exists so that fact is checkable in
/// one place rather than argued about. Producing a filtered .ics file for the
/// owner to inspect is not outbound synchronisation and is always allowed.
public enum OutboundSyncGate {
    /// Hard-coded. Changing a setting in the UI cannot flip this.
    public static let isEnabled = false

    public static let explanation = """
    Outbound synchronisation is disabled in this build. The app reads platform \
    calendars and writes filtered .ics files to your Mac. It never contacts a \
    platform to change availability, and there is no code path that could.
    """
}
