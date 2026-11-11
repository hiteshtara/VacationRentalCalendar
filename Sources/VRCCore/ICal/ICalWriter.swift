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

        // RFC 5545 §3.4: `icalbody = calprops component`, and
        // `component = 1*(...)` — one or more. A VCALENDAR carrying only
        // calendar properties is therefore not a valid iCalendar object, and a
        // strict subscriber is entitled to reject it. That is what this feed
        // published for a destination with nothing approved for sharing.
        //
        // The component used to satisfy the rule is a VTIMEZONE, and the choice
        // is deliberate: a placeholder VEVENT would satisfy the same grammar,
        // but an outbound feed's events ARE its statement of unavailability, so
        // inventing one would withdraw a night nobody approved. A timezone
        // definition says nothing whatsoever about availability. The feed keeps
        // meaning exactly what it means today — no blocks to report.
        if entries.isEmpty {
            lines.append(contentsOf: Self.easternTimeZoneComponent)
        }

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

    /// A complete VTIMEZONE for `America/New_York`, per RFC 5545 §3.6.5.
    ///
    /// Only used when there is nothing else to put in the calendar, so it is a
    /// constant rather than anything derived from the host's timezone database:
    /// the bytes a subscriber receives must not depend on which machine
    /// generated them, and cross-platform output parity is a release gate here.
    ///
    /// Each observance carries the three REQUIRED properties — DTSTART,
    /// TZOFFSETFROM, TZOFFSETTO. The DTSTARTs are floating local times with no
    /// `Z` and no TZID parameter, which §3.6.5 requires ("MUST be specified as
    /// a date with a local time value"): the offsets are what define the zone,
    /// so expressing their own start in it would be circular.
    ///
    /// The rules are the post-2007 US ones: daylight time begins on the second
    /// Sunday in March and ends on the first Sunday in November, both at 02:00
    /// local. The DTSTART dates are the first occurrences under those rules —
    /// 11 March 2007 and 4 November 2007 — and the RRULEs carry them forward.
    static let easternTimeZoneComponent = [
        "BEGIN:VTIMEZONE",
        "TZID:America/New_York",
        "BEGIN:STANDARD",
        "DTSTART:20071104T020000",
        "TZOFFSETFROM:-0400",
        "TZOFFSETTO:-0500",
        "TZNAME:EST",
        "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU",
        "END:STANDARD",
        "BEGIN:DAYLIGHT",
        "DTSTART:20070311T020000",
        "TZOFFSETFROM:-0500",
        "TZOFFSETTO:-0400",
        "TZNAME:EDT",
        "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU",
        "END:DAYLIGHT",
        "END:VTIMEZONE",
    ]

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
