import SwiftUI
import VRCCore

struct FeedsView: View {
    @EnvironmentObject var state: AppState
    @State private var editingListingID: Int64?
    @State private var draftURL: String = ""
    @State private var showingAddProperty = false
    @State private var newPropertyName = ""
    @State private var newPropertyAddress = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                safetyBanner
                securityStatus
                refreshSettings
                feedList
                Spacer(minLength: 20)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showingAddProperty) { addPropertySheet }
    }

    // MARK: - Banners

    private var safetyBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("Read-only. Nothing is sent to any platform.")
                    .font(.subheadline.weight(.semibold))
                Text(OutboundSyncGate.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.08)))
    }

    private var securityStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Where your calendar URLs are kept", systemImage: "key.fill")
                .font(.subheadline.weight(.semibold))
            Text("A platform calendar URL is a password in disguise — anyone holding it can read "
                + "your whole booking calendar. They are stored in the macOS Keychain, never in "
                + "the database and never in the project files.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: state.signature.kind.survivesRebuild
                      ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(state.signature.kind.survivesRebuild ? .green : .orange)
                Text(state.signature.explanation)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var refreshSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Automatic refresh", systemImage: "arrow.clockwise")
                .font(.subheadline.weight(.semibold))
            Toggle("Refresh feeds while the app is running", isOn: Binding(
                get: { state.autoRefreshEnabled },
                set: { state.autoRefreshEnabled = $0; state.saveRefreshSettings() }
            ))
            HStack {
                Text("Every")
                Stepper(value: Binding(
                    get: { state.autoRefreshMinutes },
                    set: { state.autoRefreshMinutes = $0; state.saveRefreshSettings() }
                ), in: 5...1440, step: 5) {
                    Text("\(state.autoRefreshMinutes) minutes").monospacedDigit()
                }
                .frame(width: 200)
            }
            .disabled(!state.autoRefreshEnabled)
            Text("Platforms publish calendar changes on their own schedule, often every few hours, "
                + "so refreshing more often than hourly rarely surfaces anything new.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Feeds

    private var feedList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Calendar feeds", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    showingAddProperty = true
                } label: {
                    Label("Add property", systemImage: "plus")
                }
                .controlSize(.small)
            }

            ForEach(state.properties) { property in
                VStack(alignment: .leading, spacing: 8) {
                    Text(property.name).font(.system(size: 13, weight: .semibold))
                    if !property.address.isEmpty {
                        Text(property.address).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(state.listings.filter { $0.propertyID == property.id }) { listing in
                        feedRow(listing)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
    }

    private func feedRow(_ listing: PlatformListing) -> some View {
        let isEditing = editingListingID == listing.id
        let hasCredential = state.hasStoredCredential(for: listing)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(Theme.color(for: listing.platform)).frame(width: 8, height: 8)
                Text(listing.platform.displayName).font(.system(size: 12, weight: .medium))
                    .frame(width: 90, alignment: .leading)

                if hasCredential {
                    Label("In Keychain", systemImage: "key.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Label("No URL yet", systemImage: "minus.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("Auto", isOn: Binding(
                    get: { listing.autoRefreshEnabled },
                    set: { state.setAutoRefresh($0, for: listing) }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)

                Button(isEditing ? "Cancel" : (hasCredential ? "Replace URL" : "Add URL")) {
                    if isEditing {
                        editingListingID = nil
                    } else {
                        draftURL = ""
                        editingListingID = listing.id
                    }
                }
                .controlSize(.small)

                Button("Refresh") {
                    Task { await state.refresh(listing: listing) }
                }
                .controlSize(.small)
                .disabled(!hasCredential || state.isRefreshing)
            }

            // Requirement 8: last successful sync and any error, per feed.
            HStack(spacing: 6) {
                if let last = listing.lastSyncAt {
                    Text("Last sync \(relative(last))")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Never synced").font(.caption2).foregroundStyle(.secondary)
                }
                if !listing.lastSyncSummary.isEmpty {
                    Text("·").font(.caption2).foregroundStyle(.secondary)
                    Text(listing.lastSyncSummary)
                        .font(.caption2)
                        .foregroundStyle(listing.lastSyncSummary.hasPrefix("Failed")
                                         ? .red : .secondary)
                        .lineLimit(1)
                }
            }

            if isEditing {
                VStack(alignment: .leading, spacing: 5) {
                    SecureField("https://… iCal export URL", text: $draftURL)
                        .textFieldStyle(.roundedBorder)
                    Text("Paste the export URL from the platform. It goes straight to the "
                        + "Keychain — it is not written to the database or shown again.")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Save to Keychain") {
                            state.saveFeedURL(for: listing, url: draftURL)
                            draftURL = ""
                            editingListingID = nil
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draftURL.lowercased().hasPrefix("https://")
                                  && !draftURL.lowercased().hasPrefix("webcal://"))
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
            }
        }
        .padding(.vertical, 4)
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var addPropertySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a property").font(.headline)
            TextField("Name, e.g. 39 G Street", text: $newPropertyName)
            TextField("Address (optional)", text: $newPropertyAddress)
            Text("Airbnb, Vrbo and Booking.com listings are created for it. Add each calendar "
                + "URL afterwards.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showingAddProperty = false }
                Button("Add") {
                    state.addProperty(name: newPropertyName, address: newPropertyAddress)
                    newPropertyName = ""
                    newPropertyAddress = ""
                    showingAddProperty = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newPropertyName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct SyncHistoryView: View {
    @EnvironmentObject var state: AppState

    private var listingNames: [Int64: String] {
        Dictionary(uniqueKeysWithValues: state.listings.compactMap { listing in
            listing.id.map { ($0, listing.label) }
        })
    }

    var body: some View {
        if state.syncRuns.isEmpty {
            ContentUnavailableView(
                "No imports yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("Choose Refresh to read your calendars for the first time.")
            )
        } else {
            Table(state.syncRuns) {
                TableColumn("When") { run in
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .width(170)
                TableColumn("Feed") { run in
                    Text(listingNames[run.listingID] ?? "Listing \(run.listingID)")
                }
                TableColumn("Result") { run in
                    HStack(spacing: 5) {
                        Image(systemName: icon(for: run.outcome))
                            .foregroundStyle(colour(for: run.outcome))
                        Text(run.summaryLine).lineLimit(1)
                    }
                }
                .width(340)
                TableColumn("HTTP") { run in
                    Text(run.httpStatus.map(String.init) ?? "—").monospacedDigit()
                }
                .width(60)
            }
        }
    }

    private func icon(for outcome: SyncOutcome) -> String {
        switch outcome {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func colour(for outcome: SyncOutcome) -> Color {
        switch outcome {
        case .success: return .green
        case .failure: return .red
        case .skipped: return .secondary
        }
    }
}
