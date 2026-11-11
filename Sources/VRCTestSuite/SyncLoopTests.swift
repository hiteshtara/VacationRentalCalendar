import Foundation
import VRCCore

/// A block we published must not come back and go round again.
///
/// Not hypothetical: Booking.com's calendar is already connected directly to
/// Airbnb and Vrbo. So the same reservation can reach a platform twice — once
/// by that subscription, once by anything we publish — and a platform that
/// imports an external block generally re-exports it in its own calendar. On
/// the next import we would see a block on Airbnb that is really our own
/// Booking.com reservation wearing a different hat, and could send it onward
/// to Vrbo. Each lap makes the dates look more independently confirmed than
/// they are, and makes withdrawal unsafe: removing one copy while another
/// stands leaves dates looking protected when they are not.
public enum SyncLoopTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DayMath.day(y, m, d) }

    static func item(
        _ platform: RentalPlatform, uid: String, _ kind: BlockKind = .confirmedReservation
    ) -> ClassifiedEvent {
        let key = "loop-\(platform.rawValue)-\(uid)"
        return ClassifiedEvent(
            event: CalendarEvent(
                listingID: 1, eventKey: key, uid: uid, platform: platform,
                summary: "Reserved", details: "",
                checkIn: day(2026, 12, 11), checkOut: day(2026, 12, 21)),
            classification: EventClassification(
                eventKey: key, kind: kind, confidence: .high,
                source: .manual, needsReview: false, exportApproved: true),
            listingLabel: platform.displayName, propertyID: 1, propertyName: "39 G Street")
    }

    /// What the owner has actually configured today.
    static let liveConnections: Set<SyncLoopGuard.DirectConnection> = [
        .init(source: .bookingCom, destination: .airbnb),
        .init(source: .bookingCom, destination: .vrbo),
    ]

    public static var cases: [TestCase] { [

        TestCase(group: "Sync loops",
                 name: "our own publication is recognisable when it comes back") { expect in
            let ours = ICalWriter.outboundUID(sourceEventKey: "some-source-event")
            expect.ok(SyncLoopGuard.isOurPublication(uid: ours))
            expect.ok(!SyncLoopGuard.isOurPublication(uid: "1234@airbnb.com"))
            expect.ok(!SyncLoopGuard.isOurPublication(uid: "abc@booking.com"))
            expect.ok(!SyncLoopGuard.isOurPublication(uid: ""))
        },

        TestCase(group: "Sync loops",
                 name: "an echo of our own block is never republished") { expect in
            // Airbnb re-exported what we sent it. Sending that to Vrbo would
            // be the second lap.
            let echo = item(.airbnb, uid: ICalWriter.outboundUID(sourceEventKey: "bk-res-1"))
            expect.equal(
                SyncLoopGuard.verdict(for: echo, destination: .vrbo,
                                      directConnections: []),
                .skipOwnPublication(uid: echo.event.uid))
        },

        TestCase(group: "Sync loops",
                 name: "an echo is not independent evidence of anything") { expect in
            // It must not be classified as a reservation Airbnb told us about,
            // nor counted as corroboration that Airbnb is holding the dates.
            let echo = item(.airbnb, uid: ICalWriter.outboundUID(sourceEventKey: "bk-res-1"))
            expect.ok(!SyncLoopGuard.shouldClassifyAsIndependentObservation(echo))
            let genuine = item(.airbnb, uid: "real-airbnb-booking@airbnb.com")
            expect.ok(SyncLoopGuard.shouldClassifyAsIndependentObservation(genuine))
        },

        TestCase(group: "Sync loops",
                 name: "we do not duplicate what a direct connection already delivers") { expect in
            // Booking.com -> Airbnb is already connected. Publishing the same
            // reservation ourselves would leave two blocks on the same nights.
            let reservation = item(.bookingCom, uid: "bk-123@booking.com")
            expect.equal(
                SyncLoopGuard.verdict(for: reservation, destination: .airbnb,
                                      directConnections: liveConnections),
                .skipDirectConnection(.bookingCom))
            expect.equal(
                SyncLoopGuard.verdict(for: reservation, destination: .vrbo,
                                      directConnections: liveConnections),
                .skipDirectConnection(.bookingCom))
        },

        TestCase(group: "Sync loops",
                 name: "a platform with no direct connection is still published to") { expect in
            // Airbnb -> Vrbo is NOT connected, so that one is ours to carry.
            let airbnbReservation = item(.airbnb, uid: "ab-999@airbnb.com")
            expect.equal(
                SyncLoopGuard.verdict(for: airbnbReservation, destination: .vrbo,
                                      directConnections: liveConnections),
                .publish)
            expect.equal(
                SyncLoopGuard.verdict(for: airbnbReservation, destination: .bookingCom,
                                      directConnections: liveConnections),
                .publish)
        },

        TestCase(group: "Sync loops",
                 name: "nothing is ever sent back to its own source") { expect in
            let reservation = item(.vrbo, uid: "vr-1@vrbo.com")
            expect.equal(
                SyncLoopGuard.verdict(for: reservation, destination: .vrbo,
                                      directConnections: []),
                .skipSameSource)
        },

        TestCase(group: "Sync loops",
                 name: "the live configuration produces no duplicate Booking.com blocks") { expect in
            // The whole portfolio against what is actually connected today.
            let events = [
                item(.bookingCom, uid: "bk-dec@booking.com"),
                item(.airbnb, uid: "ab-jan@airbnb.com"),
                item(.vrbo, uid: "vr-feb@vrbo.com"),
                item(.airbnb, uid: ICalWriter.outboundUID(sourceEventKey: "bk-dec-echo")),
            ]
            for destination in [RentalPlatform.airbnb, .vrbo, .bookingCom] {
                let result = SyncLoopGuard.publishable(
                    events, to: destination, directConnections: liveConnections)
                for published in result.publish {
                    expect.ok(!SyncLoopGuard.isOurPublication(uid: published.event.uid),
                              "an echo was published to \(destination.displayName)")
                    expect.ok(published.event.platform != destination,
                              "sent back to its source")
                    expect.ok(!liveConnections.contains(
                        .init(source: published.event.platform, destination: destination)),
                        "duplicated a direct connection to \(destination.displayName)")
                }
            }
            // Airbnb already gets Booking.com directly, so only Vrbo's event
            // is ours to carry there.
            let toAirbnb = SyncLoopGuard.publishable(
                events, to: .airbnb, directConnections: liveConnections)
            expect.equal(toAirbnb.publish.count, 1)
            expect.equal(toAirbnb.publish.first?.event.platform, .vrbo)
        },

        TestCase(group: "Sync loops",
                 name: "removing a direct connection restores our publication") { expect in
            // If the owner disconnects Booking.com -> Airbnb, we take it over
            // rather than leaving the nights uncovered.
            let reservation = item(.bookingCom, uid: "bk-123@booking.com")
            expect.equal(
                SyncLoopGuard.verdict(for: reservation, destination: .airbnb,
                                      directConnections: []),
                .publish)
        },

        TestCase(group: "Sync loops",
                 name: "a skip is reported with its reason, never silent") { expect in
            let events = [
                item(.bookingCom, uid: "bk-dec@booking.com"),
                item(.airbnb, uid: ICalWriter.outboundUID(sourceEventKey: "echo")),
            ]
            let result = SyncLoopGuard.publishable(
                events, to: .airbnb, directConnections: liveConnections)
            expect.equal(result.publish.count, 0)
            expect.equal(result.skipped.count, 2)
            let verdicts = Set(result.skipped.map { "\($0.1)" })
            expect.equal(verdicts.count, 2, "two different reasons, both recorded")
        },
    ] }
}
