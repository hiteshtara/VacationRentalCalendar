import Foundation
import VRCCore

/// Sample feeds.
///
/// The Airbnb and Vrbo samples are modelled on this owner's real exports, which
/// is why they look so bare: Airbnb sends `SUMMARY:Airbnb (Not available)` with
/// no DESCRIPTION at all, and Vrbo sends `SUMMARY:Blocked`. That emptiness is
/// the thing the app has to cope with, so the fixtures must not be richer than
/// reality or the tests would pass against a feed that does not exist.
public enum Fixtures {

    public static func calendar(_ productID: String, _ events: String) -> String {
        """
        BEGIN:VCALENDAR
        PRODID:\(productID)
        CALSCALE:GREGORIAN
        VERSION:2.0
        \(events)
        END:VCALENDAR
        """
    }

    // MARK: - Airbnb

    /// A genuine booking: Airbnb includes a reservation URL and guest contact.
    public static let airbnbConfirmedBooking = calendar(
        "-//Airbnb Inc//Hosting Calendar 1.0//EN",
        """
        BEGIN:VEVENT
        DTSTAMP:20261109T003143Z
        DTSTART;VALUE=DATE:20270310
        DTEND;VALUE=DATE:20270315
        SUMMARY:Reserved
        UID:abb-confirmed-0001@airbnb.com
        DESCRIPTION:Reservation URL: https://www.airbnb.com/hosting/reservations/details/HMABCD1234\\nPhone Number (Last 4 Digits): 8891
        END:VEVENT
        """
    )

    /// The dangerous one. Airbnb blocks dates after a host cancellation using
    /// exactly the same wording it uses for a block the host made by hand.
    /// Nothing in this event says "cancellation".
    public static let airbnbCancellationBlock = calendar(
        "-//Airbnb Inc//Hosting Calendar 1.0//EN",
        """
        BEGIN:VEVENT
        DTSTAMP:20261109T003143Z
        DTSTART;VALUE=DATE:20270417
        DTEND;VALUE=DATE:20270420
        SUMMARY:Airbnb (Not available)
        UID:abb-cancelblock-0002@airbnb.com
        END:VEVENT
        """
    )

    /// Four opaque blocks, copied in shape from the owner's live feed.
    public static let airbnbOpaqueBlocks = calendar(
        "-//Airbnb Inc//Hosting Calendar 1.0//EN",
        """
        BEGIN:VEVENT
        DTSTAMP:20261109T003143Z
        DTSTART;VALUE=DATE:20261107
        DTEND;VALUE=DATE:20261115
        SUMMARY:Airbnb (Not available)
        UID:abb-block-a@airbnb.com
        END:VEVENT
        BEGIN:VEVENT
        DTSTAMP:20261109T003143Z
        DTSTART;VALUE=DATE:20261217
        DTEND;VALUE=DATE:20261219
        SUMMARY:Airbnb (Not available)
        UID:abb-block-b@airbnb.com
        END:VEVENT
        BEGIN:VEVENT
        DTSTAMP:20261109T003143Z
        DTSTART;VALUE=DATE:20270501
        DTEND;VALUE=DATE:20271110
        SUMMARY:Airbnb (Not available)
        UID:abb-block-horizon@airbnb.com
        END:VEVENT
        """
    )

    // MARK: - Vrbo

    public static let vrboReservation = calendar(
        "-//HomeAway.com\\, Inc.//EN",
        """
        BEGIN:VEVENT
        UID:vrbo-res-0001
        DTSTAMP:20261102T225117Z
        DTSTART;VALUE=DATE:20270310
        DTEND;VALUE=DATE:20270314
        SUMMARY:Reserved - Dana P.
        END:VEVENT
        """
    )

    /// The owner's live Vrbo feed: three blocks, no reservations, nothing to
    /// classify by.
    public static let vrboBlocks = calendar(
        "-//HomeAway.com\\, Inc.//EN",
        """
        BEGIN:VEVENT
        UID:78d35b3e-5c68-443d-afa3-642519c52f7e
        DTSTAMP:20261102T225117Z
        DTSTART;VALUE=DATE:20261101
        DTEND;VALUE=DATE:20261130
        SUMMARY:Blocked
        END:VEVENT
        BEGIN:VEVENT
        UID:aca421c0-3daa-4f3c-a258-f63096b9295e
        DTSTAMP:20261102T225117Z
        DTSTART;VALUE=DATE:20261101
        DTEND;VALUE=DATE:20261102
        SUMMARY:Blocked
        END:VEVENT
        """
    )

    // MARK: - Booking.com

    public static let bookingReservation = calendar(
        "-//Booking.com//Calendar//EN",
        """
        BEGIN:VEVENT
        UID:bdc-res-0001@booking.com
        DTSTAMP:20261102T120000Z
        DTSTART;VALUE=DATE:20270601
        DTEND;VALUE=DATE:20270605
        SUMMARY:Reserved
        DESCRIPTION:Guest Name: R. Okafor\\nConfirmation Code: 4412887301
        END:VEVENT
        """
    )

    public static let bookingClosed = calendar(
        "-//Booking.com//Calendar//EN",
        """
        BEGIN:VEVENT
        UID:bdc-closed-0001@booking.com
        DTSTAMP:20261102T120000Z
        DTSTART;VALUE=DATE:20270701
        DTEND;VALUE=DATE:20270705
        SUMMARY:CLOSED - Not available
        END:VEVENT
        """
    )

    // MARK: - Awkward shapes

    public static let owner = calendar(
        "-//Test//EN",
        """
        BEGIN:VEVENT
        UID:owner-0001
        DTSTART;VALUE=DATE:20270801
        DTEND;VALUE=DATE:20270805
        SUMMARY:Owner stay - family visit
        END:VEVENT
        """
    )

    public static let maintenance = calendar(
        "-//Test//EN",
        """
        BEGIN:VEVENT
        UID:maint-0001
        DTSTART;VALUE=DATE:20270901
        DTEND;VALUE=DATE:20270903
        SUMMARY:Maintenance - bathroom repair
        END:VEVENT
        """
    )

    public static let cancelledEvent = calendar(
        "-//Test//EN",
        """
        BEGIN:VEVENT
        UID:gone-0001
        DTSTART;VALUE=DATE:20271001
        DTEND;VALUE=DATE:20271005
        SUMMARY:Reserved
        STATUS:CANCELLED
        END:VEVENT
        """
    )

    /// CRLF line endings, a folded DESCRIPTION, escaped text and a DURATION in
    /// place of DTEND — the awkward corners of RFC 5545 that real feeds use.
    public static let foldedAndEscaped =
        "BEGIN:VCALENDAR\r\n"
        + "PRODID:-//Test\\, Inc.//EN\r\n"
        + "VERSION:2.0\r\n"
        + "BEGIN:VEVENT\r\n"
        + "UID:folded-0001\r\n"
        + "DTSTART;VALUE=DATE:20271101\r\n"
        + "DURATION:P3D\r\n"
        + "SUMMARY:Reserved\r\n"
        + "DESCRIPTION:Reservation URL: https://www.airbnb.com/hosting/reser\r\n"
        + " vations/details/HMZZZ9999\\nPhone Number (Last 4 Digits): 2211\r\n"
        + "END:VEVENT\r\n"
        + "END:VCALENDAR\r\n"

    // MARK: - Builders

    /// A store with one property and one listing per platform, wired to stub
    /// feeds. Returns the store plus the listing ids by platform.
    public static func makeStore(
        feeds: [RentalPlatform: String],
        databasePath: String? = nil
    ) throws -> (store: RentalStore, listingIDs: [RentalPlatform: Int64], fetcher: StubFeedFetcher) {
        let database = try databasePath.map { try Database(path: $0) } ?? Database.inMemory()
        let store = try RentalStore(
            database: database, credentials: InMemoryFeedCredentialStore()
        )
        let property = try store.properties.insert(
            Property(name: "Test Property", address: "1 Test Way")
        )
        var ids: [RentalPlatform: Int64] = [:]
        var texts: [String: String] = [:]
        for (platform, body) in feeds {
            let url = "https://example.test/\(platform.rawValue).ics"
            let listing = try store.listings.insert(PlatformListing(
                propertyID: property.id!,
                platform: platform,
                label: "\(platform.displayName) — Test Property",
                icalURL: url,
                urlStorage: .database
            ))
            ids[platform] = listing.id
            texts[url] = body
        }
        return (store, ids, StubFeedFetcher(texts: texts))
    }

    public static func temporaryDatabasePath() -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vrc-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("test.sqlite").path
    }
}
