import SwiftUI
import VRCCore
import VRCSync
import VRCUI

/// The iPhone interface.
///
/// Written with cross-platform SwiftUI only, so that it is compiled and
/// type-checked by `swift build` on the Mac even though it ships on iOS. The
/// handful of genuinely iOS-only modifiers are guarded.
@MainActor
public struct PhoneRootView: View {
    @StateObject private var state: PhoneState

    public init(state: PhoneState? = nil) {
        // Built lazily inside the autoclosure so the main-actor-isolated
        // initialiser is not called from a nonisolated context.
        _state = StateObject(wrappedValue: state ?? PhoneState())
    }

    public var body: some View {
        TabView {
            PhoneCalendarTab(state: state)
                .tabItem { Label("Calendar", systemImage: "calendar") }

            PhoneReviewTab(state: state)
                .tabItem { Label("Review", systemImage: "questionmark.circle") }
                .badge(state.reviewQueue.count)

            PhoneConflictsTab(state: state)
                .tabItem { Label("Conflicts", systemImage: "exclamationmark.triangle") }
                .badge(state.doubleBookings.count)

            PhoneSyncTab(state: state)
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
        }
        .task { await state.sync() }
    }
}

// MARK: - Calendar

struct PhoneCalendarTab: View {
    @ObservedObject var state: PhoneState

    private var monthStart: Date {
        let calendar = DayMath.utcCalendar
        return calendar.date(
            from: calendar.dateComponents([.year, .month], from: state.anchorDate)
        ) ?? state.anchorDate
    }

    private var days: [Date] {
        let calendar = DayMath.utcCalendar
        let weekday = calendar.component(.weekday, from: monthStart)
        let start = DayMath.adding(days: -(weekday - 1), to: monthStart)
        return (0..<42).map { DayMath.adding(days: $0, to: start) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                propertyPicker
                monthHeader
                grid
                Divider()
                dayDetail
            }
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await state.sync() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(state.isSyncing)
                }
            }
        }
    }

    @ViewBuilder
    private var propertyPicker: some View {
        if state.properties.count > 1 {
            Picker("Property", selection: $state.selectedPropertyID) {
                ForEach(state.properties) { property in
                    Text(property.name).tag(property.id)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 12)
        }
    }

    private var monthHeader: some View {
        HStack {
            Button {
                state.anchorDate = DayMath.utcCalendar
                    .date(byAdding: .month, value: -1, to: state.anchorDate) ?? state.anchorDate
            } label: { Image(systemName: "chevron.left") }

            Spacer()
            Text(monthLabel).font(.headline).monospacedDigit()
            Spacer()

            Button {
                state.anchorDate = DayMath.utcCalendar
                    .date(byAdding: .month, value: 1, to: state.anchorDate) ?? state.anchorDate
            } label: { Image(systemName: "chevron.right") }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var monthLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = DayMath.utc
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: state.anchorDate)
    }

    private var grid: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(["S", "M", "T", "W", "T", "F", "S"], id: \.self) { name in
                    Text(name).font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7),
                spacing: 2
            ) {
                ForEach(days, id: \.timeIntervalSince1970) { day in
                    PhoneDayCell(
                        day: day,
                        items: state.events(on: day),
                        isInMonth: DayMath.utcCalendar.component(.month, from: day)
                            == DayMath.utcCalendar.component(.month, from: monthStart),
                        isSelected: state.selectedDay.map {
                            DayMath.utcMidnight($0) == DayMath.utcMidnight(day)
                        } ?? false
                    )
                    .onTapGesture { state.selectedDay = day }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var dayDetail: some View {
        let day = state.selectedDay ?? DayMath.utcMidnight(Date())
        let items = state.events(on: day)
        VStack(alignment: .leading, spacing: 6) {
            Text(DayMath.mediumString(day)).font(.subheadline.weight(.semibold))
            if items.isEmpty {
                Label("Open — available on every platform", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { item in
                            HStack(spacing: 8) {
                                EventChip(item: item).frame(width: 190)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.event.platform.displayName)
                                        .font(.caption.weight(.medium))
                                    Text("\(item.event.nights) night"
                                         + (item.event.nights == 1 ? "" : "s"))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PhoneDayCell: View {
    let day: Date
    let items: [ClassifiedEvent]
    let isInMonth: Bool
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text("\(DayMath.utcCalendar.component(.day, from: day))")
                .font(.system(size: 12))
                .foregroundStyle(isInMonth ? .primary : Color.secondary.opacity(0.4))
            HStack(spacing: 1) {
                ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, item in
                    Circle()
                        .fill(Theme.isSellable(item.classification)
                              ? Color.clear : Theme.color(for: item.classification.kind))
                        .overlay(
                            Circle().strokeBorder(
                                Theme.color(for: item.classification.kind),
                                lineWidth: Theme.isSellable(item.classification) ? 1 : 0
                            )
                        )
                        .frame(width: 5, height: 5)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Review

struct PhoneReviewTab: View {
    @ObservedObject var state: PhoneState

    var body: some View {
        NavigationStack {
            Group {
                if state.reviewQueue.isEmpty {
                    ContentUnavailableView(
                        "Nothing to review",
                        systemImage: "checkmark.seal",
                        description: Text("Every imported date has a decision recorded.")
                    )
                } else {
                    List(state.reviewQueue) { item in
                        NavigationLink {
                            PhoneReviewDetail(state: state, item: item)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Circle().fill(Theme.color(for: item.event.platform))
                                        .frame(width: 7, height: 7)
                                    Text(item.event.platform.displayName)
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Text("\(item.event.nights)n")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text("\(DayMath.mediumString(item.event.checkIn)) → "
                                    + "\(DayMath.mediumString(item.event.checkOut))")
                                    .font(.subheadline)
                                Text(item.event.summary.isEmpty ? "(no title)" : item.event.summary)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Needs Review")
        }
    }
}

struct PhoneReviewDetail: View {
    @ObservedObject var state: PhoneState
    let item: ClassifiedEvent
    @State private var note = ""

    var body: some View {
        List {
            Section("These dates") {
                LabeledContent("Platform", value: item.event.platform.displayName)
                LabeledContent("From", value: DayMath.mediumString(item.event.checkIn))
                LabeledContent("To", value: DayMath.mediumString(item.event.checkOut))
                LabeledContent("Nights", value: "\(item.event.nights)")
            }

            Section("What the platform sent") {
                Text(item.event.summary.isEmpty ? "(no summary)" : item.event.summary)
                if item.event.details.isEmpty {
                    Text("No description, which is why it cannot be classified automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("What the app concluded") {
                Text(item.classification.kind.displayName)
                    .foregroundStyle(Theme.color(for: item.classification.kind))
                Text(item.classification.rationale)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Your decision") {
                ForEach(BlockKind.allCases) { kind in
                    Button {
                        state.classify(eventKey: item.event.eventKey, as: kind, note: note)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.displayName)
                                .foregroundStyle(Theme.color(for: kind))
                            Text(kind.guidance)
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                TextField("Note (optional)", text: $note, axis: .vertical)
            }

            Section {
                Text("Saved to this iPhone and synced to your Mac. Later imports never "
                    + "overwrite a decision you made.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Review")
    }
}

// MARK: - Conflicts

struct PhoneConflictsTab: View {
    @ObservedObject var state: PhoneState

    var body: some View {
        NavigationStack {
            Group {
                if state.conflicts.isEmpty {
                    ContentUnavailableView(
                        "No overlaps",
                        systemImage: "checkmark.shield",
                        description: Text("No two reservations claim the same unit at once.")
                    )
                } else {
                    List {
                        ForEach(state.conflicts) { conflict in
                            Section {
                                side(conflict.sideA)
                                side(conflict.sideB)
                                if conflict.severity == .doubleBooking {
                                    Button("Acknowledge") { state.acknowledge(conflict) }
                                        .disabled(conflict.acknowledged)
                                }
                            } header: {
                                HStack(spacing: 6) {
                                    if conflict.severity.isUrgent {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.red)
                                    }
                                    Text("\(conflict.severity.displayName) · "
                                        + conflict.dateRangeDescription)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Conflicts")
        }
    }

    private func side(_ value: ConflictSide) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(Theme.color(for: value.platform)).frame(width: 7, height: 7)
                Text(value.platform.displayName).font(.caption.weight(.semibold))
            }
            Text(value.summary).font(.subheadline)
            Text("\(DayMath.mediumString(value.checkIn)) → \(DayMath.mediumString(value.checkOut))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sync and per-device setup

struct PhoneSyncTab: View {
    @ObservedObject var state: PhoneState
    @State private var editing: Int64?
    @State private var draftURL = ""

    var body: some View {
        NavigationStack {
            List {
                Section("iCloud") {
                    LabeledContent("Status", value: state.accountStatus.explanation)
                    LabeledContent("Last sync", value: state.lastSyncDescription)
                    if !state.syncMessage.isEmpty {
                        Text(state.syncMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = state.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Button {
                        Task { await state.sync() }
                    } label: {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(state.isSyncing)
                }

                let disagreements = state.syncDisagreements()
                if !disagreements.isEmpty {
                    Section("Your devices disagree") {
                        ForEach(disagreements, id: \.eventKey) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(row.local.displayName) here, "
                                    + "\(row.remote.displayName) on your Mac")
                                    .font(.subheadline)
                                Text("Not shared with any platform until you confirm.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Calendar feeds on this iPhone") {
                    Text("Feed URLs are not carried by iCloud. Add them here if you want this "
                        + "iPhone to read the platforms directly; otherwise it shows what your "
                        + "Mac imported.")
                        .font(.caption).foregroundStyle(.secondary)

                    ForEach(state.listings) { listing in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Circle().fill(Theme.color(for: listing.platform))
                                    .frame(width: 8, height: 8)
                                Text(listing.platform.displayName).font(.subheadline)
                                Spacer()
                                if state.hasCredential(for: listing) {
                                    Label("Set up", systemImage: "key.fill")
                                        .font(.caption).foregroundStyle(.green)
                                } else {
                                    Button(editing == listing.id ? "Cancel" : "Add URL") {
                                        draftURL = ""
                                        editing = editing == listing.id ? nil : listing.id
                                    }
                                    .font(.caption)
                                }
                            }
                            if editing == listing.id {
                                SecureField("https://…", text: $draftURL)
                                Button("Save to this iPhone's Keychain") {
                                    state.saveFeedURL(for: listing, url: draftURL)
                                    draftURL = ""
                                    editing = nil
                                }
                                .disabled(!draftURL.lowercased().hasPrefix("https://"))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("Protection") {
                    LabeledContent("Nights kept sellable", value: "\(state.protectedNights)")
                    Text(OutboundSyncGate.explanation)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sync")
        }
    }
}
