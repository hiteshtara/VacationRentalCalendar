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
    // A headless self-check, used to verify end-to-end that THIS code object
    // — the signed app binary — can reach the service and read back a
    // sanitized status. It runs the exact in-process path the Cloud pane uses,
    // prints a secret-free summary, and exits before any window opens. It is
    // the app's own answer to "can Refresh from AWS succeed?", gathered
    // without a human clicking.
    /// Machine-readable credential health, printed by the SIGNED APP BINARY.
    ///
    /// The installation, backup and migration scripts used
    /// `/usr/bin/security` for this. That cannot work after the move to the
    /// data protection Keychain: `security` operates on the file Keychain
    /// only and has no flag to do otherwise, so every script would keep
    /// running and quietly report the wrong answer — backup calling every live
    /// credential missing, migration skipping everything.
    ///
    /// It has to be THIS binary rather than the `vrc` helper, because a bare
    /// executable cannot carry the `keychain-access-groups` entitlement. The
    /// app bundle can, so the app is the only thing able to answer the
    /// question for production credentials.
    ///
    /// Presence is checked with `exists`, which reads attributes only and
    /// never prompts; a value is only read for references that actually have
    /// an item behind them. Output is one line per listing plus a summary, and
    /// carries no secret — references are names, not values.
    /// Which credential store this build selects, and why.
    ///
    /// Deliberately touches NOTHING: no database, no Keychain item, no
    /// credential. It exists so a freshly signed build can be verified to
    /// select the data protection Keychain before it is allowed anywhere near
    /// a real credential.
    static func runCredentialStoreIfRequested() {
        guard CommandLine.arguments.contains("--credential-store") else { return }
        print("team-signed \(AppleTeam.runningCodeCanUseAccessGroup)")
        print("running-team \(AppleTeam.runningTeamIdentifier() ?? "(none)")")
        print("expected-team \(AppleTeam.identifier)")
        print("data-protection \(CredentialStoreSelection.shouldUseDataProtection)")
        print("access-group \(AppleTeam.keychainPolicy.accessGroup ?? "(none)")")
        print("explanation \(CredentialStoreSelection.explanation)")
        exit(CredentialStoreSelection.shouldUseDataProtection ? 0 : 1)
    }

    /// Imports one secret from standard input.
    ///
    ///     security find-generic-password -s <service> -a <ref> -w \
    ///         | VacationRentalCalendar --import-secret <ref>
    ///
    /// For the Booking.com outbound feed token, which this application cannot
    /// read: its ACL trusts only `/usr/bin/security` and its partition is
    /// `apple-tool:`. Unlike a feed URL it cannot be re-entered, because
    /// Booking.com is already subscribed to the URL containing it.
    ///
    /// The value arrives on **stdin only**. Never an argument: a command line
    /// is visible in `ps` and recorded in shell history, and a feed token is a
    /// bearer credential for a whole booking calendar. Nothing is echoed and
    /// only a digest is printed.
    static func runImportSecretIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--import-secret") else { return }
        guard flag + 1 < arguments.count else {
            FileHandle.standardError.write(Data(
                "error: --import-secret needs a reference name\n".utf8))
            exit(2)
        }
        let reference = arguments[flag + 1]

        // Refuse an interactive terminal. The designed caller is a pipe from
        // `security`; reading from a TTY here would mean the owner typing a
        // token that is already stored, which is both pointless and a way to
        // get it wrong.
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else {
            FileHandle.standardError.write(Data("""
                error: pipe the value in; do not type it and do not pass it as an argument.
                  security find-generic-password -s com.vacationrentalcalendar.feed-url \\
                      -a \(reference) -w | <this app> --import-secret \(reference)

                """.utf8))
            exit(2)
        }

        let incoming = String(
            data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""

        do {
            let store = try RentalStore.makeDefault()
            let report = try SecretImport.perform(
                reference: reference, value: incoming, into: store.credentials)
            // Digest only. There is no code path here that prints the value.
            print(report.description)
            print("stored in \(store.credentials.storageDescription)")
            print("the legacy entry was not read, altered or deleted")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data(
                ("error: " + ((error as? LocalizedError)?.errorDescription
                              ?? "\(error)") + "\n").utf8))
            exit(1)
        }
    }

    static func runCredentialHealthIfRequested() {
        guard CommandLine.arguments.contains("--credential-health") else { return }
        func out(_ text: String) { print(text) }

        do {
            let store = try RentalStore.makeDefault()
            out("store \(store.credentials.storageDescription)")
            out("selection \(CredentialStoreSelection.explanation)")

            let health = try store.credentialHealth()
            for report in health {
                let reference = report.listing.credentialRef.isEmpty
                    ? "(none)" : report.listing.credentialRef
                out("\(report.status.rawValue)\t\(reference)\t\(report.listing.label)")
            }
            let unreadable = health.filter { $0.status == .unreadable }.count
            out("summary readable=\(health.filter { $0.status == .readable }.count) "
                + "unreadable=\(unreadable) "
                + "notConfigured=\(health.filter { $0.status == .notConfigured }.count)")
            exit(unreadable == 0 ? 0 : 1)
        } catch {
            out("error \(error)")
            exit(2)
        }
    }

    /// Moves every stored secret into the data protection Keychain.
    ///
    ///     VacationRentalCalendar --migrate-credentials [--dry-run]
    ///
    /// Only this code object can do it: the data protection Keychain needs the
    /// `keychain-access-groups` entitlement, which a bare executable cannot
    /// carry, so the `vrc` helper is not an option.
    ///
    /// It enumerates the KEYCHAIN, not the database. Of the six live secrets
    /// only three are referenced by any table — the two AWS keys appear in no
    /// table and the Booking.com outbound token appears nowhere at all — so a
    /// listings-driven migration would quietly leave three behind, one of them
    /// a token the platform is already subscribed to and which cannot be
    /// reproduced.
    ///
    /// Prints references, outcomes and digests. Never a value.
    static func runMigrateCredentialsIfRequested() {
        guard CommandLine.arguments.contains("--migrate-credentials") else { return }
        let dryRun = CommandLine.arguments.contains("--dry-run")
        func out(_ text: String) { print(text) }
        func fail(_ text: String, code: Int32) -> Never {
            FileHandle.standardError.write(Data((text + "\n").utf8))
            exit(code)
        }

        guard CredentialStoreSelection.shouldUseDataProtection else {
            fail("""
                REFUSED: this build is not signed by team \(AppleTeam.identifier), so the \
                data protection Keychain is unavailable and there is nowhere to migrate to.
                  \(CredentialStoreSelection.explanation)
                """, code: 3)
        }

        let legacy = KeychainFeedCredentialStore(
            additionalTrustedPaths: AppPaths.siblingExecutablePaths())
        let modern = DataProtectionFeedCredentialStore(policy: AppleTeam.keychainPolicy)

        guard let store = try? RentalStore.makeDefault() else {
            fail("error: could not open the database", code: 2)
        }

        // Classification is evidenced, not inferred: a listing carrying a
        // reference name proves nothing, because every listing is created with
        // one. An unconfigured listing is not a missing secret; a configured
        // one whose item is gone is, and it stops the run.
        let listings = (try? store.listings.all()) ?? []
        let successful = Set(((try? store.syncRuns.recent(limit: 5_000)) ?? [])
            .filter { $0.outcome == .success }.map(\.listingID))
        var configured: [String] = []
        var unconfigured: [String] = []
        for listing in listings where !listing.credentialRef.isEmpty {
            let everSynced = listing.id.map { successful.contains($0) } ?? false
            if CredentialInventory.wasConfigured(listing, hasSuccessfulImport: everSynced) {
                configured.append(listing.credentialRef)
            } else {
                unconfigured.append(listing.credentialRef)
            }
        }

        let inventory = CredentialInventory.compare(
            configuredReferences: configured,
            unconfiguredReferences: unconfigured,
            keychainReferences: legacy.allReferences())

        out("source \(legacy.storageDescription)")
        out("destination \(modern.storageDescription)")
        out(inventory.summary)
        guard inventory.isSafeToMigrate else {
            fail("REFUSED: \(inventory.referencedButMissing.count) configured listing(s) "
                + "reference a secret that is not in the Keychain. Nothing was written.",
                code: 4)
        }

        let references = inventory.toMigrate
        let plan: [CredentialMigration.Step]
        do {
            plan = try CredentialMigration.plan(
                references: references, from: legacy, to: modern)
        } catch {
            fail("error: could not plan the migration: \(error)", code: 2)
        }
        for step in plan { out("plan \(step)") }

        if dryRun {
            out("dry run — nothing was written")
            exit(0)
        }

        let result: CredentialMigration.Result
        do {
            result = try CredentialMigration.apply(plan, from: legacy, to: modern)
        } catch {
            fail("error: the migration stopped: \(error)", code: 5)
        }
        out("result migrated=\(result.migrated) alreadyPresent=\(result.alreadyPresent) "
            + "notConfigured=\(result.notConfigured) failed=\(result.failed)")

        // The gate. Derived from the destination, so a half-finished run can
        // never read as finished just because the layered store still works.
        let completeness = MigrationCompleteness.evaluate(
            expected: references, destination: modern)
        out("completeness \(completeness.headline)")
        if !completeness.detail.isEmpty { out(completeness.detail) }
        exit(completeness.isComplete ? 0 : 6)
    }

    /// Reports whether the migration finished, without migrating anything.
    static func runMigrationStatusIfRequested() {
        guard CommandLine.arguments.contains("--migration-status") else { return }
        let legacy = KeychainFeedCredentialStore(
            additionalTrustedPaths: AppPaths.siblingExecutablePaths())
        let expected = legacy.allReferences()
        guard CredentialStoreSelection.shouldUseDataProtection else {
            print("not migrated — \(CredentialStoreSelection.explanation)")
            print("source holds \(expected.count) item(s)")
            exit(1)
        }
        let modern = DataProtectionFeedCredentialStore(policy: AppleTeam.keychainPolicy)
        let status = MigrationCompleteness.evaluate(expected: expected, destination: modern)
        print(status.headline)
        if !status.detail.isEmpty { print(status.detail) }
        for reference in status.copied { print("copied\t\(reference)") }
        for reference in status.outstanding { print("outstanding\t\(reference)") }
        exit(status.isComplete ? 0 : 1)
    }

    static func runSelfCheckIfRequested() {
        guard CommandLine.arguments.contains("--self-check-cloud") else { return }
        // In process now, not through the helper: the same code the Cloud
        // pane uses, so the self-check exercises what actually ships.
        guard let store = try? RentalStore.makeDefault() else {
            FileHandle.standardError.write(Data("gui-self-check store unavailable\n".utf8))
            exit(2)
        }
        let payload = CloudStatusService.status(
            for: CloudConnection(settings: store.settings, credentials: store.credentials))
        switch Result<CloudStatusPayload, Never>.success(payload) {
        case .success(let payload):
            let summary = "gui-self-check ok=\(payload.ok) health=\(payload.health.rawValue) "
                + "message=\(payload.message) intervals=\(payload.intervals.count)\n"
            FileHandle.standardError.write(Data(summary.utf8))
            for interval in payload.intervals {
                let line = "gui-self-check interval \(interval.from)->\(interval.to) "
                    + "\(interval.source)/\(interval.basis)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            exit(payload.ok ? 0 : 3)
        case .failure(let failure):
            FileHandle.standardError.write(Data("gui-self-check failure=\(failure)\n".utf8))
            exit(4)
        }
    }

    @StateObject private var state = AppState()
    @StateObject private var loginItem = LoginItemController()

    init() {
        Self.runCredentialStoreIfRequested()
        Self.runCredentialHealthIfRequested()
        Self.runImportSecretIfRequested()
        Self.runMigrateCredentialsIfRequested()
        Self.runMigrationStatusIfRequested()
        Self.runSelfCheckIfRequested()
    }

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
                LabeledContent("Double bookings") {
                    Text(state.notificationAvailability.canNotify ? "On" : "Off")
                        .foregroundStyle(state.notificationAvailability.canNotify ? .green : .orange)
                }
                Text(state.notificationAvailability.explanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if state.notificationAvailability.needsSystemSettings {
                    Button("Open notification settings") {
                        state.openNotificationSettings()
                    }
                } else if !state.notificationAvailability.canNotify
                            && state.notificationAvailability != .notBundled {
                    Button("Turn on notifications") {
                        Task { await state.requestNotificationPermission() }
                    }
                }
                Button("Check again") {
                    Task { await state.refreshNotificationStatus() }
                }
                .buttonStyle(.link)
                .font(.caption)
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
