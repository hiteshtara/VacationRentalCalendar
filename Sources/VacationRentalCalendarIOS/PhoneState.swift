import Foundation
import SwiftUI
import VRCCore
import VRCSync

/// The iPhone's view model.
///
/// The phone is a companion, not a second manager. It reads the same local
/// SQLite database, which CloudKit keeps in step with the Mac, and it can make
/// classification decisions — but it never holds a feed URL it was not given on
/// this device, and it never exports.
@MainActor
public final class PhoneState: ObservableObject {
    @Published public private(set) var properties: [Property] = []
    @Published public private(set) var listings: [PlatformListing] = []
    @Published public private(set) var events: [ClassifiedEvent] = []
    @Published public private(set) var conflicts: [ReservationConflict] = []

    @Published public var selectedPropertyID: Int64?
    @Published public var anchorDate: Date = DayMath.utcMidnight(Date())
    @Published public var selectedDay: Date?

    @Published public private(set) var isSyncing = false
    @Published public private(set) var lastSync: Date?
    @Published public private(set) var syncMessage = "Not synced yet"
    @Published public private(set) var accountStatus: CloudAccountStatus = .unknown
    @Published public private(set) var errorMessage: String?

    private var store: RentalStore?
    private var engine: CloudSyncEngine?

    public init(store: RentalStore? = nil, cloud: CloudDatabase? = nil) {
        if let store {
            self.store = store
        } else {
            self.store = try? RentalStore.makeDefault()
        }
        if let store = self.store {
            #if canImport(CloudKit)
            self.engine = CloudSyncEngine(store: store, cloud: cloud ?? CloudKitDatabase())
            #else
            if let cloud { self.engine = CloudSyncEngine(store: store, cloud: cloud) }
            #endif
        }
        reload()
    }

    // MARK: - Reading

    public func reload() {
        guard let store else { return }
        properties = (try? store.properties.all()) ?? []
        listings = (try? store.listings.all()) ?? []
        events = (try? store.classifiedEvents()) ?? []
        conflicts = (try? store.conflicts()) ?? []
        if selectedPropertyID == nil { selectedPropertyID = properties.first?.id }
        lastSync = engine?.lastSyncAt()
    }

    public var visibleEvents: [ClassifiedEvent] {
        guard let id = selectedPropertyID else { return events }
        return events.filter { $0.propertyID == id }
    }

    public var reviewQueue: [ClassifiedEvent] {
        visibleEvents.filter { $0.classification.needsReview }
            .sorted { $0.event.checkIn < $1.event.checkIn }
    }

    public var doubleBookings: [ReservationConflict] {
        conflicts.filter { $0.severity == .doubleBooking && !$0.acknowledged }
    }

    public var protectedNights: Int {
        visibleEvents
            .filter {
                $0.classification.kind == .cancellationBlock
                    || $0.classification.kind == .unknownUnavailable
                    || $0.classification.needsReview
            }
            .reduce(0) { $0 + $1.event.nights }
    }

    public func events(on day: Date) -> [ClassifiedEvent] {
        visibleEvents.filter { $0.event.covers(day: day) }
    }

    /// Disagreements between this phone and the Mac that need settling.
    public func syncDisagreements() -> [(eventKey: String, local: BlockKind, remote: BlockKind)] {
        engine?.openDisagreements() ?? []
    }

    // MARK: - Sync

    public func sync() async {
        guard let engine, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let summary = await engine.synchronise()
        accountStatus = summary.accountStatus
        syncMessage = summary.line
        errorMessage = summary.error
        lastSync = summary.finishedAt ?? lastSync
        reload()
    }

    public var lastSyncDescription: String {
        guard let lastSync else { return "Never synced" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Synced \(formatter.localizedString(for: lastSync, relativeTo: Date()))"
    }

    // MARK: - Decisions

    public func classify(eventKey: String, as kind: BlockKind, note: String = "") {
        guard let store else { return }
        try? store.classifyManually(eventKey: eventKey, kind: kind, note: note)
        reload()
        Task { await sync() }
    }

    public func acknowledge(_ conflict: ReservationConflict) {
        guard let store else { return }
        try? store.conflictAcks.acknowledge(conflictID: conflict.id)
        reload()
    }

    // MARK: - Per-device credential setup

    /// Whether this device holds the feed URL for a listing.
    public func hasCredential(for listing: PlatformListing) -> Bool {
        store?.listings.hasCredential(for: listing) ?? false
    }

    /// Stores a feed URL in **this device's** Keychain.
    ///
    /// Feed URLs are never carried by CloudKit, so each device is set up on
    /// purpose. That is slightly more work once, and it means a device you stop
    /// using does not quietly retain access to your calendars.
    public func saveFeedURL(for listing: PlatformListing, url: String) {
        guard let store else { return }
        var updated = listing
        updated.icalURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.urlStorage = .keychain
        if updated.credentialRef.isEmpty {
            updated.credentialRef = ListingRepository.credentialReference(
                platform: listing.platform, listingLabel: listing.label
            )
        }
        do {
            try store.listings.update(updated)
            reload()
            errorMessage = nil
        } catch {
            errorMessage = "Could not save to the Keychain: \(error.localizedDescription)"
        }
    }

    /// Refreshes feeds this device actually has URLs for.
    public func refreshFeeds() async {
        guard let store else { return }
        let service = store.makeImportService(fetcher: URLSessionFeedFetcher())
        let available = listings.filter { store.listings.hasCredential(for: $0) }
        guard !available.isEmpty else {
            errorMessage = "No calendar URLs are set up on this iPhone. "
                + "Add them under Sync, or rely on iCloud for data from your Mac."
            return
        }
        for listing in available {
            _ = await service.importFeed(for: listing)
        }
        reload()
        await sync()
    }
}
