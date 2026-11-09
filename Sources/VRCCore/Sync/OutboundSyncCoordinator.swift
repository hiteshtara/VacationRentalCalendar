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
    let snapshots: FeedSnapshotRepository
    private let eventsProvider: @Sendable () throws -> [ClassifiedEvent]
    private let listingsProvider: @Sendable () throws -> [PlatformListing]
    private let syncRunsProvider: @Sendable () throws -> [SyncRun]

    public init(
        generator: CalendarFeedGenerator = CalendarFeedGenerator(),
        decisions: AvailabilityRepository,
        manager: AvailabilityManager,
        properties: PropertyRepository,
        snapshots: FeedSnapshotRepository,
        database: Database,
        eventsProvider: @escaping @Sendable () throws -> [ClassifiedEvent],
        listingsProvider: @escaping @Sendable () throws -> [PlatformListing],
        syncRunsProvider: @escaping @Sendable () throws -> [SyncRun]
    ) {
        self.generator = generator
        self.decisions = decisions
        self.manager = manager
        self.properties = properties
        self.snapshots = snapshots
        self.database = database
        self.eventsProvider = eventsProvider
        self.listingsProvider = listingsProvider
        self.syncRunsProvider = syncRunsProvider
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

    // MARK: - Rehearsal and recovery

    /// Runs the whole publication pipeline against a hosting client, recording
    /// the publication, its stage and — on success — a last-known-good
    /// snapshot.
    ///
    /// Deliberately takes the hosting client as an argument rather than owning
    /// one, so a rehearsal against a local directory uses exactly the same code
    /// path as a live publish would. The only thing a live publish adds is
    /// `OutboundSyncGate`, which `publish` enforces and this does not — because
    /// this never reaches a booking platform.
    @discardableResult
    public func runPipeline(
        propertyID: Int64,
        destination: RentalPlatform,
        hosting: FeedHostingClient,
        key: String,
        changeApproved: Bool,
        now: Date = Date()
    ) async throws -> PublicationAttempt {
        let feed = try generateFeed(propertyID: propertyID, destination: destination, now: now)
        let lastGood = try snapshots.lastKnownGood(
            propertyID: propertyID, destination: destination
        )
        let context = try publicationContext(propertyID: propertyID, now: now)

        let attempt = await PublicationPipeline(hosting: hosting).publish(
            feed: feed, lastKnownGood: lastGood, context: context,
            key: key, changeApproved: changeApproved, now: now
        )

        let publicationID = try recordGeneration(feed, status: attempt.stage.rawValue)
        try database.run("""
            UPDATE feed_publications
            SET stage = ?, uploaded_at = ?, cache_invalidated_at = ?,
                diff_summary = ?, safety_verdict = ?, failure_detail = ?
            WHERE id = ?;
            """, [
                .text(attempt.stage.rawValue),
                SQLValue(attempt.stage == .uploaded
                         || attempt.stage == .cacheInvalidated
                         || attempt.stage == .platformRefreshPending ? now : nil),
                SQLValue(attempt.stage == .cacheInvalidated
                         || attempt.stage == .platformRefreshPending ? now : nil),
                .text(attempt.safety.diff.summary),
                .text(attempt.safety.verdict.rawValue),
                SQLValue(attempt.succeeded ? nil : attempt.detail),
                .integer(publicationID),
            ])

        // Only a feed that actually reached the platform-refresh stage is
        // recorded as good. Something uploaded but not purged is live nowhere,
        // and rolling back to it later would serve bytes no one ever saw.
        if attempt.stage == .platformRefreshPending {
            let snapshot = try snapshots.record(FeedSnapshot(
                propertyID: propertyID,
                destination: destination,
                revision: feed.revision,
                generatedAt: feed.generatedAt,
                publishedAt: now,
                checksum: EventKey.sha256(generator.makeICS(feed)),
                entries: feed.included.map {
                    SnapshotEntry(
                        uid: $0.uid, startDay: $0.startDay,
                        endDay: $0.endDay, summary: $0.summary
                    )
                },
                payload: generator.makeICS(feed)
            ))
            if let id = snapshot.id {
                try snapshots.markLastKnownGood(
                    id: id, propertyID: propertyID, destination: destination
                )
            }
        }

        return attempt
    }

    /// Restores the last feed known to have been served.
    ///
    /// Used when a publication fails partway: the previous bytes are put back
    /// so that whatever platforms read next is a feed that was once correct,
    /// rather than whatever the failure left behind.
    @discardableResult
    public func rollback(
        propertyID: Int64,
        destination: RentalPlatform,
        hosting: FeedHostingClient,
        key: String,
        now: Date = Date()
    ) async throws -> FeedSnapshot? {
        guard let good = try snapshots.lastKnownGood(
            propertyID: propertyID, destination: destination
        ) else { return nil }

        try await hosting.upload(
            key: key, body: good.payload, cacheControl: R2HostingConfiguration.cacheControl
        )
        try await hosting.invalidateCache(key: key)

        try database.run("""
            INSERT INTO feed_publications
                (destination, property_id, revision, generated_at, entry_count, checksum,
                 status, stage, uploaded_at, cache_invalidated_at, diff_summary, failure_detail)
            VALUES (?, ?, ?, ?, ?, ?, 'rolled_back', 'rolled_back', ?, ?, ?, ?);
            """, [
                .text(destination.rawValue), .integer(propertyID),
                .integer(Int64(good.revision)), SQLValue(now),
                .integer(Int64(good.entryCount)), .text(good.checksum),
                SQLValue(now), SQLValue(now),
                .text("restored revision \(good.revision)"),
                SQLValue(nil as String?),
            ])
        return good
    }

    /// Gathers what the safety assessment needs.
    public func publicationContext(
        propertyID: Int64, now: Date = Date()
    ) throws -> PublicationContext {
        PublicationContext(
            listings: try listingsProvider().filter { $0.propertyID == propertyID },
            recentSyncRuns: try syncRunsProvider(),
            decisions: try decisions.forProperty(propertyID),
            sourceEvents: try eventsProvider().filter { $0.propertyID == propertyID },
            now: now
        )
    }

    /// Every publication attempt, newest first, for failure reporting.
    public func publicationHistory(
        propertyID: Int64, destination: RentalPlatform, limit: Int = 20
    ) throws -> [(revision: Int, stage: String, verdict: String, detail: String, at: Date)] {
        try database.query("""
            SELECT revision, stage, safety_verdict, COALESCE(failure_detail,'') AS failure_detail,
                   generated_at
            FROM feed_publications
            WHERE property_id = ? AND destination = ?
            ORDER BY id DESC LIMIT ?;
            """, [
                .integer(propertyID), .text(destination.rawValue), .integer(Int64(limit)),
            ]).map {
            (
                revision: $0.intValue("revision"),
                stage: $0.stringValue("stage"),
                verdict: $0.stringValue("safety_verdict"),
                detail: $0.stringValue("failure_detail"),
                at: $0.dateValue("generated_at")
            )
        }
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
