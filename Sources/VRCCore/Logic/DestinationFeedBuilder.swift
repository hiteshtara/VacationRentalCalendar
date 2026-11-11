import Foundation

/// One filtered calendar per destination.
///
/// Joins the two halves that existed separately: `OutboundPolicy` decides
/// whether a classification may protect a given platform, and `ExportPolicy`
/// decides whether an individual event may ever leave at all. Both must say
/// yes. They are kept separate because they answer different questions —
/// policy is a setting the owner controls, the allow-list is not.
///
/// What leaves is deliberately thin: dates, a stable UID, and the word
/// "Reserved" or "Not available". No guest name, no reservation number, no
/// platform-identifying detail. A destination calendar is a public artefact
/// the moment a platform subscribes to it.
public enum DestinationFeedBuilder {

    public struct Entry: Sendable, Equatable {
        public let sourceEventKey: String
        public let sourcePlatform: RentalPlatform
        /// Stable across rebuilds, restarts and republications.
        public let uid: String
        public let checkIn: Date
        public let checkOut: Date
        public let kind: BlockKind
        /// Checkout exclusive.
        public var nights: [Date] {
            CalendarVisibility.occupiedNights(
                of: CalendarEvent(
                    listingID: 0, eventKey: sourceEventKey, uid: uid,
                    platform: sourcePlatform, summary: "", details: "",
                    checkIn: checkIn, checkOut: checkOut))
        }
    }

    public struct Feed: Sendable, Equatable {
        public let propertyID: Int64
        public let propertyName: String
        public let destination: RentalPlatform
        public let entries: [Entry]
        public let ics: String
        /// Everything considered but not sent, with the reason — so a person
        /// can see why a night they expected to be protected is not.
        public let excluded: [(sourceEventKey: String, reason: String)]

        public static func == (lhs: Feed, rhs: Feed) -> Bool {
            lhs.propertyID == rhs.propertyID && lhs.destination == rhs.destination
                && lhs.entries == rhs.entries && lhs.ics == rhs.ics
        }
    }

    /// The UID this source event will carry in a destination feed.
    ///
    /// Delegates to `ICalWriter.outboundUID` rather than deriving its own: the
    /// attribution check has to recognise exactly what the writer emitted, and
    /// two derivations that must agree would eventually not.
    public static func publicationUID(
        sourceEventKey: String, destination: RentalPlatform
    ) -> String {
        ICalWriter.outboundUID(sourceEventKey: sourceEventKey)
    }

    public static func build(
        propertyID: Int64,
        propertyName: String,
        events: [ClassifiedEvent],
        destination: RentalPlatform,
        policy: OutboundPolicy,
        exportPolicy: ExportPolicy = ExportPolicy(),
        writer: ICalWriter = ICalWriter(),
        now: Date = Date()
    ) -> Feed {
        var entries: [Entry] = []
        var excluded: [(sourceEventKey: String, reason: String)] = []

        for item in events where item.propertyID == propertyID {
            // Both gates. The allow-list is not a setting; the policy is.
            let outbound = policy.decision(item, to: destination)
            guard outbound == .propagate else {
                if case .blocked(let reason) = outbound {
                    excluded.append((item.event.eventKey, reason.rawValue))
                }
                continue
            }
            let export = exportPolicy.decide(
                event: item.event, classification: item.classification,
                destination: destination)
            guard export.isIncluded else {
                excluded.append((item.event.eventKey, export.reason))
                continue
            }
            entries.append(Entry(
                sourceEventKey: item.event.eventKey,
                sourcePlatform: item.event.platform,
                uid: publicationUID(
                    sourceEventKey: item.event.eventKey, destination: destination),
                checkIn: item.event.checkIn,
                checkOut: item.event.checkOut,
                kind: item.classification.kind))
        }
        entries.sort { $0.checkIn < $1.checkIn }

        let ics = writer.makeCalendar(
            name: "\(propertyName) → \(destination.displayName)",
            entries: entries.map { entry in
                ICalWriter.ExportEntry(
                    sourceEventKey: entry.sourceEventKey,
                    checkIn: entry.checkIn,
                    checkOut: entry.checkOut,
                    // Thin on purpose: no guest name, no reservation number,
                    // no hint of which platform it came from.
                    summary: entry.kind == .confirmedReservation
                        ? "Reserved" : "Not available")
            },
            generatedAt: now)

        return Feed(propertyID: propertyID, propertyName: propertyName,
                    destination: destination, entries: entries, ics: ics,
                    excluded: excluded)
    }

    /// One feed per destination, source platform excluded automatically.
    public static func buildAll(
        propertyID: Int64, propertyName: String, events: [ClassifiedEvent],
        policy: OutboundPolicy, now: Date = Date()
    ) -> [Feed] {
        [RentalPlatform.airbnb, .vrbo, .bookingCom].map {
            build(propertyID: propertyID, propertyName: propertyName,
                  events: events, destination: $0, policy: policy, now: now)
        }
    }
}
