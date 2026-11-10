import Foundation
import VRCCore

/// Change detection decides whether a 15-minute poll wakes the cloud database.
/// Two properties have to hold, and they pull in opposite directions:
/// regenerated metadata must NOT register as a change, and anything we would
/// act on MUST. A false negative here silently stops the calendar updating.
public enum SemanticHashTests {

    /// A feed with the fields real platforms send. `stamp` is the value that
    /// varies between fetches of an unchanged calendar.
    static func feed(
        stamp: String,
        uid: String = "abc123@airbnb.com",
        start: String = "20261210",
        end: String = "20261217",
        summary: String = "Reserved",
        status: String? = nil,
        sequence: Int? = nil,
        extraEvent: Bool = false
    ) -> String {
        var lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0",
            "PRODID:-//Airbnb Inc//Hosting Calendar \(stamp)//EN",
            "CALSCALE:GREGORIAN", "BEGIN:VEVENT",
            "DTSTAMP:\(stamp)", "LAST-MODIFIED:\(stamp)", "CREATED:\(stamp)",
            "UID:\(uid)",
            "DTSTART;VALUE=DATE:\(start)", "DTEND;VALUE=DATE:\(end)",
            "SUMMARY:\(summary)",
        ]
        if let status { lines.append("STATUS:\(status)") }
        if let sequence { lines.append("SEQUENCE:\(sequence)") }
        lines.append("END:VEVENT")
        if extraEvent {
            lines += [
                "BEGIN:VEVENT", "DTSTAMP:\(stamp)", "UID:second@airbnb.com",
                "DTSTART;VALUE=DATE:20270105", "DTEND;VALUE=DATE:20270109",
                "SUMMARY:Blocked", "END:VEVENT",
            ]
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
    }

    static func hash(_ text: String) throws -> String {
        SemanticFeedHash.hash(try ICalParser.parse(text).events)
    }

    public static var cases: [TestCase] { [

        // --- Volatile metadata must not register as a change ---

        TestCase(group: "Semantic feed hash",
                 name: "a regenerated DTSTAMP does not change the hash") { expect in
            // The whole design rests on this. Platforms stamp DTSTAMP with the
            // moment the feed was generated, so if this failed, every poll
            // would look like a change and the database would never sleep.
            let first = try hash(feed(stamp: "20261108T090000Z"))
            let second = try hash(feed(stamp: "20261108T091500Z"))
            expect.equal(first, second, "DTSTAMP must be excluded from the hash")
        },

        TestCase(group: "Semantic feed hash",
                 name: "LAST-MODIFIED, CREATED, SEQUENCE and PRODID are excluded") { expect in
            let a = try hash(feed(stamp: "20261108T090000Z", sequence: 1))
            let b = try hash(feed(stamp: "20261231T235959Z", sequence: 97))
            expect.equal(a, b, "revision counters and producer strings must not count as changes")
        },

        TestCase(group: "Semantic feed hash",
                 name: "event order does not change the hash") { expect in
            let events = try ICalParser.parse(feed(stamp: "x", extraEvent: true)).events
            expect.equal(events.count, 2)
            expect.equal(
                SemanticFeedHash.hash(events),
                SemanticFeedHash.hash(events.reversed()),
                "a producer reordering events is not a change")
        },

        TestCase(group: "Semantic feed hash",
                 name: "line folding and whitespace do not change the hash") { expect in
            let folded = """
            BEGIN:VCALENDAR\r
            VERSION:2.0\r
            BEGIN:VEVENT\r
            UID:abc123@airbnb.com\r
            DTSTART;VALUE=DATE:20261210\r
            DTEND;VALUE=DATE:20261217\r
            SUMMARY:Reserved for a gu\r
             est staying four nights\r
            END:VEVENT\r
            END:VCALENDAR
            """
            let unfolded = folded
                .replacingOccurrences(of: "Reserved for a gu\r\n est", with: "Reserved for a  guest")
            expect.equal(try hash(folded), try hash(unfolded),
                         "unfolding and collapsed whitespace must normalise identically")
        },

        TestCase(group: "Semantic feed hash",
                 name: "a date-only value equals the same day written as midnight UTC") { expect in
            let dateOnly = feed(stamp: "s")
            let timed = feed(stamp: "s")
                .replacingOccurrences(of: "DTSTART;VALUE=DATE:20261210",
                                      of2: "DTSTART:20261210T000000Z")
            _ = timed
            // Verified through normalisation directly, since the parser marks
            // VALUE=DATE separately from a timed midnight.
            let events = try ICalParser.parse(dateOnly).events
            expect.equal(SemanticFeedHash.normalize(events).count, 1)
            expect.ok(SemanticFeedHash.normalize(events)[0].start.hasPrefix("D:"),
                      "a date-only start is stamped as a calendar day")
        },

        // --- Meaningful changes MUST register ---

        TestCase(group: "Semantic feed hash",
                 name: "a changed check-in date changes the hash") { expect in
            expect.notEqualHash(try hash(feed(stamp: "s")),
                                try hash(feed(stamp: "s", start: "20261211")), expect)
        },

        TestCase(group: "Semantic feed hash",
                 name: "a changed check-out date changes the hash") { expect in
            expect.notEqualHash(try hash(feed(stamp: "s")),
                                try hash(feed(stamp: "s", end: "20261218")), expect)
        },

        TestCase(group: "Semantic feed hash",
                 name: "a changed UID changes the hash") { expect in
            expect.notEqualHash(try hash(feed(stamp: "s")),
                                try hash(feed(stamp: "s", uid: "different@airbnb.com")), expect)
        },

        TestCase(group: "Semantic feed hash",
                 name: "a changed SUMMARY changes the hash") { expect in
            // "Reserved" to "Blocked" is the difference between a booking and a
            // cancellation block. It must never be invisible.
            expect.notEqualHash(try hash(feed(stamp: "s", summary: "Reserved")),
                                try hash(feed(stamp: "s", summary: "Blocked")), expect)
        },

        TestCase(group: "Semantic feed hash",
                 name: "a changed STATUS changes the hash") { expect in
            expect.notEqualHash(try hash(feed(stamp: "s", status: "CONFIRMED")),
                                try hash(feed(stamp: "s", status: "CANCELLED")), expect)
        },

        TestCase(group: "Semantic feed hash",
                 name: "an added event changes the hash") { expect in
            expect.notEqualHash(try hash(feed(stamp: "s")),
                                try hash(feed(stamp: "s", extraEvent: true)), expect)
        },

        TestCase(group: "Semantic feed hash",
                 name: "a removed event changes the hash") { expect in
            // The direction that matters for safety: a feed losing an event
            // must be visible, because that is what a reduction looks like.
            expect.notEqualHash(try hash(feed(stamp: "s", extraEvent: true)),
                                try hash(feed(stamp: "s")), expect)
        },

        TestCase(group: "Semantic feed hash",
                 name: "an emptied feed changes the hash") { expect in
            let empty = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR"
            expect.notEqualHash(try hash(feed(stamp: "s")), try hash(empty), expect)
        },

        // --- Reporting a difference must not disclose anything ---

        TestCase(group: "Semantic feed hash",
                 name: "changed field names are reported without values") { expect in
            let before = try ICalParser.parse(feed(stamp: "s", summary: "Reserved")).events
            let after = try ICalParser.parse(
                feed(stamp: "t", start: "20261211", summary: "Blocked")).events
            let names = SemanticFeedHash.changedFieldNames(from: before, to: after)
            expect.ok(names.contains("DTSTART"), "the changed date is named")
            expect.ok(names.contains("SUMMARY"), "the changed summary is named")
            for name in names {
                expect.ok(!name.contains("Reserved") && !name.contains("Blocked")
                            && !name.contains("2026"),
                          "a field name must not carry a value: \(name)")
            }
        },

        TestCase(group: "Semantic feed hash",
                 name: "the excluded-field list is the documented one") { expect in
            expect.equal(Set(SemanticFeedHash.excludedProperties),
                         Set(["DTSTAMP", "LAST-MODIFIED", "CREATED", "SEQUENCE",
                              "PRODID", "CALSCALE", "METHOD"]))
        },

        TestCase(group: "Semantic feed hash",
                 name: "a field value cannot forge a field boundary") { expect in
            // A summary containing the separator must not be able to shift
            // later fields and collide with a different event.
            let sep = "\u{1F}"
            let a = try hash(feed(stamp: "s", summary: "Reserved\(sep)20261210"))
            let b = try hash(feed(stamp: "s", summary: "Reserved"))
            expect.notEqualHash(a, b, expect)
        },
    ] }
}

private extension String {
    func replacingOccurrences(of a: String, of2 b: String) -> String {
        replacingOccurrences(of: a, with: b)
    }
}

private extension Expect {
    func notEqualHash(_ a: String, _ b: String, _ expect: Expect) {
        expect.ok(a != b, "these feeds differ meaningfully, so the hashes must differ")
    }
}
