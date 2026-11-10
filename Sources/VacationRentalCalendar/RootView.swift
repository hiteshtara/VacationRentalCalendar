import SwiftUI
import VRCCore

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let failure = state.storeFailure {
            ContentUnavailableView(
                "The database could not be opened",
                systemImage: "exclamationmark.triangle",
                description: Text(failure)
            )
            .frame(minWidth: 700, minHeight: 420)
        } else {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
            } detail: {
                detail
            }
            .frame(minWidth: 1020, minHeight: 640)
            .toolbar { toolbarContent }
            .task { state.start() }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $state.selectedPropertyID) {
            Section("Properties") {
                ForEach(state.activeProperties) { property in
                    HStack(spacing: 7) {
                        Image(systemName: "house")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(property.name).font(.system(size: 13))
                            Text(listingSummary(for: property))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .tag(property.id)
                }
            }

            Section("View") {
                ForEach(AppState.Section.allCases) { section in
                    Button {
                        state.selectedSection = section
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: section.symbol)
                                .frame(width: 16)
                            Text(section.title).font(.system(size: 13))
                            Spacer()
                            if let badge = badge(for: section) {
                                Text(badge.text)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(badge.tint.opacity(0.2)))
                                    .foregroundStyle(badge.tint)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 2)
                        .foregroundStyle(state.selectedSection == section ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Protection") {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(state.protectedNights)")
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color(red: 0.72, green: 0.29, blue: 0.84))
                    Text("nights kept sellable because they were never auto-shared")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 3)
            }
        }
        .listStyle(.sidebar)
    }

    private func listingSummary(for property: Property) -> String {
        let count = state.listings.filter { $0.propertyID == property.id }.count
        return "\(count) listing\(count == 1 ? "" : "s")"
    }

    private func badge(for section: AppState.Section) -> (text: String, tint: Color)? {
        switch section {
        case .review:
            let count = state.reviewQueue.count
            return count > 0 ? ("\(count)", .orange) : nil
        case .availability:
            let count = state.pendingDecisions.count
            return count > 0 ? ("\(count)", .blue) : nil
        default:
            return nil
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            switch state.selectedSection {
            case .portfolio: PortfolioView()
            case .calendar: calendarPane
            case .review: ReviewView()
            case .reservations: ReservationsView()
            case .availability: AvailabilityPane()
            case .cloud: CloudPane()
            case .settings: SettingsPane()
            }
            statusBar
        }
        .navigationTitle(state.selectedProperty?.name ?? "Vacation Rental Calendar")
        .navigationSubtitle(state.selectedSection.title)
    }

    @ViewBuilder
    private var calendarPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $state.calendarMode) {
                    ForEach(AppState.CalendarMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)

                Spacer()

                Button { page(-1) } label: { Image(systemName: "chevron.left") }
                Button("Today") { state.anchorDate = DayMath.utcMidnight(Date()) }
                Button { page(1) } label: { Image(systemName: "chevron.right") }

                Text(anchorLabel)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 150, alignment: .trailing)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            HStack(spacing: 12) {
                Toggle(isOn: $state.showPlatformRestrictions) {
                    Text("Show platform restrictions").font(.callout)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if state.hiddenRestrictionCount > 0 {
                    Text("\(state.hiddenRestrictionCount) hidden")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Cancellation blocks, booking-window restrictions and undecided "
                            + "events are hidden. Reservations and conflicts are never hidden, "
                            + "and hiding changes nothing about exports or conflict checks.")
                }

                Spacer()

                Button {
                    state.selectedSection = .availability
                } label: {
                    Label("Block Dates", systemImage: "calendar.badge.minus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Divider()

            FeedWarningBanner()

            switch state.calendarMode {
            case .month: MonthBarsView()
            case .week: WeekStripView()
            case .list: EventListView()
            }

            RangeSelectionBar()
        }
        .inspector(isPresented: $state.isDetailPanelPresented) {
            Group {
                if let selected = state.selectedEvent {
                    EventDetailPanel(item: selected)
                } else {
                    NoEventSelectedView()
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 350, max: 460)
        }
    }

    private func page(_ direction: Int) {
        switch state.calendarMode {
        case .month:
            state.anchorDate = DayMath.utcCalendar
                .date(byAdding: .month, value: direction, to: state.anchorDate) ?? state.anchorDate
        case .week:
            state.anchorDate = DayMath.adding(days: 7 * direction, to: state.anchorDate)
        case .list:
            state.anchorDate = DayMath.adding(days: 30 * direction, to: state.anchorDate)
        }
    }

    private var anchorLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = DayMath.utc
        formatter.dateFormat = state.calendarMode == .month ? "MMMM yyyy" : "MMM d, yyyy"
        return formatter.string(from: state.anchorDate)
    }

    // MARK: - Status bar (requirement: last sync time and any errors)

    private var cloudIndicatorText: String {
        switch state.cloud.health {
        case .healthy: return "AWS staging"
        case .degraded: return "AWS degraded"
        case .unreachable: return "AWS unreachable"
        case .notConfigured: return "AWS off"
        }
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if state.isRefreshing {
                    ProgressView().controlSize(.small)
                    Text("Reading calendars…").font(.caption)
                } else if let error = state.lastError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
                } else {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    Text(state.statusMessage.isEmpty
                         ? lastSyncDescription : state.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !state.notificationAvailability.canNotify {
                    HStack(spacing: 5) {
                        Text(state.notificationAvailability.explanation)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        if state.notificationAvailability.needsSystemSettings {
                            Button("Open Settings") { state.openNotificationSettings() }
                                .buttonStyle(.plain)
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                // Visible from every section, so the state of the cloud
                // connection is never something you have to go looking for.
                Button {
                    state.selectedSection = .cloud
                } label: {
                    HStack(spacing: 4) {
                        if state.isCloudRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            CloudHealthDot(health: state.cloud.health)
                        }
                        Text(cloudIndicatorText).font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                .help(state.cloud.label)

                Text(OutboundSyncGate.isEnabled ? "Outbound ON" : "Outbound off")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var lastSyncDescription: String {
        let dates = state.listings.compactMap(\.lastSyncAt)
        guard let latest = dates.max() else { return "No calendars have been read yet." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last successful sync \(formatter.localizedString(for: latest, relativeTo: Date()))."
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await state.refreshAll() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(state.isRefreshing)
            .keyboardShortcut("r")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                state.refreshFromCloud()
            } label: {
                Label("Refresh from AWS", systemImage: "arrow.clockwise.icloud")
            }
            .disabled(state.isCloudRefreshing || !state.isCloudConfigured)
            .help(state.isCloudConfigured
                  ? "Read status and availability from the AWS staging service"
                  : "No AWS endpoint or credentials stored")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                state.selectedSection = .review
            } label: {
                Label("Needs review", systemImage: "questionmark.circle")
            }
        }
        ToolbarItem(placement: .automatic) {
            Button {
                state.isDetailPanelPresented.toggle()
            } label: {
                Label("Details", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the event details panel")
        }
    }
}
