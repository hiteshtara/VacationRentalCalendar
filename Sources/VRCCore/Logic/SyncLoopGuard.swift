import Foundation

/// Stops a block we published coming back to us and going round again.
///
/// This is not hypothetical here. Booking.com's calendar is **already
/// connected directly** to Airbnb and Vrbo, so the same reservation can reach
/// a platform twice: once by that direct subscription, once by anything we
/// publish. And a platform that imports an external block generally
/// re-exports it in its own calendar — so on the next import we would see a
/// block on Airbnb that is really our own Booking.com reservation wearing a
/// different hat, and could publish it onward to Vrbo. That is a loop, and
/// each lap makes the dates look more independently confirmed than they are.
///
/// Three rules, each checkable without asking a platform anything:
///
/// 1. **Never republish our own publication.** Our outbound UIDs are derived
///    and carry a domain nothing else uses, so they are recognisable when
///    they come back.
/// 2. **Never publish back to the platform an event came from.** Already
///    enforced by `OutboundPolicy`, restated here because the loop case makes
///    it load-bearing rather than merely tidy.
/// 3. **Never publish something a direct connection already delivers.**
///    Duplicate blocks are not harmful to availability, but they make
///    attribution ambiguous and withdrawal dangerous: removing one while the
///    other stands leaves the dates looking protected when they are not.
public enum SyncLoopGuard {

    public enum Verdict: Sendable, Equatable {
        case publish
        /// It is ours, come back around.
        case skipOwnPublication(uid: String)
        /// The destination already receives this by a direct platform link.
        case skipDirectConnection(RentalPlatform)
        /// Back to where it came from.
        case skipSameSource
    }

    /// Whether a UID is one this app emitted.
    ///
    /// The domain is ours alone, so a round-tripped block identifies itself
    /// without needing a database to remember it.
    public static func isOurPublication(uid: String) -> Bool {
        uid.hasSuffix("@\(ICalWriter.uidDomain)")
    }

    /// Whether an imported event is one of ours that a platform re-exported.
    public static func isEchoOfOurs(_ item: ClassifiedEvent) -> Bool {
        isOurPublication(uid: item.event.uid)
    }

    /// A direct platform-to-platform subscription the owner has configured.
    public struct DirectConnection: Sendable, Equatable, Hashable {
        public let source: RentalPlatform
        public let destination: RentalPlatform
        public init(source: RentalPlatform, destination: RentalPlatform) {
            self.source = source
            self.destination = destination
        }
    }

    public static func verdict(
        for item: ClassifiedEvent,
        destination: RentalPlatform,
        directConnections: Set<DirectConnection>
    ) -> Verdict {
        if isEchoOfOurs(item) {
            return .skipOwnPublication(uid: item.event.uid)
        }
        if item.event.platform == destination {
            return .skipSameSource
        }
        let direct = DirectConnection(source: item.event.platform, destination: destination)
        if directConnections.contains(direct) {
            return .skipDirectConnection(item.event.platform)
        }
        return .publish
    }

    /// Filters a set of source events down to what is safe to publish to one
    /// destination, with a reason for everything dropped.
    public static func publishable(
        _ items: [ClassifiedEvent],
        to destination: RentalPlatform,
        directConnections: Set<DirectConnection>
    ) -> (publish: [ClassifiedEvent], skipped: [(ClassifiedEvent, Verdict)]) {
        var publish: [ClassifiedEvent] = []
        var skipped: [(ClassifiedEvent, Verdict)] = []
        for item in items {
            let verdict = verdict(for: item, destination: destination,
                                  directConnections: directConnections)
            if verdict == .publish { publish.append(item) } else { skipped.append((item, verdict)) }
        }
        return (publish, skipped)
    }

    /// An imported event that is an echo of our own publication must never be
    /// treated as independent evidence of anything — not as a reservation, not
    /// as corroboration that a platform is holding dates for its own reasons.
    public static func shouldClassifyAsIndependentObservation(
        _ item: ClassifiedEvent
    ) -> Bool {
        !isEchoOfOurs(item)
    }
}
