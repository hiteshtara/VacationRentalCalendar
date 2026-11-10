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
    @Published var isDetailPanelPresented = false
    /// Keys ticked in the review queue for a batch decision.
    @Published var reviewSelection: Set<String> = []

    // Availability editing
    @Published var rangeStart: Date?
    @Published var rangeEnd: Date?
    @Published var plannedActions: [RentalPlatform: AvailabilityAction] = [:]
    @Published var planReason: String = ""
    @Published private(set) var decisions: [AvailabilityDecision] = []
    @Published private(set) var auditEntries: [AuditEntry] = []
    @Published private(set) var syncStates: [DestinationSyncState] = []
    @Published private(set) var findings: [ConflictFinding] = []

    /// Presentation only. Hiding restrictions declutters the calendar and
    /// changes nothing about export eligibility, conflict detection or the
    /// review queue — a test asserts exactly that.
    @Published var showPlatformRestrictions = false

    // Status
    @Published private(set) var isRefreshing = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var lastError: String?
    @Published private(set) var notificationAvailability: ConflictNotifier.Availability = .notBundled
    @Published private(set) var hasAskedForNotifications = false
    @Published private(set) var signature: CodeSignatureInfo = .init(kind: .unsigned)
    @Published private(set) var storeFailure: String?

    // MARK: Cloud (AWS staging)
    //
    // Read-only. Nothing here publishes, approves, or enables a schedule --
    // the app can look at the cloud service and nothing more.
    @Published private(set) var cloud: CloudSnapshot = .unknown
    @Published private(set) var isCloudRefreshing = false
    @Published private(set) var cloudConfiguration: CloudConnection.Availability =
        .notConfigured(missing: ["endpoint"])
    /// How many long periods the one-off sweep brought back for review.
    private(set) var longPeriodsFlagged = 0

    // Settings
    @Published var autoRefreshEnabled = true
    @Published var autoRefreshMinutes = 60

    private var store: RentalStore?
    private let notifier = ConflictNotifier()
    private var refreshTask: Task<Void, Never>?

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case calendar, reservations, availability, review, cloud, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .calendar: return "Calendar"
            case .reservations: return "Reservations"
            case .availability: return "Availability"
            case .review: return "Needs Review"
            case .cloud: return "Cloud"
            case .settings: return "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .calendar: return "calendar"
            case .reservations: return "bed.double"
            case .availability: return "slider.horizontal.3"
            case .review: return "questionmark.circle"
            case .cloud: return "cloud"
            case .settings: return "gearshape"
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
                // Raises the review flag on unusually long periods. Never
                // changes a classification — see LongPeriodReview.
                self.longPeriodsFlagged = (try? LongPeriodReview.runOnce(in: created))?.count ?? 0
                self.store = created
            } catch {
                self.storeFailure = "The local database could not be opened: \(error)"
            }
        }
        self.signature = CodeSignatureInfo.current()
        self.reload()
        loadSettings()
        refreshCloudConfiguration()
    }

    var isReady: Bool { store != nil }

    // MARK: - Cloud

    /// Endpoint configuration, read from SQLite only.
    ///
    /// The GUI never reads the AWS credential from the Keychain -- it cannot, on
    /// this machine (see docs/KEYCHAIN.md). Whether the credential is actually
    /// usable is answered by the helper on refresh, not here. This only reports
    /// whether an endpoint has been stored and whether the helper is present.
    func refreshCloudConfiguration() {
        guard let store else { return }
        let endpoint = ((try? store.settings.string(CloudConnection.endpointSettingKey)) ?? nil) ?? ""
        let region = ((try? store.settings.string(CloudConnection.regionSettingKey)) ?? nil) ?? "us-east-1"
        if endpoint.isEmpty {
            cloudConfiguration = .notConfigured(missing: ["endpoint"])
        } else if HelperCloudClient.helperURL() == nil {
            cloudConfiguration = .credentialUnreadable("The bundled vrc helper is missing.")
        } else if let url = URL(string: endpoint), CloudConnection.isSecure(endpoint) {
            cloudConfiguration = .configured(endpoint: url, region: region)
        } else {
            cloudConfiguration = .insecureEndpoint(endpoint)
        }
        if case .configured = cloudConfiguration {} else if cloud.status == nil {
            cloud = CloudSnapshot(health: .notConfigured(cloudConfiguration.summary))
        }
    }

    var isCloudConfigured: Bool {
        if case .configured = cloudConfiguration { return true }
        return false
    }

    /// Asks the AWS service for its status, through the bundled helper.
    ///
    /// Read-only: the helper calls GET /status and GET /availability and
    /// nothing else. It cannot publish, approve a decision, or enable a
    /// schedule. The helper returns only CloudStatusPayload -- no secret ever
    /// crosses back into this process.
    func refreshFromCloud() {
        guard !isCloudRefreshing else { return }
        refreshCloudConfiguration()
        guard isCloudConfigured else {
            cloud = CloudSnapshot(health: .notConfigured(cloudConfiguration.summary))
            return
        }

        isCloudRefreshing = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                HelperCloudClient.statusWakingSleepingCluster()
            }.value

            await MainActor.run {
                guard let self else { return }
                self.isCloudRefreshing = false
                switch result {
                case .success(let payload):
                    self.cloud = Self.snapshot(from: payload)
                case .failure(let failure):
                    // The failure is kept and shown. An indicator that can only
                    // say "fine" is worse than none.
                    self.cloud = CloudSnapshot(
                        health: .unreachable(Self.describe(failure)),
                        status: self.cloud.status,
                        intervals: self.cloud.intervals,
                        checkedAt: Date())
                }
            }
        }
    }

    /// Maps the helper's sanitized payload onto the snapshot the interface
    /// shows. The reconstructed Status carries only the payload's fields.
    private static func snapshot(from payload: CloudStatusPayload) -> CloudSnapshot {
        let health: CloudSnapshot.Health
        switch payload.health {
        case .healthy: health = .healthy
        case .degraded: health = .degraded(payload.message)
        case .unreachable: health = .unreachable(payload.message)
        case .insecureEndpoint: health = .unreachable(payload.message)
        case .notConfigured: health = .notConfigured(payload.message)
        }

        guard payload.ok else {
            return CloudSnapshot(health: health, checkedAt: Date())
        }

        let status = CloudSyncClient.Status(
            liveSourceEvents: payload.liveSourceEvents ?? 0,
            approvedDecisions: payload.approvedDecisions ?? 0,
            publishedDecisions: payload.publishedDecisions ?? 0,
            openConflicts: payload.openConflicts ?? 0,
            lastSuccessfulImport: payload.lastSuccessfulImport ?? "",
            outboundEnabled: payload.outboundEnabled ?? false,
            remoteSynchronised: payload.remoteSynchronised ?? false,
            failingSources: payload.failingSources,
            staleSources: payload.staleSources)
        let intervals = payload.intervals.map {
            CloudSyncClient.BlockingInterval(
                property: $0.property, from: $0.from, to: $0.to,
                basis: $0.basis, source: $0.source)
        }
        return CloudSnapshot(health: health, status: status,
                             intervals: intervals, checkedAt: Date())
    }

    private static func describe(_ failure: HelperCloudClient.Failure) -> String {
        switch failure {
        case .helperMissing: return "The bundled vrc helper is missing."
        case .timedOut: return "The helper did not respond in time."
        case .noOutput: return "The helper returned nothing."
        case .unreadableOutput: return "The helper returned an unreadable result."
        }
    }

    /// Cloud intervals that have no counterpart in the local calendar, so the
    /// interface can show what the cloud knows and the Mac does not.
    var cloudOnlyIntervals: [CloudSyncClient.BlockingInterval] {
        let localNights: Set<String> = Set(events.flatMap { item -> [String] in
            var nights: [String] = []
            var day = item.event.checkIn
            while day < item.event.checkOut {
                nights.append(DayMath.icalDateString(day))
                day = DayMath.adding(days: 1, to: day)
            }
            return nights
        })
        return cloud.intervals.filter { interval in
            guard let from = CloudInterval.day(interval.from) else { return true }
            return !localNights.contains(DayMath.icalDateString(from))
        }
    }

    func start() {
        Task { [weak self] in await self?.refreshNotificationStatus() }
        scheduleAutoRefresh()
    }

    /// Reads the current permission without asking for it, so launching the app
    /// does not re-prompt and a denial can be reported accurately.
    func refreshNotificationStatus() async {
        let status = await notifier.currentAvailability()
        notificationAvailability = status
        hasAskedForNotifications = status != .notRequested
        // Ask once, on first launch, rather than silently never asking.
        if status == .notRequested {
            let granted = await notifier.requestAuthorization()
            notificationAvailability = granted
            hasAskedForNotifications = true
        }
    }

    /// Asks again on demand, for the button in Settings.
    func requestNotificationPermission() async {
        notificationAvailability = await notifier.requestAuthorization()
        hasAskedForNotifications = true
    }

    /// Opens the right pane of System Settings when permission was refused.
    func openNotificationSettings() {
        ConflictNotifier.openSystemNotificationSettings()
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
            findings = ConflictAnalyzer().analyse(
                events: events,
                listings: listings,
                acknowledgedIDs: try store.conflictAcks.acknowledgedIDs()
            )
            decisions = try store.availability.all()
            auditEntries = try store.auditLog.recent(limit: 200)
            if let propertyID = selectedPropertyID {
                syncStates = (try? store.outbound.allStates(propertyID: propertyID)) ?? []
            }
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

    /// Everything for the selected property. The authority for exports,
    /// conflicts and review — never filtered by a display toggle.
    var visibleEvents: [ClassifiedEvent] {
        guard let id = selectedPropertyID else { return events }
        return events.filter { $0.propertyID == id }
    }

    /// What the calendar draws. Restrictions and undecided blocks are hidden
    /// by default so reservations and real conflicts stand out; confirmed
    /// reservations and owner blocks are never hidden.
    var calendarEvents: [ClassifiedEvent] {
        guard !showPlatformRestrictions else { return visibleEvents }
        return visibleEvents.filter { item in
            switch item.displayStatus {
            case .confirmed, .ownerBlock, .maintenance:
                return true
            case .cancellationBlock, .platformRestriction, .needsReview, .unknown:
                return false
            }
        }
    }

    /// How many the toggle is currently hiding.
    var hiddenRestrictionCount: Int {
        showPlatformRestrictions ? 0 : visibleEvents.count - calendarEvents.count
    }

    var reservations: [ClassifiedEvent] {
        visibleEvents
            .filter { $0.classification.kind == .confirmedReservation }
            .sorted { $0.event.checkIn < $1.event.checkIn }
    }

    // MARK: - Conflict categories

    var visibleFindings: [ConflictFinding] {
        guard let id = selectedPropertyID else { return findings }
        return findings.filter { $0.propertyID == id }
    }

    func findings(_ category: ConflictCategory) -> [ConflictFinding] {
        visibleFindings.filter { $0.category == category }
    }

    var bookingConflictCount: Int {
        findings(.bookingConflict).filter { !$0.acknowledged }.count
    }

    var availabilityDifferences: [AvailabilityDifference] {
        guard let id = selectedPropertyID else { return [] }
        return AvailabilityOverview().differences(
            from: DayMath.utcMidnight(Date()), days: 120, propertyID: id,
            events: visibleEvents, listings: listingsForSelectedProperty
        )
    }

    func availability(on day: Date) -> DayAvailability? {
        guard let id = selectedPropertyID else { return nil }
        return AvailabilityOverview().day(
            day, propertyID: id, events: visibleEvents, listings: listingsForSelectedProperty
        )
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

    var selectedEvent: ClassifiedEvent? {
        selectedEventKey.flatMap { event(for: $0) }
    }

    /// Opens the detail panel on an event. Used by every calendar view, so a
    /// bar, a row and a review item all behave the same way.
    func select(eventKey: String) {
        selectedEventKey = eventKey
        isDetailPanelPresented = true
    }

    func clearSelection() {
        selectedEventKey = nil
        isDetailPanelPresented = false
    }

    /// What each feed is and is not telling us — drives the warning shown when
    /// a platform sends nothing that could identify a booking.
    var feedDiagnostics: [FeedDiagnostic] {
        FeedDiagnostics.diagnoseAll(listings: listingsForSelectedProperty, events: visibleEvents)
    }

    var uninformativeFeeds: [FeedDiagnostic] {
        feedDiagnostics.filter(\.cannotIdentifyReservations)
    }

    /// True when this event's own feed gave nothing to identify a booking by.
    func feedLacksDetail(for item: ClassifiedEvent) -> Bool {
        !FeedDiagnostics.identifiesReservation(
            summary: item.event.summary,
            details: item.event.details,
            platform: item.event.platform
        )
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

    /// Applies one decision to several events at once. The review queue for a
    /// feed like Airbnb's is usually several identical-looking blocks, and
    /// deciding them one at a time is needless work.
    func classifyBatch(eventKeys: Set<String>, as kind: BlockKind, note: String = "") {
        guard let store, !eventKeys.isEmpty else { return }
        var failures = 0
        for key in eventKeys {
            do {
                try store.classifyManually(eventKey: key, kind: kind, note: note)
            } catch {
                failures += 1
            }
        }
        reviewSelection.removeAll()
        reload()
        statusMessage = failures == 0
            ? "Classified \(eventKeys.count) event\(eventKeys.count == 1 ? "" : "s") as \(kind.displayName.lowercased())."
            : "Classified \(eventKeys.count - failures), but \(failures) could not be saved."
    }

    /// Moves to the next item still needing review, so a decision advances the
    /// queue instead of leaving the cursor on something already handled.
    func advanceToNextReviewItem(after key: String) {
        let queue = reviewQueue
        guard !queue.isEmpty else {
            selectedEventKey = nil
            return
        }
        if let index = queue.firstIndex(where: { $0.event.eventKey == key }) {
            let next = queue.index(after: index)
            selectedEventKey = (next < queue.endIndex ? queue[next] : queue[0]).event.eventKey
        } else {
            selectedEventKey = queue.first?.event.eventKey
        }
    }

    /// Other undecided events from the same feed that look the same, so one
    /// decision can cover the obvious group.
    func similarPendingEvents(to item: ClassifiedEvent) -> [ClassifiedEvent] {
        reviewQueue.filter {
            $0.event.eventKey != item.event.eventKey
                && $0.event.platform == item.event.platform
                && $0.event.summary == item.event.summary
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

    func acknowledge(finding: ConflictFinding) {
        guard let store else { return }
        try? store.conflictAcks.acknowledge(conflictID: finding.id)
        reload()
    }

    func unacknowledge(finding: ConflictFinding) {
        guard let store else { return }
        try? store.conflictAcks.unacknowledge(conflictID: finding.id)
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

    // MARK: - Availability

    /// The nights currently selected in the calendar, checkout-exclusive.
    var selectedRange: (start: Date, end: Date)? {
        guard let rangeStart, let rangeEnd else { return nil }
        let lower = min(rangeStart, rangeEnd)
        let upper = max(rangeStart, rangeEnd)
        // The user picks the last night; the stored end is the morning after.
        return (lower, DayMath.adding(days: 1, to: upper))
    }

    var selectedNights: Int {
        guard let range = selectedRange else { return 0 }
        return max(0, DayMath.daysBetween(range.start, range.end))
    }

    /// Clicking a day starts a range; clicking a second day completes it.
    func selectDay(_ day: Date) {
        let value = DayMath.utcMidnight(day)
        if rangeStart == nil || rangeEnd != nil {
            rangeStart = value
            rangeEnd = nil
        } else {
            rangeEnd = value
        }
    }

    func extendSelection(to day: Date) {
        if rangeStart == nil { rangeStart = DayMath.utcMidnight(day) }
        rangeEnd = DayMath.utcMidnight(day)
    }

    func clearRange() {
        rangeStart = nil
        rangeEnd = nil
        plannedActions = [:]
        planReason = ""
    }

    func isDayInSelection(_ day: Date) -> Bool {
        guard let range = selectedRange else { return false }
        let value = DayMath.utcMidnight(day)
        return value >= range.start && value < range.end
    }

    var currentPlan: AvailabilityPlan? {
        guard let propertyID = selectedPropertyID, let range = selectedRange,
              !plannedActions.isEmpty else { return nil }
        return AvailabilityPlan(
            propertyID: propertyID, startDay: range.start, endDay: range.end,
            reason: planReason, actions: plannedActions
        )
    }

    /// Works out what the plan would do. Writes nothing.
    func previewPlan() -> VRCCore.AvailabilityPreview? {
        guard let store, let plan = currentPlan else { return nil }
        return try? store.availabilityManager.preview(plan)
    }

    func submitPlan() {
        guard let store, let plan = currentPlan else { return }
        do {
            let submitted = try store.availabilityManager.submit(plan)
            reload()
            let refused = submitted.filter { $0.status == .failed }.count
            statusMessage = refused == 0
                ? "\(submitted.count) change\(submitted.count == 1 ? "" : "s") waiting for your approval."
                : "\(submitted.count - refused) waiting for approval, \(refused) refused."
            clearRange()
        } catch {
            lastError = "Could not save that plan: \(error.localizedDescription)"
        }
    }

    func approve(decisionID: Int64) {
        guard let store else { return }
        do {
            let approved = try store.availabilityManager.approve(decisionID: decisionID)
            reload()
            statusMessage = "Approved: \(approved.summaryLine). Nothing has been sent anywhere."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            reload()
        }
    }

    func cancel(decisionID: Int64) {
        guard let store else { return }
        do {
            _ = try store.availabilityManager.cancel(decisionID: decisionID)
            statusMessage = "Change cancelled."
        } catch let error as AvailabilityError {
            // An approved decision refuses a plain cancel. Say so rather than
            // failing silently, which is how the old `try?` behaved.
            statusMessage = error.errorDescription ?? "That change could not be cancelled."
        } catch {
            statusMessage = "That change could not be cancelled."
        }
        reload()
    }

    /// Deliberately withdrawing an approval. The view asks for confirmation
    /// first; this is only reached after the owner says yes.
    func withdrawApproved(decisionID: Int64) {
        guard let store else { return }
        do {
            _ = try store.availabilityManager.withdrawApproved(
                decisionID: decisionID, confirmation: .ownerConfirmedWithdrawal)
            statusMessage = "Approval withdrawn. The nights go back on sale here."
        } catch {
            statusMessage = "That approval could not be withdrawn."
        }
        reload()
    }

    func cancelAllPending() {
        guard let store, let propertyID = selectedPropertyID else { return }
        guard let result = try? store.availabilityManager.cancelPending(propertyID: propertyID)
        else { return }
        reload()
        var message = "Cleared \(result.cancelled) pending change"
            + (result.cancelled == 1 ? "." : "s.")
        if result.keptApproved > 0 {
            // Saying what was KEPT is the point. A sweep that quietly does
            // less than the button implies is its own surprise.
            message += " \(result.keptApproved) approved change"
                + (result.keptApproved == 1 ? " was" : "s were")
                + " kept — withdraw those individually if you meant to."
        }
        statusMessage = message
    }

    var decisionsForSelectedProperty: [AvailabilityDecision] {
        guard let id = selectedPropertyID else { return decisions }
        return decisions.filter { $0.propertyID == id }
    }

    var pendingDecisions: [AvailabilityDecision] {
        decisionsForSelectedProperty.filter { $0.status.isPending }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func destinationFeed(for destination: RentalPlatform) -> DestinationFeed? {
        guard let store, let id = selectedPropertyID else { return nil }
        return try? store.outbound.generateFeed(propertyID: id, destination: destination)
    }

    func auditEntries(forDecision id: Int64) -> [AuditEntry] {
        guard let store else { return [] }
        return (try? store.auditLog.entries(forDecision: id)) ?? []
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
