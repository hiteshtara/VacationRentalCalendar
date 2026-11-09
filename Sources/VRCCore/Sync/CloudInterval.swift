import Foundation

/// Date parsing for the cloud service's interval payloads.
///
/// The service renders days as `YYYY-MM-DD` or `YYYYMMDD`; both are accepted so
/// a format change on one side does not silently produce an empty calendar.
public enum CloudInterval {
    public static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = DayMath.utc
        for format in ["yyyy-MM-dd", "yyyyMMdd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    public static func nights(_ interval: CloudSyncClient.BlockingInterval) -> Int {
        guard let from = day(interval.from), let to = day(interval.to) else { return 0 }
        return max(0, DayMath.daysBetween(from, to))
    }

    public static func describe(_ interval: CloudSyncClient.BlockingInterval) -> String {
        guard let from = day(interval.from), let to = day(interval.to) else {
            return "\(interval.from) → \(interval.to)"
        }
        return "\(DayMath.mediumString(from)) → \(DayMath.mediumString(to))"
    }
}
