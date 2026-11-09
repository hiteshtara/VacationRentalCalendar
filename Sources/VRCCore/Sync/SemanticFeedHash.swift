import Foundation

/// Decides whether a re-fetched feed actually says anything new.
///
/// The scheduled importer runs every 15 minutes, but waking the cloud database
/// is the expensive part of a poll — Aurora Serverless v2 bills a five-minute
/// minimum pause delay, so a poll that touches the database costs roughly
/// 5.5 minutes of capacity whether or not anything changed. Polling cheaply
/// therefore means answering "is this different?" without a database at all.
///
/// The hash covers what we would act on and deliberately excludes what feeds
/// regenerate on every request. `DTSTAMP` is the important one: platforms stamp
/// it with the time the feed was generated, so a hash over raw bytes would
/// differ on every single poll and change detection would never fire.
///
/// Included, because a change in any of these changes what we would publish:
///   UID, RECURRENCE-ID   — event identity
///   DTSTART, DTEND       — the nights, resolved through DURATION
///   SUMMARY              — carries the platform's own wording, which drives
///                          classification ("Reserved", "Blocked", "Not available")
///   DESCRIPTION, LOCATION — further classification signal
///   STATUS               — CONFIRMED / TENTATIVE / CANCELLED
///
/// Excluded, because they move without meaning anything:
///   DTSTAMP, LAST-MODIFIED, CREATED, SEQUENCE, PRODID, property order,
///   event order, line folding, and surrounding whitespace.
///
/// `SEQUENCE` is excluded on purpose. It is meant to be a revision counter, but
/// a bump with identical dates, summary and status is not a change we would act
/// on, and some producers increment it on regeneration.
public enum SemanticFeedHash {

    /// One event reduced to the fields we would act on.
    public struct NormalizedEvent: Hashable, Sendable, Comparable {
        public var uid: String
        public var recurrenceID: String
        public var start: String
        public var end: String
        public var summary: String
        public var detail: String
        public var status: String

        public static func < (a: NormalizedEvent, b: NormalizedEvent) -> Bool {
            a.canonicalLine < b.canonicalLine
        }

        /// Field-separated so two different field splits cannot collide — a
        /// summary containing the separator is impossible, because the
        /// separator is a control character stripped during normalisation.
        public var canonicalLine: String {
            [uid, recurrenceID, start, end, summary, detail, status]
                .joined(separator: "\u{1F}")
        }
    }

    /// Fields excluded from the hash, named so a test can assert the list and
    /// so the reason survives in one place rather than in a comment.
    public static let excludedProperties = [
        "DTSTAMP", "LAST-MODIFIED", "CREATED", "SEQUENCE", "PRODID", "CALSCALE", "METHOD",
    ]

    public static func normalize(_ events: [ICalEvent]) -> [NormalizedEvent] {
        events.map(normalize(event:)).sorted()
    }

    public static func normalize(event: ICalEvent) -> NormalizedEvent {
        NormalizedEvent(
            uid: collapse(event.uid),
            recurrenceID: collapse(event.recurrenceID ?? ""),
            start: stamp(event.dtStart),
            end: stamp(resolvedEnd(of: event)),
            summary: collapse(event.summary),
            detail: collapse(event.description + " " + event.location),
            status: collapse(event.status ?? "").uppercased()
        )
    }

    /// The exact bytes that get hashed. Exposed so a failing comparison can be
    /// explained field by field without re-deriving anything.
    public static func canonicalText(_ events: [ICalEvent]) -> String {
        normalize(events).map(\.canonicalLine).joined(separator: "\u{1E}")
    }

    public static func hash(_ events: [ICalEvent]) -> String {
        EventKey.sha256(canonicalText(events))
    }

    /// Which normalised field names differ between two feeds, for events present
    /// in both. Returns field *names* only — never values — so a caller can log
    /// the result without disclosing reservation or guest detail.
    public static func changedFieldNames(
        from before: [ICalEvent], to after: [ICalEvent]
    ) -> [String] {
        let a = Dictionary(
            normalize(before).map { ($0.uid + "\u{1F}" + $0.recurrenceID, $0) },
            uniquingKeysWith: { first, _ in first })
        let b = Dictionary(
            normalize(after).map { ($0.uid + "\u{1F}" + $0.recurrenceID, $0) },
            uniquingKeysWith: { first, _ in first })

        var names = Set<String>()
        for (key, before) in a {
            guard let after = b[key] else { continue }
            if before.start != after.start { names.insert("DTSTART") }
            if before.end != after.end { names.insert("DTEND") }
            if before.summary != after.summary { names.insert("SUMMARY") }
            if before.detail != after.detail { names.insert("DESCRIPTION/LOCATION") }
            if before.status != after.status { names.insert("STATUS") }
        }
        if Set(a.keys) != Set(b.keys) { names.insert("UID set") }
        return names.sorted()
    }

    // MARK: - Normalisation details

    /// DTEND wins; otherwise DTSTART + DURATION, which is how some producers
    /// express a stay. An event with neither normalises to an empty end rather
    /// than to a guessed one — the parser already reports that case.
    private static func resolvedEnd(of event: ICalEvent) -> ICalDateValue? {
        if let explicit = event.dtEnd { return explicit }
        guard let start = event.dtStart, let duration = event.duration else { return nil }
        return ICalDateValue(
            date: start.date.addingTimeInterval(duration), isDateOnly: start.isDateOnly)
    }

    /// A date-only value is stamped as a calendar day, so a producer switching
    /// between `20261210` and `20261210T000000Z` is not read as a change. A
    /// timed value is stamped to the second in UTC.
    private static func stamp(_ value: ICalDateValue?) -> String {
        guard let value else { return "" }
        if value.isDateOnly { return "D:" + DayMath.icalDateString(value.date) }
        return "T:" + String(Int(value.date.timeIntervalSince1970.rounded()))
    }

    /// Trims, collapses runs of whitespace, and strips control characters —
    /// including the separators used to build the canonical line, so no field
    /// value can forge a field boundary.
    private static func collapse(_ text: String) -> String {
        let cleaned = String(text.unicodeScalars.map { scalar -> Character in
            if scalar.properties.generalCategory == .control { return " " }
            return Character(scalar)
        })
        return cleaned.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
