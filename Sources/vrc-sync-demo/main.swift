import Foundation
import VRCCore

// Synthetic end-to-end publisher for the staging demonstration.
//
// Everything here is invented: the property, the guests, the reservations and
// the tokens. It exists so the HTTP path can be exercised without reaching
// for a live calendar, a live token, or a platform anyone is subscribed to.

let arguments = Array(CommandLine.arguments.dropFirst())
func value(for flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}
guard let outDirectory = value(for: "--out") else {
    FileHandle.standardError.write(Data("usage: vrc-sync-demo --out <dir>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: outDirectory)
let propertyID: Int64 = 4242
let now = DayMath.day(2026, 11, 11)

func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

func synthetic(
    _ platform: RentalPlatform, _ kind: BlockKind,
    _ ci: Date, _ co: Date, summary: String, needsReview: Bool = false,
    approved: Bool = true
) -> ClassifiedEvent {
    let key = "demo-\(platform.rawValue)-\(Int(ci.timeIntervalSince1970))-\(kind.rawValue)"
    return ClassifiedEvent(
        event: CalendarEvent(
            listingID: 1, eventKey: key, uid: "src-\(key)@example.invalid",
            platform: platform, summary: summary, details: "",
            checkIn: ci, checkOut: co),
        classification: EventClassification(
            eventKey: key, kind: kind, confidence: needsReview ? .low : .high,
            source: needsReview ? .automatic : .manual,
            needsReview: needsReview, exportApproved: approved),
        listingLabel: platform.displayName,
        propertyID: propertyID, propertyName: "Staging Cottage")
}

/// A portfolio with one of everything that must and must not travel.
let events: [ClassifiedEvent] = [
    synthetic(.bookingCom, .confirmedReservation, day(2026, 12, 11), day(2026, 12, 21),
              summary: "Reserved - Dana Example - BK12345678"),
    synthetic(.airbnb, .cancellationBlock, day(2026, 12, 17), day(2026, 12, 19),
              summary: "Airbnb (Not available)"),
    synthetic(.vrbo, .ownerBlock, day(2026, 12, 23), day(2026, 12, 27), summary: "Family"),
    synthetic(.bookingCom, .unknownUnavailable, day(2027, 1, 5), day(2027, 1, 9),
              summary: "CLOSED - Not available", needsReview: true),
]

// --- verify mode ------------------------------------------------------------

if let fetched = value(for: "--verify") {
    let text = (try? String(contentsOfFile: fetched, encoding: .utf8)) ?? ""
    let parsed = (try? ICalParser.parse(text)) ?? ICalParseResult()
    let imported: [ClassifiedEvent] = parsed.events.compactMap { event in
        guard let start = event.dtStart?.date, let end = event.dtEnd?.date else { return nil }
        return ClassifiedEvent(
            event: CalendarEvent(
                listingID: 2, eventKey: "dest-\(event.uid)", uid: event.uid,
                platform: .airbnb, summary: event.summary, details: "",
                checkIn: start, checkOut: end),
            classification: EventClassification(
                eventKey: "dest-\(event.uid)", kind: .ownerBlock, confidence: .high,
                source: .automatic, needsReview: false),
            listingLabel: "Airbnb", propertyID: propertyID, propertyName: "Staging Cottage")
    }
    let reservation = events[0]
    let assessment = DeliveryAssessment.assess(
        item: reservation, destination: .airbnb, policy: .default,
        observedAtDestination: imported,
        publishedUID: DestinationFeedBuilder.publicationUID(
            sourceEventKey: reservation.event.eventKey, destination: .airbnb),
        destinationFeed: FeedFreshness(platform: .airbnb,
                                       lastSuccess: now.addingTimeInterval(-60),
                                       lastOutcome: .success),
        lastPublishFailed: false, now: now)

    var report = "parsed \(parsed.events.count) event(s)\n"
    report += "status \(assessment.status.rawValue)\n"
    report += "attribution \(assessment.attribution)\n"
    report += "datesCovered \(assessment.datesCovered)\n"
    if assessment.status == .protected { report += "VERIFY ok\n" }
    try? report.write(to: out.appendingPathComponent("verify.txt"),
                      atomically: true, encoding: .utf8)
    print(report.trimmingCharacters(in: .newlines))
    exit(assessment.status == .protected ? 0 : 1)
}

// --- simulated failure ------------------------------------------------------

if arguments.contains("--simulate-publish-failure") {
    // The publication errors before it writes anything. The point of the
    // check is that the previously served feed is untouched: a failure must
    // never be able to reopen nights that are already protected.
    print("publication attempt failed (simulated); nothing was written")
    exit(0)
}

// --- publish ----------------------------------------------------------------

var manifest: [String] = []
for destination in [RentalPlatform.airbnb, .vrbo] {
    let feed = DestinationFeedBuilder.build(
        propertyID: propertyID, propertyName: "Staging Cottage",
        events: events, destination: destination, policy: .default, now: now)

    let minted = FeedToken.mint(
        propertyID: propertyID, destination: destination, version: 1, now: now)

    let path = out.appendingPathComponent("\(destination.rawValue).ics")
    try? feed.ics.write(to: path, atomically: true, encoding: .utf8)

    manifest.append("\(destination.rawValue)\t\(minted.secret)\t\(minted.token.objectKey)")
    print("\(destination.displayName): \(feed.entries.count) entr(y/ies) "
        + "→ \(minted.token.objectKey)")
    for excluded in feed.excluded {
        print("   excluded \(excluded.sourceEventKey): \(excluded.reason)")
    }
}
try? manifest.joined(separator: "\n").appending("\n")
    .write(to: out.appendingPathComponent("manifest.txt"),
           atomically: true, encoding: .utf8)
print("manifest written")
