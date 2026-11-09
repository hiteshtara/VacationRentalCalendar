import Foundation

/// Builds an RFC 5545 document for outbound use.
///
/// Guest details never reach this writer. Summaries are generic by design: an
/// outbound feed's only job is to say "these nights are taken", and anything
/// more leaks a guest's data to a third-party platform for no benefit.
public struct ICalWriter: Sendable {
    public static let productID = "-//Vacation Rental Calendar//Filtered Export 1.0//EN"
    public static let uidDomain = "vacationrentalcalendar.local"

    public init() {}

    public struct ExportEntry: Sendable {
        public var sourceEventKey: String
        public var checkIn: Date
        public var checkOut: Date
        public var summary: String
        public var isAllDay: Bool

        public init(
            sourceEventKey: String,
            checkIn: Date,
            checkOut: Date,
            summary: String,
            isAllDay: Bool = true
        ) {
            self.sourceEventKey = sourceEventKey
            self.checkIn = checkIn
            self.checkOut = checkOut
            self.summary = summary
            self.isAllDay = isAllDay
        }
    }

    public func makeCalendar(
        name: String,
        entries: [ExportEntry],
        generatedAt: Date = Date()
    ) -> String {
        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:\(Self.productID)",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "X-WR-CALNAME:\(escape(name))",
            "X-WR-CALDESC:\(escape("Filtered availability. Contains only reservations and blocks approved for sharing."))",
        ]

        for entry in entries.sorted(by: { $0.checkIn < $1.checkIn }) {
            lines.append("BEGIN:VEVENT")
            // The outbound UID is derived from, but not equal to, the source
            // UID, so a platform cannot correlate it back to the originating
            // listing.
            let uid = EventKey.sha256("export\u{1F}" + entry.sourceEventKey)
            lines.append("UID:\(uid)@\(Self.uidDomain)")
            lines.append("DTSTAMP:\(DayMath.icalDateTimeString(generatedAt))")
            if entry.isAllDay {
                lines.append("DTSTART;VALUE=DATE:\(DayMath.icalDateString(entry.checkIn))")
                lines.append("DTEND;VALUE=DATE:\(DayMath.icalDateString(entry.checkOut))")
            } else {
                lines.append("DTSTART:\(DayMath.icalDateTimeString(entry.checkIn))")
                lines.append("DTEND:\(DayMath.icalDateTimeString(entry.checkOut))")
            }
            lines.append("SUMMARY:\(escape(entry.summary))")
            lines.append("TRANSP:OPAQUE")
            lines.append("STATUS:CONFIRMED")
            lines.append("END:VEVENT")
        }

        lines.append("END:VCALENDAR")
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 5545 §3.3.11 TEXT escaping.
    public func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }

    /// RFC 5545 §3.1 folding at 75 octets, splitting on UTF-8 boundaries so a
    /// multi-byte character is never cut in half.
    public func fold(_ line: String) -> String {
        let bytes = Array(line.utf8)
        guard bytes.count > 75 else { return line }

        var chunks: [String] = []
        var index = 0
        var limit = 75
        while index < bytes.count {
            var end = min(index + limit, bytes.count)
            // Back off until the slice is valid UTF-8.
            while end > index, String(bytes: bytes[index..<end], encoding: .utf8) == nil {
                end -= 1
            }
            if end == index { end = min(index + limit, bytes.count) }
            chunks.append(String(bytes: bytes[index..<end], encoding: .utf8) ?? "")
            index = end
            limit = 74 // continuation lines carry a leading space
        }
        return chunks.joined(separator: "\r\n ")
    }
}
