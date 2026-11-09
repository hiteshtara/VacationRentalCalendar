import Foundation

/// Everything the app needs, assembled in one place.
///
/// Holds the database, the repositories and the services, and exposes the few
/// composite reads the UI actually wants. Synchronous by design — SQLite is
/// fast enough locally that a background queue would add risk without adding
/// responsiveness.
public final class RentalStore: @unchecked Sendable {
    public let database: Database
    public let credentials: FeedCredentialStore
    public let properties: PropertyRepository
    public let listings: ListingRepository
    public let events: EventRepository
    public let classifications: ClassificationRepository
    public let syncRuns: SyncRunRepository
    public let conflictAcks: ConflictRepository
    public let settings: SettingsRepository
    public let classifier: BlockClassifier
    public let detector: ConflictDetector
    public let exporter: ExportService
    public let policy: ExportPolicy
    public let availability: AvailabilityRepository
    public let auditLog: AvailabilityAuditLog
    public let snapshots: FeedSnapshotRepository
    public let feedTokens: FeedTokenRepository
    public private(set) var availabilityManager: AvailabilityManager!
    public private(set) var outbound: OutboundSyncCoordinator!

    public init(database: Database, credentials: FeedCredentialStore) throws {
        self.database = database
        self.credentials = credentials
        try Migrator.migrate(database)
        self.properties = PropertyRepository(database: database)
        self.listings = ListingRepository(database: database, credentials: credentials)
        self.events = EventRepository(database: database)
        self.classifications = ClassificationRepository(database: database)
        self.syncRuns = SyncRunRepository(database: database)
        self.conflictAcks = ConflictRepository(database: database)
        self.settings = SettingsRepository(database: database)
        self.classifier = BlockClassifier()
        self.detector = ConflictDetector()
        self.policy = ExportPolicy()
        self.exporter = ExportService(policy: policy)
        self.availability = AvailabilityRepository(database: database)
        self.auditLog = AvailabilityAuditLog(database: database)
        self.snapshots = FeedSnapshotRepository(database: database)
        self.feedTokens = FeedTokenRepository(database: database, credentials: credentials)

        // Built after the stored properties so they can close over `self`
        // safely; the closure only reads, and only on demand.
        let repositories = (
            availability: self.availability,
            audit: self.auditLog,
            properties: self.properties,
            listings: self.listings
        )
        let provider: @Sendable () throws -> [ClassifiedEvent] = { [unowned self] in
            try self.classifiedEvents()
        }
        self.availabilityManager = AvailabilityManager(
            decisions: repositories.availability,
            audit: repositories.audit,
            properties: repositories.properties,
            listings: repositories.listings,
            eventsProvider: provider
        )
        self.outbound = OutboundSyncCoordinator(
            decisions: repositories.availability,
            manager: availabilityManager,
            properties: repositories.properties,
            database: database,
            eventsProvider: provider
        )
    }

    /// The real on-disk store.
    ///
    /// Keychain only. There is deliberately no plaintext or file-based
    /// fallback: a feed URL is a bearer credential for the owner's whole
    /// booking calendar, and silently downgrading its protection would be worse
    /// than failing visibly.
    public static func makeDefault() throws -> RentalStore {
        AppPaths.ensureDirectories()
        let keychain = KeychainFeedCredentialStore(
            additionalTrustedPaths: AppPaths.siblingExecutablePaths()
        )
        return try RentalStore(
            database: Database(path: AppPaths.databaseURL.path),
            credentials: DeadlineFeedCredentialStore(wrapping: keychain)
        )
    }

    /// A throwaway store for tests.
    public static func makeInMemory() throws -> RentalStore {
        try RentalStore(database: Database.inMemory(), credentials: InMemoryFeedCredentialStore())
    }

    // MARK: - Composite reads

    public func makeImportService(fetcher: FeedFetching) -> ImportService {
        ImportService(
            events: events,
            classifications: classifications,
            listings: listings,
            syncRuns: syncRuns,
            fetcher: fetcher,
            classifier: classifier
        )
    }

    /// Every active event joined to its classification, its listing and its
    /// property — the shape every view wants.
    public func classifiedEvents(includeTombstoned: Bool = false) throws -> [ClassifiedEvent] {
        let allProperties = try properties.all()
        let allListings = try listings.all()
        let allClassifications = try classifications.all()

        let propertyNames = Dictionary(
            uniqueKeysWithValues: allProperties.compactMap { property -> (Int64, String)? in
                property.id.map { ($0, property.name) }
            }
        )
        let listingInfo = Dictionary(
            uniqueKeysWithValues: allListings.compactMap { listing -> (Int64, PlatformListing)? in
                listing.id.map { ($0, listing) }
            }
        )

        let rows = includeTombstoned
            ? try events.all(includeTombstoned: true)
            : try events.allActive()

        return rows.map { event in
            let listing = listingInfo[event.listingID]
            let propertyID = listing?.propertyID ?? 0
            let classification = allClassifications[event.eventKey]
                ?? EventClassification(
                    eventKey: event.eventKey,
                    kind: .unknownUnavailable,
                    confidence: .low,
                    source: .automatic,
                    needsReview: true,
                    rationale: "No classification was recorded for this event, so it is treated as "
                        + "unknown and is never exported."
                )
            return ClassifiedEvent(
                event: event,
                classification: classification,
                listingLabel: listing?.label ?? "Unknown listing",
                propertyID: propertyID,
                propertyName: propertyNames[propertyID] ?? "Unassigned"
            )
        }
    }

    public func conflicts() throws -> [ReservationConflict] {
        detector.detect(
            in: try classifiedEvents(),
            acknowledgedIDs: try conflictAcks.acknowledgedIDs()
        )
    }

    public func needsReview() throws -> [ClassifiedEvent] {
        try classifiedEvents()
            .filter { $0.classification.needsReview }
            .sorted { $0.event.checkIn < $1.event.checkIn }
    }

    // MARK: - Manual classification

    /// Records the owner's decision. Marked `.manual`, which makes it permanent
    /// as far as future imports are concerned.
    public func classifyManually(
        eventKey: String,
        kind: BlockKind,
        note: String = "",
        approveForExport: Bool? = nil
    ) throws {
        let existing = try classifications.find(eventKey: eventKey)
        // A cancellation or unknown classification can never be export-approved,
        // regardless of what the caller passes.
        let approved = kind.describesGenuineUnavailability
            ? (approveForExport ?? existing?.exportApproved ?? false)
            : false

        let classification = EventClassification(
            eventKey: eventKey,
            kind: kind,
            confidence: .high,
            source: .manual,
            needsReview: false,
            rationale: "You classified this as \(kind.displayName.lowercased()).",
            note: note.isEmpty ? (existing?.note ?? "") : note,
            exportApproved: approved,
            exportSuppressed: existing?.exportSuppressed ?? false,
            decidedAt: Date()
        )
        try classifications.save(classification)
    }

    public func setExportApproval(eventKey: String, approved: Bool) throws {
        guard var classification = try classifications.find(eventKey: eventKey) else { return }
        guard classification.kind.describesGenuineUnavailability else { return }
        classification.exportApproved = approved
        classification.decidedAt = Date()
        try classifications.save(classification)
    }

    public func setExportSuppressed(eventKey: String, suppressed: Bool) throws {
        guard var classification = try classifications.find(eventKey: eventKey) else { return }
        classification.exportSuppressed = suppressed
        classification.decidedAt = Date()
        try classifications.save(classification)
    }

    /// Drops a manual decision and lets the classifier have another go.
    public func resetToAutomatic(eventKey: String) throws {
        guard let event = try events.find(eventKey: eventKey) else { return }
        let proposal = ClassificationProposal(
            kind: .unknownUnavailable,
            confidence: .low,
            rationale: "Your decision was cleared, so this is unknown again until reclassified.",
            needsReview: true
        )
        _ = event
        try classifications.save(EventClassification(eventKey: eventKey, proposal: proposal))
    }

    // MARK: - Export

    public func exportPlan(
        propertyID: Int64,
        destination: RentalPlatform?,
        horizonDays: Int? = nil
    ) throws -> ExportPlan {
        let property = try properties.find(id: propertyID)
        return exporter.plan(
            propertyID: propertyID,
            propertyName: property?.name ?? "Property \(propertyID)",
            events: try classifiedEvents(),
            destination: destination,
            horizonDays: horizonDays
        )
    }
}
