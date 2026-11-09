import Foundation
import VRCCore

// Cross-platform parity harness.
//
// Compiles and runs on both macOS and Linux and emits a byte-identical report
// if, and only if, the business rules agree. Everything is pinned: fixed dates,
// fixed UIDs, a fixed generation timestamp, and sorted output. There is no
// `Date()` anywhere, no dictionary iteration, no locale-dependent formatting,
// and no UUID.
//
// The point is not that both platforms pass their tests. It is that the same
// inputs produce the same classifications, the same availability outcomes, the
// same conflict categories and the same filtered iCal bytes.
//
//   swift run vrc-parity            prints the report
//   swift run vrc-parity --digest   prints only the SHA-256 of the report

let wantDigestOnly = CommandLine.arguments.contains("--digest")
let fixedNow = Date(timeIntervalSince1970: 1_764_000_000) // 2025-11-24T15:20:00Z
var out = ""
func emit(_ line: String = "") { out += line + "\n" }

func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

// ---------------------------------------------------------------- 1. parsing

// Deliberately awkward input: CRLF and bare LF mixed, a folded line, a
// VALUE=DATE and a UTC timestamp, DURATION instead of DTEND, and an unknown
// property. Every one of these has a platform-specific failure mode.
let feedText = [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Parity//EN", "CALSCALE:GREGORIAN",
    "BEGIN:VEVENT", "DTSTAMP:20261109T120000Z", "UID:p-reserved@airbnb",
    "DTSTART;VALUE=DATE:20270301", "DTEND;VALUE=DATE:20270305",
    "SUMMARY:Reserved - Dana Pemberton",
    "DESCRIPTION:Phone Number (Last 4 Digits): 8891", "STATUS:CONFIRMED",
    "END:VEVENT",
    "BEGIN:VEVENT", "DTSTAMP:20261109T120000Z", "UID:p-cancelled@airbnb",
    "DTSTART;VALUE=DATE:20270310", "DTEND;VALUE=DATE:20270312",
    "SUMMARY:Airbnb (Not available)",
    "DESCRIPTION:This block was created because of a cancell", " ation penalty",
    "END:VEVENT",
    "BEGIN:VEVENT", "DTSTAMP:20261109T120000Z", "UID:p-duration@vrbo",
    "DTSTART:20270401T000000Z", "DURATION:P3D", "SUMMARY:Blocked",
    "X-UNKNOWN-PROPERTY:ignored", "END:VEVENT",
    "BEGIN:VEVENT", "DTSTAMP:20261109T120000Z", "UID:p-opaque@vrbo",
    "DTSTART;VALUE=DATE:20270501", "DTEND;VALUE=DATE:20270601", "SUMMARY:Not available",
    "END:VEVENT",
    "END:VCALENDAR",
].joined(separator: "\r\n") + "\n"

emit("=== 1. iCal parsing ===")
let parsed = try ICalParser.parse(feedText)
emit("productID: \(parsed.productID)")
emit("events: \(parsed.events.count)")
emit("warnings: \(parsed.warnings.count)")
for event in parsed.events.sorted(by: { $0.uid < $1.uid }) {
    let start = event.dtStart.map { DayMath.icalDateString($0.date) } ?? "-"
    let end = event.dtEnd.map { DayMath.icalDateString($0.date) } ?? "-"
    let duration = event.duration.map { String(Int($0)) } ?? "-"
    emit("  \(event.uid) start=\(start) end=\(end) dur=\(duration) "
        + "dateOnly=\(event.dtStart?.isDateOnly.description ?? "-") "
        + "status=\(event.status ?? "-") summary=\"\(event.summary)\" "
        + "lines=\(event.allLines.count)")
}

// --------------------------------------------------------- 2. classification

emit()
emit("=== 2. classification ===")
let classifier = BlockClassifier()
struct Row { let uid: String; let line: String }
var rows: [Row] = []
for event in parsed.events {
    let platform: RentalPlatform = event.uid.hasSuffix("@airbnb") ? .airbnb : .vrbo
    let nights: Int = {
        guard let s = event.dtStart?.date else { return 1 }
        if let e = event.dtEnd?.date { return max(1, DayMath.daysBetween(s, e)) }
        if let d = event.duration { return max(1, Int(d / 86_400)) }
        return 1
    }()
    let proposal = classifier.classify(event: event, platform: platform, nights: nights)
    rows.append(Row(uid: event.uid, line:
        "  \(event.uid) platform=\(platform.rawValue) nights=\(nights) "
        + "kind=\(proposal.kind.rawValue) needsReview=\(proposal.needsReview) "
        + "genuine=\(proposal.kind.describesGenuineUnavailability)"))
}
for row in rows.sorted(by: { $0.uid < $1.uid }) { emit(row.line) }

emit()
emit("  every BlockKind, and whether it may ever be exported:")
for kind in BlockKind.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
    emit("    \(kind.rawValue) genuine=\(kind.describesGenuineUnavailability)")
}

// --------------------------------------------------- 3. availability decisions

emit()
emit("=== 3. availability decisions ===")
let store = try RentalStore.makeInMemory()
let property = try store.properties.insert(Property(name: "39 G Street"))
let propertyID = property.id!
for platform in [RentalPlatform.airbnb, .vrbo, .bookingCom] {
    _ = try store.listings.insert(PlatformListing(
        propertyID: propertyID, platform: platform, label: platform.displayName,
        icalURL: "https://example.test/\(platform.rawValue).ics",
        urlStorage: .database, connectionState: .connected))
}
// The two real December decisions, including the deliberate Dec 17-18 gap.
let ranges = [((2026, 12, 10), (2026, 12, 17)), ((2026, 12, 19), (2026, 12, 20))]
var decisions: [AvailabilityDecision] = []
for (index, range) in ranges.enumerated() {
    let decision = try store.availability.insert(AvailabilityDecision(
        propertyID: propertyID, destination: .vrbo, action: .block,
        startDay: day(range.0.0, range.0.1, range.0.2),
        endDay: day(range.1.0, range.1.1, range.1.2),
        status: .approved, publicationUID: "vrc-parity-\(index)",
        approvedAt: fixedNow))
    decisions.append(decision)
}
for decision in decisions.sorted(by: { $0.publicationUID < $1.publicationUID }) {
    emit("  \(decision.publicationUID) \(decision.destination.rawValue) "
        + "\(decision.action.rawValue) \(decision.status.rawValue) "
        + "\(DayMath.icalDateString(decision.startDay))→"
        + "\(DayMath.icalDateString(decision.endDay)) nights=\(decision.nights)")
}
let protectedNights = [day(2026, 12, 17), day(2026, 12, 18)]
for night in protectedNights {
    let covered = decisions.contains { night >= $0.startDay && night < $0.endDay }
    emit("  protected \(DayMath.icalDateString(night)) covered=\(covered)")
}

// ------------------------------------------------------- 4. conflict outcomes

emit()
emit("=== 4. conflict outcomes ===")
func classified(
    _ key: String, _ platform: RentalPlatform, _ kind: BlockKind,
    _ from: (Int, Int, Int), _ to: (Int, Int, Int), verifiedSummary: Bool = true
) -> ClassifiedEvent {
    ClassifiedEvent(
        event: CalendarEvent(
            listingID: 1, eventKey: key, uid: key, platform: platform,
            summary: verifiedSummary && kind == .confirmedReservation
                ? "Reserved - Dana Pemberton" : "Blocked",
            details: verifiedSummary && kind == .confirmedReservation
                ? "Phone Number (Last 4 Digits): 8891" : "",
            checkIn: day(from.0, from.1, from.2), checkOut: day(to.0, to.1, to.2)),
        classification: EventClassification(
            eventKey: key, kind: kind, confidence: .high, source: .manual,
            needsReview: false, exportApproved: kind != .confirmedReservation),
        listingLabel: platform.displayName, propertyID: 1, propertyName: "39 G Street")
}

let conflictInputs = [
    classified("c-abnb-res", .airbnb, .confirmedReservation, (2027, 7, 1), (2027, 7, 5)),
    classified("c-vrbo-res", .vrbo, .confirmedReservation, (2027, 7, 3), (2027, 7, 8)),
    classified("c-abnb-owner", .airbnb, .ownerBlock, (2027, 8, 1), (2027, 8, 4)),
    classified("c-vrbo-owner", .vrbo, .ownerBlock, (2027, 8, 2), (2027, 8, 6)),
    classified("c-abnb-cancel", .airbnb, .cancellationBlock, (2027, 9, 1), (2027, 9, 3)),
    // Adjacency: checkout on the 5th, arrival on the 5th. Must NOT be a conflict.
    classified("c-abnb-turn", .airbnb, .confirmedReservation, (2027, 10, 1), (2027, 10, 5)),
    classified("c-vrbo-turn", .vrbo, .confirmedReservation, (2027, 10, 5), (2027, 10, 9)),
]
let findings = ConflictAnalyzer().analyse(events: conflictInputs, now: fixedNow)
emit("findings: \(findings.count)")
var findingLines: [String] = []
for finding in findings {
    let platforms = [finding.sideA.platform.rawValue, finding.sideB.platform.rawValue]
        .sorted().joined(separator: "+")
    findingLines.append(
        "  \(finding.category.rawValue) "
        + "\(DayMath.icalDateString(finding.overlapStart))→"
        + "\(DayMath.icalDateString(finding.overlapEnd)) "
        + "platforms=\(platforms) "
        + "verifA=\(finding.verificationA?.rawValue ?? "-") "
        + "verifB=\(finding.verificationB?.rawValue ?? "-")")
}
for line in findingLines.sorted() { emit(line) }

// --------------------------------------------------- 5. filtered iCal output

emit()
emit("=== 5. filtered iCal output ===")
let exportInputs = [
    classified("x-abnb-res", .airbnb, .confirmedReservation, (2027, 3, 1), (2027, 3, 5)),
    classified("x-abnb-cancel", .airbnb, .cancellationBlock, (2027, 3, 10), (2027, 3, 12)),
    classified("x-abnb-window", .airbnb, .platformRestriction, (2027, 3, 20), (2027, 3, 25)),
    classified("x-abnb-unknown", .airbnb, .unknownUnavailable, (2027, 4, 1), (2027, 4, 3)),
    classified("x-abnb-owner", .airbnb, .ownerBlock, (2027, 4, 10), (2027, 4, 14)),
]
for scope in [FeedPublicationScope.approvedManualBlocksOnly,
              .reservationsAndApprovedBlocks] {
    let feed = CalendarFeedGenerator().generate(
        destination: .vrbo, propertyID: propertyID, propertyName: "39 G Street",
        sourceEvents: exportInputs, decisions: decisions,
        scope: scope, revision: 7, now: fixedNow)
    emit("scope=\(scope.rawValue) included=\(feed.included.count) "
        + "excluded=\(feed.excluded.count) nights=\(feed.includedNights)")
    for entry in feed.entries.sorted(by: { $0.uid < $1.uid }) {
        emit("  \(entry.included ? "IN " : "OUT") \(entry.uid) "
            + "\(DayMath.icalDateString(entry.startDay))→"
            + "\(DayMath.icalDateString(entry.endDay)) "
            + "nights=\(entry.nights) reason=\(entry.reason)")
    }
    let rendered = CalendarFeedGenerator().makeICS(feed)
    emit("  rendered bytes: \(rendered.utf8.count)")
    emit("  rendered sha256: \(EventKey.sha256(rendered))")
    for line in rendered.replacingOccurrences(of: "\r\n", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: true) {
        emit("  | \(line)")
    }
}

// --------------------------------------------------------------- 6. digest

let digest = EventKey.sha256(out)
if wantDigestOnly {
    print(digest)
} else {
    print(out, terminator: "")
    print("=== parity digest ===")
    print(digest)
}
