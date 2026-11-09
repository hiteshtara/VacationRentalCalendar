import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Posts native notifications for problems the owner needs to know about.
///
/// Guarded carefully: `UNUserNotificationCenter.current()` traps when the
/// process has no bundle identifier, which is exactly the case when the app is
/// run straight from `swift run` rather than from the built `.app`. So every
/// entry point checks for a bundle first and reports back whether it actually
/// did anything.
public final class ConflictNotifier: @unchecked Sendable {
    public enum Availability: Sendable, Equatable {
        case available
        /// Permission has never been asked for on this machine.
        case notRequested
        case notBundled
        case denied
        case unknown(String)

        public var canNotify: Bool { self == .available }

        /// Whether System Settings is the only way to change this.
        public var needsSystemSettings: Bool { self == .denied }

        public var explanation: String {
            switch self {
            case .available:
                return "Double bookings will raise a notification."
            case .notRequested:
                return "Notifications have not been set up yet."
            case .notBundled:
                return "Notifications need the installed app. Open VacationRentalCalendar.app "
                    + "rather than running it from the command line."
            case .denied:
                return "Notifications are turned off for this app, so double bookings will only "
                    + "show inside the app. Turn them on in System Settings."
            case .unknown(let detail):
                return "Notifications are unavailable: \(detail)"
            }
        }
    }

    private var announcedConflictIDs: Set<String> = []
    private let lock = NSLock()

    public init() {}

    public static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    /// Reads the current permission **without** asking for it.
    ///
    /// Asking on every launch is both rude and useless — macOS only shows the
    /// prompt once — and it also makes a refusal indistinguishable from a
    /// failure. Reading first means the app can say which one happened.
    public func currentAvailability() async -> Availability {
        #if canImport(UserNotifications)
        guard Self.isBundled else { return .notBundled }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .available
        case .denied: return .denied
        case .notDetermined: return .notRequested
        @unknown default: return .unknown("unrecognised authorisation status")
        }
        #else
        return .notBundled
        #endif
    }

    /// Asks macOS for permission. Only shows a prompt the first time; after
    /// that it returns the standing answer.
    public func requestAuthorization() async -> Availability {
        #if canImport(UserNotifications)
        guard Self.isBundled else { return .notBundled }
        do {
            let centre = UNUserNotificationCenter.current()
            let granted = try await centre.requestAuthorization(options: [.alert, .sound, .badge])
            if granted { return .available }
            // A refusal and an already-denied state look the same here, so ask
            // the system which it was.
            return await currentAvailability() == .notRequested ? .denied : await currentAvailability()
        } catch {
            return .unknown(error.localizedDescription)
        }
        #else
        return .notBundled
        #endif
    }

    /// Opens System Settings at the notifications pane for this app.
    public static func openSystemNotificationSettings() {
        #if canImport(AppKit)
        let identifier = Bundle.main.bundleIdentifier ?? ""
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.notifications?id=\(identifier)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
        #endif
    }

    /// Notifies about double bookings not already announced this session.
    @discardableResult
    public func announce(conflicts: [ReservationConflict]) -> Int {
        #if canImport(UserNotifications)
        guard Self.isBundled else { return 0 }
        let urgent = conflicts.filter { $0.severity == .doubleBooking && !$0.acknowledged }

        lock.lock()
        let fresh = urgent.filter { !announcedConflictIDs.contains($0.id) }
        for conflict in fresh { announcedConflictIDs.insert(conflict.id) }
        lock.unlock()

        for conflict in fresh {
            let content = UNMutableNotificationContent()
            content.title = "Double booking — \(conflict.propertyName)"
            content.body = "\(conflict.dateRangeDescription) is booked on both "
                + "\(conflict.sideA.platform.displayName) and "
                + "\(conflict.sideB.platform.displayName)."
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "conflict-\(conflict.id)", content: content, trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
        return fresh.count
        #else
        return 0
        #endif
    }

    public func announceReviewQueue(count: Int) {
        #if canImport(UserNotifications)
        guard Self.isBundled, count > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(count) date range\(count == 1 ? "" : "s") need review"
        content.body = "Until you classify them they stay unavailable here and sellable "
            + "everywhere else."
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: "review-queue", content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        #endif
    }
}
