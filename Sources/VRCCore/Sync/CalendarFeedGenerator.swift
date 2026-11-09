import Foundation

/// Why an entry is in, or out of, a destination feed.
public struct FeedEntryDecision: Identifiable, Sendable {
    public enum Origin: String, Sendable {
        /// Came from another platform's imported calendar.
        case sourceEvent
        /// Created here by an availability decision.
        case availabilityDecision
    }

    public var origin: Origin
    public var uid: String
    public var startDay: Date
    public var endDay: Date
    public var summary: String
    public var included: Bool
    public var reason: String
    public var sourceEventKey: String?
    public var decisionID: Int64?
    public var platform: RentalPlatform?

    public var id: String { uid }
    public var nights: Int { max(1, DayMath.daysBetween(startDay, endDay)) }
}

public struct DestinationFeed: Sendable {
    public var destination: RentalPlatform
    public var propertyID: Int64
    public var propertyName: String
    public var entries: [FeedEntryDecision]
    public var generatedAt: Date
    public var revision: Int

    public var included: [FeedEntryDecision] { entries.filter(\.included) }
    public var excluded: [FeedEntryDecision] { entries.filter { !$0.included } }
    public var includedNights: Int { included.reduce(0) { $0 + $1.nights } }

    /// Nights held back because they were unverified, unknown, or a
    /// cancellation block — the inventory this app is protecting.
    public var protectedNights: Int {
        excluded
            .filter { $0.origin == .sourceEvent && $0.reason.contains("never") || $0.reason.contains("review") }
            .reduce(0) { $0 + $1.nights }
    }

    public var calendarName: String {
        "\(propertyName) → \(destination.displayName)"
    }
}

/// Builds one destination's filtered calendar.
///
/// Three streams feed into it, and they stay distinguishable all the way
/// through: **source events** imported from other platforms, **availability
/// decisions** the owner approved here, and the **published entries** that
/// result. A source event is never rewritten to express a decision.
public struct CalendarFeedGenerator: Sendable {
    let policy: ExportPolicy
    let writer: ICalWriter

    public init(policy: ExportPolicy = ExportPolicy(), writer: ICalWriter = ICalWriter()) {
        self.policy = policy
        self.writer = writer
    }

    /// Marks entries this application produced, so they can be recognised if
    /// they ever come back to us through a platform's own export.
    public static let ownUIDMarker = "vrc-"

    public func generate(
        destination: RentalPlatform,
        propertyID: Int64,
        propertyName: String,
        sourceEvents: [ClassifiedEvent],
        decisions: [AvailabilityDecision],
        revision: Int = 1,
        now: Date = Date()
    ) -> DestinationFeed {
        var entries: [FeedEntryDecision] = []

        // --- Stream 1: source events from other platforms -------------------

        for item in sourceEvents where item.propertyID == propertyID {
            let event = item.event

            // Circular-import guard. If the owner subscribed a platform to one
            // of our feeds, that platform's export will contain our own blocks.
            // Publishing them onward would make a block immortal — it could
            // never be withdrawn, because each platform would keep feeding it
            // back. So anything bearing our marker is dropped on sight.
            if event.uid.contains(Self.ownUIDMarker)
                || event.uid.contains(ICalWriter.uidDomain) {
                entries.append(FeedEntryDecision(
                    origin: .sourceEvent, uid: event.uid,
                    startDay: event.checkIn, endDay: event.checkOut,
                    summary: event.summary, included: false,
                    reason: "This came from one of our own published feeds. Republishing it "
                        + "would create a loop that could never be undone.",
                    sourceEventKey: event.eventKey, platform: event.platform
                ))
                continue
            }

            let verdict = policy.decide(
                event: event, classification: item.classification, destination: destination
            )
            entries.append(FeedEntryDecision(
                origin: .sourceEvent,
                uid: stableUID(forSourceKey: event.eventKey, destination: destination),
                startDay: event.checkIn,
                endDay: event.checkOut,
                summary: verdict.isIncluded ? summaryForSource(item) : event.summary,
                included: verdict.isIncluded,
                reason: verdict.reason,
                sourceEventKey: event.eventKey,
                platform: event.platform
            ))
        }

        // --- Stream 2: the owner's own availability decisions ---------------

        for decision in decisions
        where decision.propertyID == propertyID && decision.destination == destination {
            switch decision.action {
            case .leaveUnchanged:
                entries.append(FeedEntryDecision(
                    origin: .availabilityDecision, uid: decision.publicationUID,
                    startDay: decision.startDay, endDay: decision.endDay,
                    summary: "Not available", included: false,
                    reason: "You chose to leave \(destination.displayName) unchanged.",
                    decisionID: decision.id, platform: destination
                ))

            case .unblock:
                // Reopening is the absence of an entry, not the presence of
                // one. Recorded so the audit shows it was considered.
                entries.append(FeedEntryDecision(
                    origin: .availabilityDecision, uid: decision.publicationUID,
                    startDay: decision.startDay, endDay: decision.endDay,
                    summary: "Not available", included: false,
                    reason: decision.status.contributesToFeed
                        ? "Reopened: our block is withdrawn by leaving these nights out of the "
                            + "feed. Only blocks this app created are affected."
                        : "Reopen requested but not yet approved.",
                    decisionID: decision.id, platform: destination
                ))

            case .block:
                let eligible = decision.status.contributesToFeed
                entries.append(FeedEntryDecision(
                    origin: .availabilityDecision,
                    uid: decision.publicationUID,
                    startDay: decision.startDay,
                    endDay: decision.endDay,
                    summary: "Not available",
                    included: eligible,
                    reason: eligible
                        ? "You approved this block on \(DayMath.mediumString(decision.approvedAt ?? decision.updatedAt))."
                        : "Not approved yet (\(decision.status.displayName.lowercased())), so it "
                            + "is not published.",
                    decisionID: decision.id,
                    platform: destination
                ))
            }
        }

        return DestinationFeed(
            destination: destination,
            propertyID: propertyID,
            propertyName: propertyName,
            entries: entries.sorted { $0.startDay < $1.startDay },
            generatedAt: now,
            revision: revision
        )
    }

    /// Generic by design. An outbound feed's only job is to say which nights
    /// are taken; a guest's name adds nothing and leaks something.
    private func summaryForSource(_ item: ClassifiedEvent) -> String {
        item.classification.kind == .confirmedReservation ? "Reserved" : "Not available"
    }

    /// Stable across regeneration and distinct per destination, so one
    /// platform cannot correlate its feed against another's.
    public func stableUID(forSourceKey key: String, destination: RentalPlatform) -> String {
        Self.ownUIDMarker + EventKey.sha256("\(destination.rawValue)\u{1F}\(key)").prefix(32)
    }

    public func makeICS(_ feed: DestinationFeed) -> String {
        let entries = feed.included.map { entry in
            ICalWriter.ExportEntry(
                sourceEventKey: entry.uid,
                checkIn: entry.startDay,
                checkOut: entry.endDay,
                summary: entry.summary,
                isAllDay: true
            )
        }
        return writer.makeCalendar(
            name: feed.calendarName, entries: entries, generatedAt: feed.generatedAt
        )
    }

    /// Plain-language account of what went in and what did not.
    public func auditText(_ feed: DestinationFeed) -> String {
        var lines = [
            "Feed for \(feed.destination.displayName) — \(feed.propertyName)",
            "Revision \(feed.revision), generated \(DayMath.mediumString(feed.generatedAt))",
            "",
            "INCLUDED (\(feed.included.count) entries, \(feed.includedNights) nights)",
        ]
        if feed.included.isEmpty { lines.append("  (nothing)") }
        for entry in feed.included {
            lines.append("  \(DayMath.icalDateString(entry.startDay))"
                + "–\(DayMath.icalDateString(entry.endDay))"
                + "  \(entry.origin == .availabilityDecision ? "your block" : "source")"
                + "  — \(entry.reason)")
        }
        lines.append("")
        lines.append("HELD BACK (\(feed.excluded.count))")
        for entry in feed.excluded {
            lines.append("  \(DayMath.icalDateString(entry.startDay))"
                + "–\(DayMath.icalDateString(entry.endDay))  — \(entry.reason)")
        }
        return lines.joined(separator: "\n")
    }
}
