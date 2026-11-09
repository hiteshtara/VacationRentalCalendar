import Foundation
#if canImport(UserNotifications)
import UserNotifications
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
        case notBundled
        case denied
        case unknown(String)

        public var canNotify: Bool { self == .available }

        public var explanation: String {
            switch self {
            case .available:
                return "Notifications are on."
            case .notBundled:
                return "Notifications need the built app. Launch VacationRentalCalendar.app "
                    + "rather than running from the command line."
            case .denied:
                return "Notifications are turned off for this app in System Settings."
            case .unknown(let detail):
                return "Notifications are unavailable: \(detail)"
            }
        }
    }

    private var announcedConflictIDs: Set<String> = []
    private let lock = NSLock()

    public init() {}

    public static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    public func requestAuthorization() async -> Availability {
        #if canImport(UserNotifications)
        guard Self.isBundled else { return .notBundled }
        do {
            let centre = UNUserNotificationCenter.current()
            let granted = try await centre.requestAuthorization(options: [.alert, .sound])
            return granted ? .available : .denied
        } catch {
            return .unknown(error.localizedDescription)
        }
        #else
        return .notBundled
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
