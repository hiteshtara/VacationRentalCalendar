import Foundation
import VRCCore

/// A calendar with nothing to report must still be a valid iCalendar object.
///
/// RFC 5545 §3.4 defines the body of a VCALENDAR as `icalbody = calprops
/// component`, where `component = 1*(eventc / todoc / journalc / freebusyc /
/// timezonec / iana-comp / x-comp)`. `1*` means **one or more**: a VCALENDAR
/// carrying only calendar properties and no components does not satisfy the
/// grammar. This app published exactly that for a property with no approved
/// blocks — 297 bytes, zero components — and a subscriber held its connection
/// at "Activating" without ever saying why.
///
/// The fix must not be a placeholder VEVENT. An outbound feed states which
/// nights are unavailable, so inventing an event to satisfy a grammar would be
/// inventing unavailability, and this project's whole reason for existing is
/// that a night withdrawn by mistake is revenue nobody notices. A VTIMEZONE
/// satisfies `1*component` while asserting nothing at all about availability:
/// it is a definition, not a block.
public enum EmptyCalendarTests {

    static let writer = ICalWriter()

    /// The empty case: a destination with nothing approved for sharing.
    static var emptyCalendar: String {
        writer.makeCalendar(name: "39 G Street → Booking.com", entries: [],
                            generatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// The populated case, which must come out exactly as it always has.
    static var populatedCalendar: String {
        writer.makeCalendar(
            name: "39 G Street → Vrbo",
            entries: [ICalWriter.ExportEntry(
                sourceEventKey: "k1",
                checkIn: DayMath.day(2026, 12, 10), checkOut: DayMath.day(2026, 12, 17),
                summary: "Not available")],
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// Lines, unfolded, with the CRLF pairs removed.
    static func lines(_ ics: String) -> [String] {
        ics.components(separatedBy: "\r\n").filter { !$0.isEmpty }
    }

    static func count(_ ics: String, _ needle: String) -> Int {
        lines(ics).filter { $0 == needle }.count
    }

    public static var cases: [TestCase] { [

        // --- The grammar rule itself -----------------------------------------

        TestCase(group: "Empty calendar",
                 name: "an empty calendar still contains at least one component") { expect in
            // The RFC rule, stated directly. Every component production is
            // checked so this cannot be satisfied by something unintended.
            let ics = emptyCalendar
            let components = ["VEVENT", "VTODO", "VJOURNAL", "VFREEBUSY", "VTIMEZONE"]
                .reduce(into: 0) { total, name in total += count(ics, "BEGIN:\(name)") }
            expect.ok(components >= 1,
                      "icalbody = calprops component, where component is 1*(...); found \(components)")
        },

        TestCase(group: "Empty calendar",
                 name: "the component is a VTIMEZONE, not an invented event") { expect in
            // The distinction that matters. A placeholder VEVENT would also
            // satisfy the grammar and would be a synthetic block.
            let ics = emptyCalendar
            expect.equal(count(ics, "BEGIN:VTIMEZONE"), 1)
            expect.equal(count(ics, "BEGIN:VEVENT"), 0, "no event may be invented")
        },

        // --- The timezone definition's own validity --------------------------

        TestCase(group: "Empty calendar",
                 name: "the VTIMEZONE carries a TZID") { expect in
            // RFC 5545 §3.6.5: TZID is REQUIRED and must occur once.
            let ics = emptyCalendar
            expect.equal(count(ics, "TZID:America/New_York"), 1)
        },

        TestCase(group: "Empty calendar",
                 name: "the VTIMEZONE has both STANDARD and DAYLIGHT observances") { expect in
            // §3.6.5 requires at least one of the two. Eastern time has both,
            // and a definition carrying only one would misreport half the year.
            let ics = emptyCalendar
            expect.equal(count(ics, "BEGIN:STANDARD"), 1)
            expect.equal(count(ics, "END:STANDARD"), 1)
            expect.equal(count(ics, "BEGIN:DAYLIGHT"), 1)
            expect.equal(count(ics, "END:DAYLIGHT"), 1)
        },

        TestCase(group: "Empty calendar",
                 name: "each observance has the three properties the RFC requires") { expect in
            // §3.6.5: DTSTART, TZOFFSETFROM and TZOFFSETTO are REQUIRED in
            // every STANDARD and DAYLIGHT subcomponent. Checked per-observance
            // rather than over the whole document, so one observance carrying
            // both copies cannot pass for two.
            let all = lines(emptyCalendar)
            for observance in ["STANDARD", "DAYLIGHT"] {
                guard let open = all.firstIndex(of: "BEGIN:\(observance)"),
                      let close = all.firstIndex(of: "END:\(observance)"), open < close else {
                    expect.fail("no \(observance) observance to check")
                    continue
                }
                let body = all[(open + 1)..<close]
                for required in ["DTSTART", "TZOFFSETFROM", "TZOFFSETTO"] {
                    expect.equal(body.filter { $0.hasPrefix("\(required):") }.count, 1,
                                 "\(observance) must carry exactly one \(required)")
                }
            }
        },

        TestCase(group: "Empty calendar",
                 name: "observance DTSTARTs are floating local time, as the RFC demands") { expect in
            // §3.6.5: "the DTSTART property value MUST be specified as a date
            // with a local time value" — no UTC Z suffix and no TZID parameter,
            // because the offsets are what define the zone. Getting this wrong
            // is the classic VTIMEZONE error and parsers do reject it.
            for line in lines(emptyCalendar).filter({ $0.hasPrefix("DTSTART") }) {
                expect.ok(!line.hasSuffix("Z"), "\(line) must not be UTC")
                expect.notContains(line, "TZID=")
                expect.ok(line.hasPrefix("DTSTART:"), "no parameters belong here: \(line)")
            }
        },

        TestCase(group: "Empty calendar",
                 name: "the offsets are the real ones for US Eastern time") { expect in
            // -0500 standard, -0400 daylight. A definition that parses but
            // states the wrong offsets is worse than none: it would shift every
            // date a subscriber derives from it.
            let all = lines(emptyCalendar)
            guard let standard = all.firstIndex(of: "BEGIN:STANDARD"),
                  let daylight = all.firstIndex(of: "BEGIN:DAYLIGHT") else {
                return expect.fail("observances missing")
            }
            let standardBody = all[standard..<(all.firstIndex(of: "END:STANDARD") ?? standard)]
            let daylightBody = all[daylight..<(all.firstIndex(of: "END:DAYLIGHT") ?? daylight)]
            expect.ok(standardBody.contains("TZOFFSETTO:-0500"), "EST is UTC-5")
            expect.ok(standardBody.contains("TZOFFSETFROM:-0400"))
            expect.ok(daylightBody.contains("TZOFFSETTO:-0400"), "EDT is UTC-4")
            expect.ok(daylightBody.contains("TZOFFSETFROM:-0500"))
        },

        // --- What must NOT have changed --------------------------------------

        TestCase(group: "Empty calendar",
                 name: "a populated calendar gains no timezone and is otherwise untouched") { expect in
            // The blast radius. Every feed that already had events must render
            // byte-for-byte as before, or this change quietly rewrites the
            // feeds the platforms are already subscribed to.
            let ics = populatedCalendar
            expect.equal(count(ics, "BEGIN:VTIMEZONE"), 0,
                         "the timezone exists only to satisfy the empty case")
            expect.equal(count(ics, "BEGIN:VEVENT"), 1)
            expect.equal(ics, [
                "BEGIN:VCALENDAR", "VERSION:2.0",
                "PRODID:\(ICalWriter.productID)",
                "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
                "X-WR-CALNAME:39 G Street \u{2192} Vrbo",
                "X-WR-CALDESC:Filtered availability. Contains only reservations and blocks a",
                " pproved for sharing.",
                "BEGIN:VEVENT",
                "UID:783e72716029e0f00f4aa98b0bb640f017da1ca8e9e536dc59c5f1159f73c8c1@vacati",
                " onrentalcalendar.local",
                "DTSTAMP:20270115T080000Z",
                "DTSTART;VALUE=DATE:20261210", "DTEND;VALUE=DATE:20261217",
                "SUMMARY:Not available", "TRANSP:OPAQUE", "STATUS:CONFIRMED",
                "END:VEVENT", "END:VCALENDAR",
            ].joined(separator: "\r\n") + "\r\n")
        },

        TestCase(group: "Empty calendar",
                 name: "the empty calendar withdraws no nights and names no guest") { expect in
            // Read back through the app's own parser: whatever we added must
            // not be interpretable as unavailability by anything downstream.
            let ics = emptyCalendar
            let parsed = try! ICalParser.parse(ics)
            expect.equal(parsed.events.count, 0, "an empty feed blocks nothing")
            expect.equal(parsed.productID, ICalWriter.productID, "identifiers are preserved")
            expect.notContains(ics, "SUMMARY")
            expect.notContains(ics, "ATTENDEE")
            expect.notContains(ics, "ORGANIZER")
            expect.notContains(ics, "DESCRIPTION:")
        },

        TestCase(group: "Empty calendar",
                 name: "the timezone's RRULE is not mistaken for a recurring event") { expect in
            // The parser flags RRULE inside a VEVENT for human review. A
            // recurrence rule in a VTIMEZONE is ordinary and must stay silent,
            // or every import of our own feed raises a warning about nothing.
            let parsed = try! ICalParser.parse(emptyCalendar)
            expect.ok(parsed.warnings.isEmpty, "warnings were \(parsed.warnings)")
        },

        TestCase(group: "Empty calendar",
                 name: "CRLF endings and 75-octet folding survive") { expect in
            let ics = emptyCalendar
            expect.ok(ics.hasSuffix("END:VCALENDAR\r\n"))
            expect.notContains(ics.replacingOccurrences(of: "\r\n", with: ""), "\n")
            for line in lines(ics) {
                expect.ok(line.utf8.count <= 75, "line over 75 octets: \(line)")
            }
        },

        TestCase(group: "Empty calendar",
                 name: "an empty calendar is stable across regeneration") { expect in
            // The one thing that must not vary is the part a subscriber diffs.
            // DTSTAMP is absent here because there is no event to stamp, so two
            // runs at different times must produce identical bytes.
            let first = writer.makeCalendar(name: "39 G Street → Booking.com", entries: [],
                                            generatedAt: Date(timeIntervalSince1970: 1_000_000))
            let second = writer.makeCalendar(name: "39 G Street → Booking.com", entries: [],
                                             generatedAt: Date(timeIntervalSince1970: 2_000_000))
            expect.equal(first, second)
        },
    ] }
}
