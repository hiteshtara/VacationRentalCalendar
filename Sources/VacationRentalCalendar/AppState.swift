import Foundation
import SwiftUI
import VRCCore

/// Everything the views read, and the only place that talks to `RentalStore`.
@MainActor
final class AppState: ObservableObject {

    // Data
    @Published private(set) var properties: [Property] = []
    @Published private(set) var listings: [PlatformListing] = []
    @Published private(set) var events: [ClassifiedEvent] = []
    @Published private(set) var conflicts: [ReservationConflict] = []
    @Published private(set) var syncRuns: [SyncRun] = []

    // UI state
    @Published var selectedPropertyID: Int64?
    @Published var selectedSection: Section = .calendar
    @Published var calendarMode: CalendarMode = .month
    @Published var anchorDate: Date = DayMath.utcMidnight(Date())
    @Published var selectedEventKey: String?

    // Status
    @Published private(set) var isRefreshing = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var lastError: String?
    @Published private(set) var notificationAvailability: ConflictNotifier.Availability = .notBundled
    @Published private(set) var signature: CodeSignatureInfo = .init(kind: .unsigned)
    @Published private(set) var storeFailure: String?

    // Settings
    @Published var autoRefreshEnabled = true
    @Published var autoRefreshMinutes = 60

    private var store: RentalStore?
    private let notifier = ConflictNotifier()
    private var refreshTask: Task<Void, Never>?

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case calendar, review, conflicts, export, feeds, history
        var id: String { rawValue }

        var title: String {
            switch self {
            case .calendar: return "Calendar"
            case .review: return "Needs Review"
            case .conflicts: return "Conflicts"
            case .export: return "Filtered Export"
            case .feeds: return "Feeds"
            case .history: return "Sync History"
            }
        }

        var symbol: String {
            switch self {
            case .calendar: return "calendar"
            case .review: return "questionmark.circle"
            case .conflicts: return "exclamationmark.triangle"
            case .export: return "square.and.arrow.up"
            case .feeds: return "antenna.radiowaves.left.and.right"
            case .history: return "clock.arrow.circlepath"
            }
        }
    }

    enum CalendarMode: String, CaseIterable, Identifiable, Hashable {
        case month, week, list
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    // MARK: - Lifecycle

    init(store: RentalStore? = nil) {
        if let store {
            self.store = store
        } else {
            do {
                let created = try RentalStore.makeDefault()
                try SeedData.apply(to: created)
                self.store = created
            } catch {
                self.storeFailure = "The local database could not be opened: \(error)"
            }
        }
        self.signature = CodeSignatureInfo.current()
        self.reload()
        loadSettings()
    }

    var isReady: Bool { store != nil }

    func start() {
        Task { [weak self] in
            guard let self else { return }
            let availability = await self.notifier.requestAuthorization()
            await MainActor.run { self.notificationAvailability = availability }
        }
        scheduleAutoRefresh()
    }

    // MARK: - Reading

    func reload() {
        guard let store else { return }
        do {
            properties = try store.properties.all()
            listings = try store.listings.all()
            events = try store.classifiedEvents()
            conflicts = try store.conflicts()
            syncRuns = try store.syncRuns.recent(limit: 100)
            if selectedPropertyID == nil { selectedPropertyID = properties.first?.id }
            lastError = nil
        } catch {
            lastError = "Could not read the database: \(error)"
        }
    }

    private func loadSettings() {
        guard let store else { return }
        autoRefreshEnabled = (try? store.settings.bool(SettingKey.autoRefreshEnabled, default: true)) ?? true
        autoRefreshMinutes = (try? store.settings.int(SettingKey.autoRefreshMinutes, default: 60)) ?? 60
    }

    func saveRefreshSettings() {
        guard let store else { return }
        try? store.settings.set(SettingKey.autoRefreshEnabled, autoRefreshEnabled)
        try? store.settings.set(SettingKey.autoRefreshMinutes, max(5, autoRefreshMinutes))
        scheduleAutoRefresh()
    }

    // MARK: - Derived

    var selectedProperty: Property? {
        properties.first { $0.id == selectedPropertyID }
    }

    var visibleEvents: [ClassifiedEvent] {
        guard let id = selectedPropertyID else { return events }
        return events.filter { $0.propertyID == id }
    }

    var reviewQueue: [ClassifiedEvent] {
        visibleEvents
            .filter { $0.classification.needsReview }
            .sorted { $0.event.checkIn < $1.event.checkIn }
    }

    var visibleConflicts: [ReservationConflict] {
        guard let id = selectedPropertyID else { return conflicts }
        return conflicts.filter { $0.propertyID == id }
    }

    var doubleBookingCount: Int {
        visibleConflicts.filter { $0.severity == .doubleBooking && !$0.acknowledged }.count
    }

    var listingsForSelectedProperty: [PlatformListing] {
        guard let id = selectedPropertyID else { return listings }
        return listings.filter { $0.propertyID == id }
    }

    /// Nights the app is currently protecting from propagation.
    var protectedNights: Int {
        visibleEvents
            .filter {
                $0.classification.kind == .cancellationBlock
                    || $0.classification.kind == .unknownUnavailable
                    || $0.classification.needsReview
            }
            .reduce(0) { $0 + $1.event.nights }
    }

    func events(on day: Date) -> [ClassifiedEvent] {
        visibleEvents.filter { $0.event.covers(day: day) }
    }

    func event(for key: String) -> ClassifiedEvent? {
        events.first { $0.event.eventKey == key }
    }

    // MARK: - Importing

    func refreshAll(autoRefreshOnly: Bool = false) async {
        guard let store, !isRefreshing else { return }
        isRefreshing = true
        statusMessage = "Reading calendars…"
        defer { isRefreshing = false }

        let service = store.makeImportService(fetcher: URLSessionFeedFetcher())
        let targets = autoRefreshOnly
            ? listings.filter(\.autoRefreshEnabled)
            : listings

        var seen = 0, created = 0, changed = 0, review = 0
        var failures: [String] = []

        for listing in targets {
            let report = await service.importFeed(for: listing)
            seen += report.run.eventsSeen
            created += report.run.eventsInserted
            changed += report.run.eventsUpdated
            review += report.run.eventsNeedingReview
            if report.run.outcome == .failure {
                failures.append("\(listing.label): \(report.run.errorMessage ?? "failed")")
            }
        }

        reload()
        notifier.announce(conflicts: conflicts)

        var parts = ["\(seen) event\(seen == 1 ? "" : "s") read"]
        if created > 0 { parts.append("\(created) new") }
        if changed > 0 { parts.append("\(changed) changed") }
        if review > 0 { parts.append("\(review) need review") }
        statusMessage = parts.joined(separator: " · ")
        lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func refresh(listing: PlatformListing) async {
        guard let store else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let service = store.makeImportService(fetcher: URLSessionFeedFetcher())
        let report = await service.importFeed(for: listing)
        reload()
        statusMessage = "\(listing.label): \(report.run.summaryLine)"
        lastError = report.run.outcome == .failure ? report.run.errorMessage : nil
    }

    private func scheduleAutoRefresh() {
        refreshTask?.cancel()
        guard autoRefreshEnabled else { return }
        let interval = UInt64(max(5, autoRefreshMinutes)) * 60 * 1_000_000_000
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { return }
                await self?.refreshAll(autoRefreshOnly: true)
            }
        }
    }

    // MARK: - Classification

    func classify(eventKey: String, as kind: BlockKind, note: String = "", approve: Bool? = nil) {
        guard let store else { return }
        do {
            try store.classifyManually(
                eventKey: eventKey, kind: kind, note: note, approveForExport: approve
            )
            reload()
            statusMessage = "Saved: \(kind.displayName)."
        } catch {
            lastError = "Could not save that decision: \(error)"
        }
    }

    func setExportApproval(eventKey: String, approved: Bool) {
        guard let store else { return }
        try? store.setExportApproval(eventKey: eventKey, approved: approved)
        reload()
    }

    func setExportSuppressed(eventKey: String, suppressed: Bool) {
        guard let store else { return }
        try? store.setExportSuppressed(eventKey: eventKey, suppressed: suppressed)
        reload()
    }

    func acknowledge(conflict: ReservationConflict) {
        guard let store else { return }
        try? store.conflictAcks.acknowledge(conflictID: conflict.id)
        reload()
    }

    func unacknowledge(conflict: ReservationConflict) {
        guard let store else { return }
        try? store.conflictAcks.unacknowledge(conflictID: conflict.id)
        reload()
    }

    // MARK: - Feeds

    func saveFeedURL(for listing: PlatformListing, url: String) {
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
            statusMessage = "Saved to the Keychain for \(listing.label)."
            lastError = nil
        } catch {
            lastError = "Could not store that URL in the Keychain: \(error)"
        }
    }

    func storedURL(for listing: PlatformListing) -> String {
        guard let store else { return "" }
        return store.listings.resolvedURLIfAvailable(for: listing)
    }

    func hasStoredCredential(for listing: PlatformListing) -> Bool {
        store?.listings.hasCredential(for: listing) ?? false
    }

    func setAutoRefresh(_ enabled: Bool, for listing: PlatformListing) {
        guard let store else { return }
        var updated = listing
        updated.autoRefreshEnabled = enabled
        try? store.listings.update(updated)
        reload()
    }

    func addProperty(name: String, address: String) {
        guard let store, !name.isEmpty else { return }
        do {
            let property = try store.properties.insert(Property(name: name, address: address))
            if let id = property.id {
                for platform in [RentalPlatform.airbnb, .vrbo, .bookingCom] {
                    try store.listings.insert(PlatformListing(
                        propertyID: id,
                        platform: platform,
                        label: "\(platform.displayName) — \(name)",
                        urlStorage: .keychain,
                        credentialRef: ListingRepository.credentialReference(
                            platform: platform, listingLabel: name
                        ),
                        autoRefreshEnabled: false
                    ))
                }
            }
            reload()
            selectedPropertyID = property.id
        } catch {
            lastError = "Could not add that property: \(error)"
        }
    }

    // MARK: - Export

    func exportPlan(destination: RentalPlatform?) -> ExportPlan? {
        guard let store, let id = selectedPropertyID else { return nil }
        return try? store.exportPlan(propertyID: id, destination: destination)
    }

    func writeExport(plan: ExportPlan, to url: URL) {
        guard let store else { return }
        do {
            try store.exporter.write(plan: plan, to: url)
            statusMessage = "Wrote \(plan.included.count) event(s) to \(url.lastPathComponent)."
        } catch {
            lastError = "Could not write that file: \(error)"
        }
    }

    func auditText(for plan: ExportPlan) -> String {
        store?.exporter.auditText(for: plan) ?? ""
    }
}
