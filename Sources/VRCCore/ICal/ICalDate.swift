import Foundation

/// Decoded DTSTART / DTEND.
public struct ICalDateValue: Hashable, Sendable {
    public let date: Date
    public let isDateOnly: Bool
}

public enum ICalDateParser {
    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }

    /// Handles the three forms the rental platforms emit:
    /// `20261107` (VALUE=DATE), `20261107T150000Z` (UTC), and
    /// `20261107T150000` with an optional `TZID` parameter.
    public static func parse(_ line: ICalContentLine) -> ICalDateValue? {
        let raw = line.rawValue.trimmingCharacters(in: .whitespaces)
        let declaredDateOnly = line.parameter("VALUE")?.uppercased() == "DATE"

        if raw.hasSuffix("Z") {
            if let date = formatter("yyyyMMdd'T'HHmmss'Z'", timeZone: DayMath.utc).date(from: raw) {
                return ICalDateValue(date: date, isDateOnly: false)
            }
        }

        if raw.contains("T") {
            let zone = line.parameter("TZID").flatMap { TimeZone(identifier: $0) } ?? DayMath.utc
            if let date = formatter("yyyyMMdd'T'HHmmss", timeZone: zone).date(from: raw) {
                return ICalDateValue(date: date, isDateOnly: false)
            }
        }

        if raw.count == 8,
           let date = formatter("yyyyMMdd", timeZone: DayMath.utc).date(from: raw) {
            return ICalDateValue(date: date, isDateOnly: true)
        }

        // Last resort: a declared DATE that is malformed in length.
        if declaredDateOnly,
           let date = formatter("yyyyMMdd", timeZone: DayMath.utc).date(from: String(raw.prefix(8))) {
            return ICalDateValue(date: date, isDateOnly: true)
        }

        return nil
    }

    /// RFC 5545 DURATION, enough of it for `P3D` / `PT24H` style values that
    /// appear when a feed omits DTEND.
    public static func parseDuration(_ raw: String) -> TimeInterval? {
        var value = raw.uppercased()
        guard value.hasPrefix("P") else { return nil }
        value.removeFirst()
        var total: TimeInterval = 0
        var number = ""
        var inTime = false
        for character in value {
            if character == "T" { inTime = true; continue }
            if character.isNumber { number.append(character); continue }
            guard let amount = Double(number) else { return nil }
            number = ""
            switch character {
            case "W": total += amount * 7 * 86_400
            case "D": total += amount * 86_400
            case "H": total += amount * 3_600
            case "M": total += inTime ? amount * 60 : amount * 30 * 86_400
            case "S": total += amount
            default: return nil
            }
        }
        return total > 0 ? total : nil
    }
}
