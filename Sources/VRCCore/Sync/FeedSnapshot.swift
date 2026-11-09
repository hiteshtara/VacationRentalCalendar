import Foundation

/// One entry as it was actually served, kept so a later proposal can be
/// compared against it line by line.
public struct SnapshotEntry: Hashable, Sendable, Identifiable {
    public var uid: String
    public var startDay: Date
    public var endDay: Date
    public var summary: String

    public var id: String { uid }
    public var nights: Int { max(1, DayMath.daysBetween(startDay, endDay)) }

    public init(uid: String, startDay: Date, endDay: Date, summary: String) {
        self.uid = uid
        self.startDay = startDay
        self.endDay = endDay
        self.summary = summary
    }

    public var rangeDescription: String {
        "\(DayMath.mediumString(startDay)) – \(DayMath.mediumString(endDay))"
    }
}

/// A complete record of a feed that was served, including the bytes.
///
/// Exists so the question "did this feed get smaller, and if so why?" can be
/// answered from evidence rather than inferred. Without it, an import failure
/// that produced an empty feed is indistinguishable from the owner genuinely
/// reopening everything.
public struct FeedSnapshot: Identifiable, Sendable {
    public var id: Int64?
    public var propertyID: Int64
    public var destination: RentalPlatform
    public var revision: Int
    public var generatedAt: Date
    public var publishedAt: Date?
    public var checksum: String
    public var entries: [SnapshotEntry]
    public var payload: String
    public var isLastKnownGood: Bool

    public var entryCount: Int { entries.count }
    public var coveredNights: Int { entries.reduce(0) { $0 + $1.nights } }

    public init(
        id: Int64? = nil,
        propertyID: Int64,
        destination: RentalPlatform,
        revision: Int,
        generatedAt: Date = Date(),
        publishedAt: Date? = nil,
        checksum: String = "",
        entries: [SnapshotEntry] = [],
        payload: String = "",
        isLastKnownGood: Bool = false
    ) {
        self.id = id
        self.propertyID = propertyID
        self.destination = destination
        self.revision = revision
        self.generatedAt = generatedAt
        self.publishedAt = publishedAt
        self.checksum = checksum
        self.entries = entries
        self.payload = payload
        self.isLastKnownGood = isLastKnownGood
    }
}

/// What a proposed publication would change about a destination's feed.
public struct FeedDiff: Sendable {
    public var added: [SnapshotEntry]
    public var removed: [SnapshotEntry]
    public var unchangedCount: Int
    public var previousEntryCount: Int
    public var proposedEntryCount: Int
    public var previousNights: Int
    public var proposedNights: Int

    public var removedNights: Int { removed.reduce(0) { $0 + $1.nights } }
    public var addedNights: Int { added.reduce(0) { $0 + $1.nights } }

    /// Any previously published blocked dates would stop being blocked.
    public var removesPublishedDates: Bool { !removed.isEmpty }

    /// The feed would go from having entries to having none.
    public var wouldEmptyFeed: Bool { previousEntryCount > 0 && proposedEntryCount == 0 }

    /// Fewer blocked nights than before, by any amount.
    public var isReduced: Bool { proposedNights < previousNights }

    public var isFirstPublication: Bool { previousEntryCount == 0 && previousNights == 0 }

    public var summary: String {
        if isFirstPublication { return "First publication: \(proposedEntryCount) entries." }
        if added.isEmpty && removed.isEmpty { return "No change." }
        var parts: [String] = []
        if !added.isEmpty { parts.append("+\(added.count) (\(addedNights) nights)") }
        if !removed.isEmpty { parts.append("−\(removed.count) (\(removedNights) nights)") }
        return parts.joined(separator: ", ")
    }

    public static func between(
        previous: FeedSnapshot?, proposed: DestinationFeed
    ) -> FeedDiff {
        let proposedEntries = proposed.included.map {
            SnapshotEntry(uid: $0.uid, startDay: $0.startDay, endDay: $0.endDay, summary: $0.summary)
        }
        let previousEntries = previous?.entries ?? []
        let previousByUID = Dictionary(
            previousEntries.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let proposedByUID = Dictionary(
            proposedEntries.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first }
        )

        let added = proposedEntries.filter { previousByUID[$0.uid] == nil }
        let removed = previousEntries.filter { proposedByUID[$0.uid] == nil }
        let unchanged = proposedEntries.filter { entry in
            previousByUID[entry.uid].map {
                $0.startDay == entry.startDay && $0.endDay == entry.endDay
            } ?? false
        }.count

        return FeedDiff(
            added: added,
            removed: removed,
            unchangedCount: unchanged,
            previousEntryCount: previousEntries.count,
            proposedEntryCount: proposedEntries.count,
            previousNights: previousEntries.reduce(0) { $0 + $1.nights },
            proposedNights: proposedEntries.reduce(0) { $0 + $1.nights }
        )
    }

    /// Line-by-line account for the approval screen.
    public func describe() -> [String] {
        var lines: [String] = []
        for entry in removed {
            lines.append("REMOVE  \(entry.rangeDescription)  (\(entry.nights) nights) — these "
                + "nights would go back on sale")
        }
        for entry in added {
            lines.append("ADD     \(entry.rangeDescription)  (\(entry.nights) nights)")
        }
        if lines.isEmpty { lines.append("No change to what is published.") }
        return lines
    }
}
