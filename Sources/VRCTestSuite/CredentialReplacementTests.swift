import Foundation
import VRCCore

/// Entering a new URL must give a dead connection another chance.
///
/// `FeedConnectionState.shouldAttemptImport` is false for `revoked`, and that
/// is correct: a token the platform has rejected will be rejected again, and
/// retrying it forever fills the history with failures that make a settled
/// fact look like a flaky network.
///
/// But the latch has to be released by the one event that genuinely changes
/// the answer — the owner supplying a **new** URL. It was not. The reset in
/// `ListingRepository.update` fired only for `credentialUnreadable`, so a
/// revoked listing stayed revoked no matter how many times the URL was
/// replaced, and no HTTP request was ever attempted again.
///
/// That is exactly what happened to Booking.com on 2026-11-10: the Keychain
/// item was updated with a freshly issued export URL, the app reported
/// "disconnected by the platform" one second later, and `sync_runs` recorded
/// no HTTP status at all — because nothing was ever sent. The app's own
/// message said "It will not be retried until you supply a new one", and the
/// owner had supplied a new one.
public enum CredentialReplacementTests {

    static func listing(
        _ store: RentalStore, _ state: FeedConnectionState, url: String
    ) throws -> PlatformListing {
        let property = try store.properties.insert(Property(name: "Southie Beach House"))
        let inserted = try store.listings.insert(PlatformListing(
            propertyID: property.id!, platform: .bookingCom,
            label: "Booking.com — Southie Beach House (17482435)",
            icalURL: url, urlStorage: .database))
        // `insert` does not persist connection_state — it is only ever moved
        // through setConnectionState, so that every change leaves an audit row.
        // Setting it here rather than on the struct is what makes the fixture
        // real: passing it to the initialiser silently did nothing, and the
        // first version of these tests passed against a listing that was never
        // actually revoked.
        try store.listings.setConnectionState(
            listingID: inserted.id!, to: state, actor: "test")
        return try store.listings.find(id: inserted.id!)!
    }

    /// Replaces the URL the way the Settings panel does.
    static func replaceURL(
        _ store: RentalStore, _ listing: PlatformListing, with url: String
    ) throws -> PlatformListing {
        var changed = listing
        changed.icalURL = url
        try store.listings.update(changed)
        return try store.listings.find(id: listing.id!)!
    }

    public static var cases: [TestCase] { [

        TestCase(group: "Credential replacement",
                 name: "a new URL clears a revoked connection so it is tried again") { expect in
            // The bug. Booking.com revokes the token when the connection it
            // belonged to is deleted; the owner makes a new connection and
            // pastes the new URL. That is a different credential, and the
            // platform's old answer no longer applies to it.
            let store = try RentalStore.makeInMemory()
            let dead = try listing(store, .revoked, url: "https://ical.booking.com/v1/export?t=old")
            expect.ok(!dead.connectionState.shouldAttemptImport, "precondition: not retried")

            let after = try replaceURL(store, dead, with: "https://ical.booking.com/v1/export?t=new")

            expect.equal(after.connectionState, .unknown,
                         "a new URL supersedes the platform's answer about the old one")
            expect.ok(after.connectionState.shouldAttemptImport,
                      "and the next refresh must actually reach the network")
        },

        TestCase(group: "Credential replacement",
                 name: "the reset is recorded, so the history explains itself") { expect in
            // Without an audit row the state appears to change on its own.
            let store = try RentalStore.makeInMemory()
            let dead = try listing(store, .revoked, url: "https://ical.booking.com/v1/export?t=old")
            _ = try replaceURL(store, dead, with: "https://ical.booking.com/v1/export?t=new")

            let events = try store.listings.connectionHistory(listingID: dead.id!)
            let reset = events.first { $0.toState == .unknown && $0.actor == "owner" }
            expect.ok(reset != nil, "a transition to unknown must be recorded")
            expect.equal(reset?.fromState, .revoked)
            expect.equal(reset?.actor, "owner", "the owner did this, not an import")
        },

        TestCase(group: "Credential replacement",
                 name: "an unreadable credential is still cleared by a new URL") { expect in
            // The case that already worked. It must keep working — this is how
            // Airbnb and Vrbo recover after the app is rebuilt and macOS stops
            // honouring the old Keychain ACL.
            let store = try RentalStore.makeInMemory()
            let stuck = try listing(store, .credentialUnreadable, url: "https://a.test/old.ics")
            let after = try replaceURL(store, stuck, with: "https://a.test/new.ics")
            expect.equal(after.connectionState, .unknown)
        },

        TestCase(group: "Credential replacement",
                 name: "every state that blocks importing is cleared, except the owner's own choice") { expect in
            // Stated as a rule rather than a list, so a state added later is
            // covered by the test that governs it.
            for state in FeedConnectionState.allCases where !state.shouldAttemptImport {
                let store = try RentalStore.makeInMemory()
                let item = try listing(store, state, url: "https://a.test/old.ics")
                let after = try replaceURL(store, item, with: "https://a.test/new.ics")

                if state == .disconnectedByOwner {
                    expect.equal(after.connectionState, .disconnectedByOwner,
                                 "a deliberate switch-off must not be undone by typing a URL")
                } else {
                    expect.equal(after.connectionState, .unknown,
                                 "\(state.rawValue) must be cleared by a new URL")
                }
            }
        },

        TestCase(group: "Credential replacement",
                 name: "a healthy connection is left alone") { expect in
            // The reset must not fire on every update, or a working feed would
            // forget it is working — and the audit trail would fill with noise.
            let store = try RentalStore.makeInMemory()
            let live = try listing(store, .connected, url: "https://a.test/old.ics")
            let after = try replaceURL(store, live, with: "https://a.test/new.ics")
            expect.equal(after.connectionState, .connected)
            let events = try store.listings.connectionHistory(listingID: live.id!)
            expect.ok(events.allSatisfy { $0.actor != "owner" },
                      "no spurious transition was recorded")
        },
    ] }
}
