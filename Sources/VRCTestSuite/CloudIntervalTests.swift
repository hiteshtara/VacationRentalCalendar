import Foundation
import VRCCore

/// The service's interval payloads are parsed before being shown. A format the
/// parser does not recognise must not quietly render as an empty calendar.
public enum CloudIntervalTests {

    static func interval(_ from: String, _ to: String) -> CloudSyncClient.BlockingInterval {
        CloudSyncClient.BlockingInterval(
            property: "39 G Street", from: from, to: to,
            basis: "reservation", source: "direct")
    }

    public static var cases: [TestCase] { [

        TestCase(group: "Cloud intervals",
                 name: "both day formats the service emits are parsed") { expect in
            expect.ok(CloudInterval.day("2027-07-01") != nil, "hyphenated")
            expect.ok(CloudInterval.day("20270701") != nil, "compact")
            expect.equal(CloudInterval.day("2027-07-01"), CloudInterval.day("20270701"))
        },

        TestCase(group: "Cloud intervals",
                 name: "nights are counted check-out exclusive",
                 requirement: "Half-open [checkIn, checkOut)") { expect in
            expect.equal(CloudInterval.nights(interval("2027-07-01", "2027-07-08")), 7)
            expect.equal(CloudInterval.nights(interval("2027-09-01", "2027-09-02")), 1)
        },

        TestCase(group: "Cloud intervals",
                 name: "an unparseable range is shown verbatim, not as nothing") { expect in
            let described = CloudInterval.describe(interval("not-a-date", "also-not"))
            // Falling back to the raw text keeps a format change visible rather
            // than rendering a blank row that reads as "no blocks".
            expect.contains(described, "not-a-date")
            expect.equal(CloudInterval.nights(interval("not-a-date", "also-not")), 0)
        },

        TestCase(group: "Cloud intervals",
                 name: "a reversed range counts zero rather than negative") { expect in
            expect.equal(CloudInterval.nights(interval("2027-07-08", "2027-07-01")), 0)
        },
    ] }
}
