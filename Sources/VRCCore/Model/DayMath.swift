import Foundation

/// All-day iCal dates carry no time zone. Everything in this app therefore
/// reduces them to UTC midnight so that day arithmetic cannot drift with the
/// viewer's locale or with daylight saving.
public enum DayMath {
    public static let utc = TimeZone(identifier: "UTC")!

    public static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    public static func utcMidnight(_ date: Date) -> Date {
        let c = utcCalendar
        return c.date(from: c.dateComponents([.year, .month, .day], from: date)) ?? date
    }

    public static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return utcCalendar.date(from: comps)!
    }

    public static func adding(days: Int, to date: Date) -> Date {
        utcCalendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    public static func daysBetween(_ a: Date, _ b: Date) -> Int {
        utcCalendar.dateComponents([.day], from: utcMidnight(a), to: utcMidnight(b)).day ?? 0
    }

    /// `yyyyMMdd`, the form Airbnb/Vrbo/Booking.com all use for all-day events.
    public static func icalDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    public static func icalDateTimeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    public static func mediumString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date)
    }
}
