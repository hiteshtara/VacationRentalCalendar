import SwiftUI
import ServiceManagement
import VRCCore

/// Wraps the Launch at Login service so the UI can offer it only when it will
/// actually work — it needs a real `.app` bundle, so it is unavailable when the
/// binary is run straight from `swift run`.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var lastError: String?

    var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    init() { refresh() }

    func refresh() {
        guard isAvailable else { return }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func set(_ enabled: Bool) {
        guard isAvailable else {
            lastError = "Launch at Login needs the installed app. Open "
                + "VacationRentalCalendar.app rather than running from the command line."
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = "macOS refused that change: \(error.localizedDescription)"
        }
        refresh()
    }
}

@main
struct VacationRentalCalendarApp: App {
    @StateObject private var state = AppState()
    @StateObject private var loginItem = LoginItemController()

    var body: some Scene {
        WindowGroup("Vacation Rental Calendar") {
            RootView()
                .environmentObject(state)
                .environmentObject(loginItem)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh All Calendars") {
                    Task { await state.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            CommandGroup(replacing: .help) {
                Link("How the cancellation-block protection works",
                     destination: URL(string: "https://www.airbnb.com/help/article/990")!)
            }
        }

        // Requirement: optional menu-bar status icon.
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(state)
                .environmentObject(loginItem)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(loginItem)
        }
    }

    private var menuBarSymbol: String {
        if state.doubleBookingCount > 0 { return "calendar.badge.exclamationmark" }
        if !state.reviewQueue.isEmpty { return "calendar.badge.questionmark" }
        return "calendar"
    }
}

/// The menu-bar drop-down: status at a glance, refresh, and a way back to the
/// window. Deliberately small — the real work happens in the main window.
struct MenuBarPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if state.isRefreshing {
            Text("Reading calendars…")
        } else if let latest = state.listings.compactMap(\.lastSyncAt).max() {
            Text("Last sync \(latest.formatted(date: .abbreviated, time: .shortened))")
        } else {
            Text("No calendars read yet")
        }

        if let error = state.lastError {
            Text("Error: \(error)")
        }

        Divider()

        Text("\(state.reviewQueue.count) awaiting review")
        Text("\(state.doubleBookingCount) double booking\(state.doubleBookingCount == 1 ? "" : "s")")
        Text("\(state.protectedNights) nights kept sellable")

        Divider()

        Button("Refresh Now") {
            Task { await state.refreshAll() }
        }
        .disabled(state.isRefreshing)

        Button("Open Vacation Rental Calendar") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            for window in NSApplication.shared.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }

        Divider()

        Text(OutboundSyncGate.isEnabled
             ? "Outbound sync is ON"
             : "Outbound sync off — nothing is sent to any platform")

        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loginItem: LoginItemController

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.set($0) }
                ))
                .disabled(!loginItem.isAvailable)
                if !loginItem.isAvailable {
                    Text("Available once the app is installed in /Applications and launched "
                        + "from there.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = loginItem.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Refresh") {
                Toggle("Refresh automatically while running", isOn: Binding(
                    get: { state.autoRefreshEnabled },
                    set: { state.autoRefreshEnabled = $0; state.saveRefreshSettings() }
                ))
                Stepper(value: Binding(
                    get: { state.autoRefreshMinutes },
                    set: { state.autoRefreshMinutes = $0; state.saveRefreshSettings() }
                ), in: 5...1440, step: 5) {
                    Text("Every \(state.autoRefreshMinutes) minutes").monospacedDigit()
                }
                .disabled(!state.autoRefreshEnabled)
            }

            Section("Notifications") {
                Text(state.notificationAvailability.explanation)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Security") {
                Text(state.signature.explanation)
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Database", value: AppPaths.databaseURL.path)
                    .font(.caption)
            }

            Section("Outbound synchronisation") {
                Label(
                    OutboundSyncGate.isEnabled ? "Enabled" : "Disabled",
                    systemImage: OutboundSyncGate.isEnabled ? "lock.open" : "lock.fill"
                )
                .foregroundStyle(OutboundSyncGate.isEnabled ? .orange : .green)
                Text(OutboundSyncGate.explanation)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
    }
}
