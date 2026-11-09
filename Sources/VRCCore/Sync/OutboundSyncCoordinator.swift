import Foundation

/// The state of one destination's outbound feed.
public struct DestinationSyncState: Identifiable, Sendable {
    public var destination: RentalPlatform
    public var propertyID: Int64
    public var approvedCount: Int
    public var publishedCount: Int
    public var awaitingRefreshCount: Int
    public var verifiedCount: Int
    public var lastGeneratedAt: Date?
    public var lastPublishedAt: Date?
    public var capability: PlatformCapability

    public var id: String { "\(propertyID)-\(destination.rawValue)" }

    /// The honest headline. Never claims a platform has synchronised.
    public var headline: String {
        if !OutboundSyncGate.isEnabled {
            return approvedCount > 0
                ? "\(approvedCount) approved, held locally — publishing is switched off"
                : "Publishing is switched off"
        }
        if verifiedCount > 0 && publishedCount == 0 && awaitingRefreshCount == 0 {
            return "Confirmed on \(destination.displayName)"
        }
        if publishedCount > 0 || awaitingRefreshCount > 0 {
            return "Published — awaiting platform confirmation"
        }
        return approvedCount > 0 ? "Approved, not yet published" : "Nothing pending"
    }
}

/// Orchestrates feed generation and would orchestrate publication.
///
/// Everything here stops at the edge of this Mac. `publish` refuses while
/// `OutboundSyncGate.isEnabled` is false, and in this build it is false and
/// hard-coded. Generating a feed and writing it to a local file is not
/// publication, and the distinction is kept deliberately sharp: writing the
/// file changes nothing anywhere, and the coordinator never pretends otherwise.
public final class OutboundSyncCoordinator: @unchecked Sendable {
    let generator: CalendarFeedGenerator
    let decisions: AvailabilityRepository
    let manager: AvailabilityManager
    let database: Database
    let properties: PropertyRepository
    private let eventsProvider: @Sendable () throws -> [ClassifiedEvent]

    public init(
        generator: CalendarFeedGenerator = CalendarFeedGenerator(),
        decisions: AvailabilityRepository,
        manager: AvailabilityManager,
        properties: PropertyRepository,
        database: Database,
        eventsProvider: @escaping @Sendable () throws -> [ClassifiedEvent]
    ) {
        self.generator = generator
        self.decisions = decisions
        self.manager = manager
        self.properties = properties
        self.database = database
        self.eventsProvider = eventsProvider
    }

    // MARK: - Generation (always allowed — local only)

    /// Builds the feed a destination would receive. Writes nothing outward.
    public func generateFeed(
        propertyID: Int64, destination: RentalPlatform, now: Date = Date()
    ) throws -> DestinationFeed {
        let property = try properties.find(id: propertyID)
        let revision = try nextRevision(propertyID: propertyID, destination: destination)
        return generator.generate(
            destination: destination,
            propertyID: propertyID,
            propertyName: property?.name ?? "Property \(propertyID)",
            sourceEvents: try eventsProvider(),
            decisions: try decisions.forProperty(propertyID),
            revision: revision,
            now: now
        )
    }

    public func generateAll(
        propertyID: Int64, now: Date = Date()
    ) throws -> [DestinationFeed] {
        try [RentalPlatform.airbnb, .vrbo, .bookingCom].map {
            try generateFeed(propertyID: propertyID, destination: $0, now: now)
        }
    }

    /// Records a generated feed and its entries, so a published entry can later
    /// be traced to the decision or source event that justified it.
    @discardableResult
    public func recordGeneration(_ feed: DestinationFeed, status: String = "generated") throws -> Int64 {
        let ics = generator.makeICS(feed)
        try database.run("""
            INSERT INTO feed_publications
                (destination, property_id, revision, generated_at, entry_count, checksum, status)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """, [
                .text(feed.destination.rawValue), .integer(feed.propertyID),
                .integer(Int64(feed.revision)), SQLValue(feed.generatedAt),
                .integer(Int64(feed.included.count)),
                .text(EventKey.sha256(ics)), .text(status),
            ])
        let publicationID = database.lastInsertRowID

        for entry in feed.included {
            try database.run("""
                INSERT INTO published_feed_entries
                    (publication_id, entry_uid, origin, source_event_key, decision_id,
                     start_day, end_day, summary)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """, [
                    .integer(publicationID), .text(entry.uid), .text(entry.origin.rawValue),
                    SQLValue(entry.sourceEventKey), SQLValue(entry.decisionID),
                    SQLValue(entry.startDay), SQLValue(entry.endDay), .text(entry.summary),
                ])
        }
        return publicationID
    }

    private func nextRevision(propertyID: Int64, destination: RentalPlatform) throws -> Int {
        try database.scalarInt("""
            SELECT COALESCE(MAX(revision), 0) + 1 FROM feed_publications
            WHERE property_id = ? AND destination = ?;
            """, [.integer(propertyID), .text(destination.rawValue)])
    }

    /// Writes the feed to a local file for inspection. Local only — a file on
    /// this Mac is not reachable by any platform.
    @discardableResult
    public func writeLocalPreview(_ feed: DestinationFeed, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(generator.makeICS(feed).utf8).write(to: url, options: [.atomic])
        return url
    }

    // MARK: - Publication (gated)

    /// Would publish the feed to its hosting endpoint and mark its decisions
    /// published.
    ///
    /// Refuses while the outbound gate is shut. There is also, deliberately, no
    /// hosting client behind this: Phase C designs the hosting, Phase D would
    /// build it, and this build stops before Phase D.
    public func publish(
        propertyID: Int64, destination: RentalPlatform, now: Date = Date()
    ) throws -> Never {
        _ = propertyID
        _ = destination
        _ = now
        throw AvailabilityError.outboundDisabled
    }

    // MARK: - Status

    public func state(
        propertyID: Int64, destination: RentalPlatform
    ) throws -> DestinationSyncState {
        let mine = try decisions.forProperty(propertyID)
            .filter { $0.destination == destination }
        let lastGenerated = try database.queryOne("""
            SELECT MAX(generated_at) AS v FROM feed_publications
            WHERE property_id = ? AND destination = ?;
            """, [.integer(propertyID), .text(destination.rawValue)])?.date("v")

        return DestinationSyncState(
            destination: destination,
            propertyID: propertyID,
            approvedCount: mine.filter { $0.status == .approved }.count,
            publishedCount: mine.filter { $0.status == .published }.count,
            awaitingRefreshCount: mine.filter { $0.status == .awaitingPlatformRefresh }.count,
            verifiedCount: mine.filter { $0.status == .verified }.count,
            lastGeneratedAt: lastGenerated,
            lastPublishedAt: mine.compactMap(\.publishedAt).max(),
            capability: PlatformAdapters.capability(for: destination)
        )
    }

    public func allStates(propertyID: Int64) throws -> [DestinationSyncState] {
        try [RentalPlatform.airbnb, .vrbo, .bookingCom].map {
            try state(propertyID: propertyID, destination: $0)
        }
    }
}
