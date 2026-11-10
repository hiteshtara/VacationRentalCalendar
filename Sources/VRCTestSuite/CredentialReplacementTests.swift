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

    /// A listing whose URL lives in the credential store, so reference
    /// versioning is exercised rather than the plain database column.
    static func keychainListing(
        _ store: RentalStore, _ state: FeedConnectionState, url: String, ref: String
    ) throws -> PlatformListing {
        let property = try store.properties.insert(Property(name: "Southie Beach House"))
        let inserted = try store.listings.insert(PlatformListing(
            propertyID: property.id!, platform: .bookingCom,
            label: "Booking.com — Southie Beach House (17482435)",
            icalURL: url, urlStorage: .keychain, credentialRef: ref))
        try store.listings.setConnectionState(
            listingID: inserted.id!, to: state, actor: "test")
        return try store.listings.find(id: inserted.id!)!
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
        // --- Reference versioning -------------------------------------------
        //
        // Saving a new URL over an existing Keychain item preserves that
        // item's access list. For a WORKING entry that is exactly right — it
        // keeps the grant the owner already gave. For a dead one it is exactly
        // wrong: the list names an earlier build, macOS refuses the read
        // without prompting, and the item becomes permanently unreadable.
        //
        // Writing still succeeds, because writing and reading are authorised
        // separately. So the save looks fine and the next import fails as
        // `credential_unreadable` — which is what happened to Booking.com on
        // 2026-11-10 and made the owner paste the same URL twice.

        TestCase(group: "Credential replacement",
                 name: "replacing a revoked feed's URL writes to a fresh reference, first time") { expect in
            let store = try RentalStore.makeInMemory()
            let dead = try keychainListing(
                store, .revoked, url: "https://ical.booking.com/v1/export?t=old",
                ref: "booking-17482435")
            expect.ok(store.credentials.exists(reference: "booking-17482435"),
                      "precondition: an item already sits at the old reference")

            var changed = dead
            changed.icalURL = "https://ical.booking.com/v1/export?t=new"
            try store.listings.update(changed)

            let after = try store.listings.find(id: dead.id!)!
            expect.equal(after.credentialRef, "booking-17482435-v2",
                         "a dead credential must not inherit the old access list")
        },

        TestCase(group: "Credential replacement",
                 name: "the superseded credential is left untouched, never deleted") { expect in
            // Nothing is deleted and no credential is regenerated: if the new
            // URL turns out to be wrong, the old entry is still there.
            let store = try RentalStore.makeInMemory()
            let dead = try keychainListing(
                store, .revoked, url: "https://ical.booking.com/v1/export?t=old",
                ref: "booking-17482435")
            var changed = dead
            changed.icalURL = "https://ical.booking.com/v1/export?t=new"
            try store.listings.update(changed)

            expect.equal(try store.credentials.url(reference: "booking-17482435"),
                         "https://ical.booking.com/v1/export?t=old",
                         "the old entry still holds the old URL")
            expect.equal(try store.credentials.url(reference: "booking-17482435-v2"),
                         "https://ical.booking.com/v1/export?t=new",
                         "and the new URL is readable at the new reference")
        },

        TestCase(group: "Credential replacement",
                 name: "versioning follows the same rule as the state reset") { expect in
            // One rule, both places. A state that blocks importing gets a new
            // reference when a new URL arrives; the owner's own switch-off does
            // not, because nothing about that credential is suspect.
            for state in FeedConnectionState.allCases where !state.shouldAttemptImport {
                let store = try RentalStore.makeInMemory()
                let item = try keychainListing(
                    store, state, url: "https://a.test/old.ics", ref: "booking-ref")
                var changed = item
                changed.icalURL = "https://a.test/new.ics"
                try store.listings.update(changed)
                let after = try store.listings.find(id: item.id!)!

                if state.isClearedByANewURL {
                    expect.equal(after.credentialRef, "booking-ref-v2",
                                 "\(state.rawValue) must get a fresh reference")
                } else {
                    expect.equal(after.credentialRef, "booking-ref",
                                 "\(state.rawValue) keeps its reference and its grant")
                }
            }
        },

        TestCase(group: "Credential replacement",
                 name: "a healthy feed keeps its reference, so the owner's grant survives") { expect in
            // The blast radius. Versioning a working entry would throw away a
            // Keychain grant the owner gave and force them to re-approve it —
            // and the three live feeds must keep the references they have.
            for state in [FeedConnectionState.connected, .failing, .unknown] {
                let store = try RentalStore.makeInMemory()
                let live = try keychainListing(
                    store, state, url: "https://a.test/old.ics", ref: "vrbo-5550554-v5")
                var changed = live
                changed.icalURL = "https://a.test/new.ics"
                try store.listings.update(changed)
                let after = try store.listings.find(id: live.id!)!
                expect.equal(after.credentialRef, "vrbo-5550554-v5",
                             "\(state.rawValue) must not be re-versioned")
            }
        },

        TestCase(group: "Credential replacement",
                 name: "versioning increments rather than stacking suffixes") { expect in
            let store = try RentalStore.makeInMemory()
            let dead = try keychainListing(
                store, .revoked, url: "https://a.test/old.ics", ref: "airbnb-123-v5")
            var changed = dead
            changed.icalURL = "https://a.test/new.ics"
            try store.listings.update(changed)
            expect.equal(try store.listings.find(id: dead.id!)!.credentialRef, "airbnb-123-v6")
        },
    ] }
}
