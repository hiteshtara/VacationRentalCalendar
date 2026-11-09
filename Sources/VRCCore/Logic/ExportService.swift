import Foundation

public struct ExportLineItem: Identifiable, Sendable {
    public var event: CalendarEvent
    public var classification: EventClassification
    public var decision: ExportDecision
    public var propertyName: String
    public var listingLabel: String

    public var id: String { event.eventKey }
    public var isIncluded: Bool { decision.isIncluded }
}

public struct ExportPlan: Sendable {
    public var propertyID: Int64
    public var propertyName: String
    public var destination: RentalPlatform?
    public var items: [ExportLineItem]
    public var generatedAt: Date

    public var included: [ExportLineItem] { items.filter(\.isIncluded) }
    public var excluded: [ExportLineItem] { items.filter { !$0.isIncluded } }

    public var includedNights: Int { included.reduce(0) { $0 + $1.event.nights } }
    public var excludedNights: Int { excluded.reduce(0) { $0 + $1.event.nights } }

    /// The number the owner actually cares about: nights kept sellable because
    /// the app refused to propagate an unverified block.
    public var protectedNights: Int {
        excluded
            .filter {
                $0.classification.kind == .cancellationBlock
                    || $0.classification.kind == .unknownUnavailable
                    || $0.classification.needsReview
            }
            .reduce(0) { $0 + $1.event.nights }
    }

    public var calendarName: String {
        let suffix = destination.map { " → \($0.displayName)" } ?? ""
        return "\(propertyName) availability\(suffix)"
    }
}

/// Produces filtered outbound calendars.
///
/// Writes files to the Mac only. Nothing here contacts a platform; see
/// `OutboundSyncGate`.
public struct ExportService: Sendable {
    let policy: ExportPolicy
    let writer: ICalWriter

    public init(policy: ExportPolicy = ExportPolicy(), writer: ICalWriter = ICalWriter()) {
        self.policy = policy
        self.writer = writer
    }

    public func plan(
        propertyID: Int64,
        propertyName: String,
        events: [ClassifiedEvent],
        destination: RentalPlatform?,
        horizonDays: Int? = nil,
        now: Date = Date()
    ) -> ExportPlan {
        let horizonCutoff = horizonDays.map { DayMath.adding(days: $0, to: now) }

        let items = events
            .filter { $0.propertyID == propertyID }
            .filter { item in
                guard let cutoff = horizonCutoff else { return true }
                return item.event.checkIn < cutoff
            }
            .map { item in
                ExportLineItem(
                    event: item.event,
                    classification: item.classification,
                    decision: policy.decide(
                        event: item.event,
                        classification: item.classification,
                        destination: destination
                    ),
                    propertyName: item.propertyName,
                    listingLabel: item.listingLabel
                )
            }
            .sorted { $0.event.checkIn < $1.event.checkIn }

        return ExportPlan(
            propertyID: propertyID,
            propertyName: propertyName,
            destination: destination,
            items: items,
            generatedAt: now
        )
    }

    /// Generic summary text. Deliberately says nothing about who is staying.
    public func summary(for item: ExportLineItem) -> String {
        item.classification.kind == .confirmedReservation ? "Reserved" : "Not available"
    }

    public func makeICS(from plan: ExportPlan) -> String {
        let entries = plan.included.map { item in
            ICalWriter.ExportEntry(
                sourceEventKey: item.event.eventKey,
                checkIn: item.event.checkIn,
                checkOut: item.event.checkOut,
                summary: summary(for: item),
                isAllDay: item.event.isAllDay
            )
        }
        return writer.makeCalendar(
            name: plan.calendarName, entries: entries, generatedAt: plan.generatedAt
        )
    }

    @discardableResult
    public func write(plan: ExportPlan, to url: URL) throws -> URL {
        let text = makeICS(from: plan)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url, options: [.atomic])
        return url
    }

    /// Plain-language audit of what was left out and why, so the owner can see
    /// the protection working rather than taking it on faith.
    public func auditText(for plan: ExportPlan) -> String {
        var lines: [String] = []
        lines.append("Filtered export — \(plan.calendarName)")
        lines.append("Generated \(DayMath.mediumString(plan.generatedAt))")
        lines.append("")
        lines.append("INCLUDED (\(plan.included.count) events, \(plan.includedNights) nights)")
        if plan.included.isEmpty { lines.append("  (nothing)") }
        for item in plan.included {
            lines.append("  \(DayMath.icalDateString(item.event.checkIn))"
                + "–\(DayMath.icalDateString(item.event.checkOut))"
                + "  \(item.event.platform.shortTag)"
                + "  \(item.classification.kind.displayName)"
                + "  — \(item.decision.reason)")
        }
        lines.append("")
        lines.append("EXCLUDED (\(plan.excluded.count) events, \(plan.excludedNights) nights)")
        if plan.excluded.isEmpty { lines.append("  (nothing)") }
        for item in plan.excluded {
            lines.append("  \(DayMath.icalDateString(item.event.checkIn))"
                + "–\(DayMath.icalDateString(item.event.checkOut))"
                + "  \(item.event.platform.shortTag)"
                + "  \(item.classification.kind.displayName)"
                + "  — \(item.decision.reason)")
        }
        lines.append("")
        lines.append("\(plan.protectedNights) nights stayed sellable because this app refused to "
            + "share an unverified block.")
        return lines.joined(separator: "\n")
    }
}
