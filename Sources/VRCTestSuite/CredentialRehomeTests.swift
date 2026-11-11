import Foundation
import VRCCore

/// Moving a credential to a new code object, and knowing when one cannot be
/// read.
///
/// What went wrong on 2026-11-10. The app was rebuilt and installed, and
/// `migrate-cloud-credential.sh` re-homed the three feed URLs. The listings
/// were `connected` at the time, so nothing triggered versioning, and
/// `FeedCredentialStore.save` therefore took its UPDATE path — which preserves
/// the existing item's access list on purpose, so a working entry keeps the
/// grant the owner gave it.
///
/// That is right for an ordinary save and exactly wrong for a re-home. The
/// access list still named the PREVIOUS build's binaries, so the new ones held
/// only the transient grant from the migration's own prompts. Once that
/// lapsed, the GUI could not read the credentials — and neither could the
/// bundled CLI, after appearing to work for eleven minutes.
///
/// Re-homing must therefore always write to a FRESH reference, whose access
/// list is built for the code objects that exist now. Preserving the old grant
/// is the one thing a re-home must not do.
public enum CredentialRehomeTests {

    static func listing(
        _ store: RentalStore, state: FeedConnectionState, ref: String, url: String
    ) throws -> PlatformListing {
        let property = try store.properties.insert(Property(name: "39 G Street"))
        let inserted = try store.listings.insert(PlatformListing(
            propertyID: property.id!, platform: .airbnb, label: "Airbnb",
            icalURL: url, urlStorage: .keychain, credentialRef: ref))
        try store.listings.setConnectionState(
            listingID: inserted.id!, to: state, actor: "test")
        return try store.listings.find(id: inserted.id!)!
    }

    public static var cases: [TestCase] { [

        TestCase(group: "Credential re-home",
                 name: "re-homing a CONNECTED listing still writes a fresh reference") { expect in
            // The regression. A healthy listing keeps its reference on an
            // ordinary save — but a re-home is not an ordinary save, and this
            // is the case that silently locked both binaries out.
            let store = try RentalStore.makeInMemory()
            let live = try listing(store, state: .connected,
                                   ref: "airbnb-123-v5", url: "https://a.test/f.ics")
            expect.ok(live.connectionState.shouldAttemptImport, "precondition: healthy")

            var changed = live
            changed.icalURL = "https://a.test/f.ics"
            try store.listings.update(changed, rehomeCredential: true)

            expect.equal(try store.listings.find(id: live.id!)?.credentialRef, "airbnb-123-v6",
                         "a re-home must not inherit an access list built for other binaries")
        },

        TestCase(group: "Credential re-home",
                 name: "the superseded entry is left in place") { expect in
            // Nothing is deleted and no credential is regenerated: if the
            // re-home is wrong, the previous entry is still there.
            let store = try RentalStore.makeInMemory()
            let live = try listing(store, state: .connected,
                                   ref: "airbnb-123-v5", url: "https://a.test/old.ics")
            var changed = live
            changed.icalURL = "https://a.test/old.ics"
            try store.listings.update(changed, rehomeCredential: true)

            expect.equal(try store.credentials.url(reference: "airbnb-123-v5"),
                         "https://a.test/old.ics", "the old entry still holds the value")
            expect.equal(try store.credentials.url(reference: "airbnb-123-v6"),
                         "https://a.test/old.ics", "and the new one holds the same value")
        },

        TestCase(group: "Credential re-home",
                 name: "an ordinary save still keeps a healthy listing's reference") { expect in
            // The behaviour re-homing must not become. Versioning every save
            // would throw away the owner's Keychain grant on every edit.
            let store = try RentalStore.makeInMemory()
            let live = try listing(store, state: .connected,
                                   ref: "airbnb-123-v5", url: "https://a.test/f.ics")
            var changed = live
            changed.icalURL = "https://a.test/g.ics"
            try store.listings.update(changed)
            expect.equal(try store.listings.find(id: live.id!)?.credentialRef, "airbnb-123-v5")
        },

        // --- Knowing what cannot be read -------------------------------------

        // --- Telling "not set up" apart from "broken" ------------------------
        //
        // `vrc doctor` reported Test Cottage's three empty listings as
        // CREDENTIAL UNREADABLE, which reads as three broken credentials on a
        // property that has simply never been configured. It also made the gate
        // permanently red, so a genuinely unreadable credential would not have
        // stood out.
        //
        // The discriminator is whether a Keychain ITEM exists. `exists` reads
        // attributes only and never prompts, so this costs nothing and cannot
        // block. If there is no item there is no credential, and "unreadable"
        // is the wrong word for it.

        TestCase(group: "Credential health",
                 name: "a reference with nothing behind it is not configured, not broken") { expect in
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "Test Cottage"))
            let listing = try store.listings.insert(PlatformListing(
                propertyID: property.id!, platform: .airbnb, label: "Airbnb — Test Cottage",
                urlStorage: .keychain, credentialRef: "airbnb-p2-test-cottage"))

            let health = try store.credentialHealth()
            expect.equal(health.first { $0.listing.id == listing.id }?.status, .notConfigured)
            expect.equal(try store.unreadableCredentials().count, 0,
                         "an empty listing is not a failure")
        },

        TestCase(group: "Credential health",
                 name: "a listing with no reference at all is not configured") { expect in
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "Test Cottage"))
            let listing = try store.listings.insert(PlatformListing(
                propertyID: property.id!, platform: .vrbo, label: "Vrbo — Test Cottage",
                urlStorage: .keychain))
            let health = try store.credentialHealth()
            expect.equal(health.first { $0.listing.id == listing.id }?.status, .notConfigured)
        },

        TestCase(group: "Credential health",
                 name: "a stored credential that reads is reported readable") { expect in
            let store = try RentalStore.makeInMemory()
            let live = try listing(store, state: .connected,
                                   ref: "airbnb-123-v6", url: "https://a.test/f.ics")
            let health = try store.credentialHealth()
            expect.equal(health.first { $0.listing.id == live.id }?.status, .readable)
            expect.equal(try store.unreadableCredentials().count, 0)
        },

        TestCase(group: "Credential health",
                 name: "an item that exists but cannot be read IS a failure") { expect in
            // The case that must keep working. A credential whose access list
            // names a build that no longer exists is a real problem and has to
            // stay visible — that is the whole point of the check.
            let store = try RentalStore(
                database: Database.inMemory(),
                credentials: UnreadableFeedCredentialStore(presentReferences: ["airbnb-123-v6"]))
            let property = try store.properties.insert(Property(name: "39 G Street"))
            _ = try store.listings.insert(PlatformListing(
                propertyID: property.id!, platform: .airbnb, label: "Airbnb",
                urlStorage: .keychain, credentialRef: "airbnb-123-v6"))

            let health = try store.credentialHealth()
            expect.equal(health.first?.status, .unreadable)
            expect.equal(try store.unreadableCredentials().count, 1)
        },

        TestCase(group: "Credential health",
                 name: "a mixed portfolio reports each listing on its own terms") { expect in
            // Three configured and readable, three never set up — exactly 39 G
            // Street and Test Cottage as they stand.
            let store = try RentalStore.makeInMemory()
            let real = try store.properties.insert(Property(name: "39 G Street"))
            for (platform, ref) in [(RentalPlatform.airbnb, "airbnb-p1-v6"),
                                    (.vrbo, "vrbo-p1-v6"), (.bookingCom, "booking-p1-v3")] {
                _ = try store.listings.insert(PlatformListing(
                    propertyID: real.id!, platform: platform, label: platform.displayName,
                    icalURL: "https://a.test/\(ref).ics", urlStorage: .keychain,
                    credentialRef: ref))
            }
            let synthetic = try store.properties.insert(Property(name: "Test Cottage"))
            for platform in [RentalPlatform.airbnb, .vrbo, .bookingCom] {
                _ = try store.listings.insert(PlatformListing(
                    propertyID: synthetic.id!, platform: platform,
                    label: platform.displayName, urlStorage: .keychain,
                    credentialRef: "\(platform.rawValue)-p2-test-cottage"))
            }

            let health = try store.credentialHealth()
            expect.equal(health.filter { $0.status == .readable }.count, 3)
            expect.equal(health.filter { $0.status == .notConfigured }.count, 3)
            expect.equal(health.filter { $0.status == .unreadable }.count, 0)
            expect.equal(try store.unreadableCredentials().count, 0,
                         "an unconfigured property must not make the gate red")
        },

        TestCase(group: "Credential re-home",
                 name: "a readable credential is not reported") { expect in
            let store = try RentalStore.makeInMemory()
            _ = try listing(store, state: .connected,
                            ref: "airbnb-123-v5", url: "https://a.test/f.ics")
            expect.equal(try store.unreadableCredentials().count, 0)
        },

        TestCase(group: "Credential re-home",
                 name: "a listing with no reference at all is not reported") { expect in
            // A URL kept in the database column has no Keychain entry and is
            // not a credential problem.
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "39 G Street"))
            _ = try store.listings.insert(PlatformListing(
                propertyID: property.id!, platform: .vrbo, label: "Vrbo",
                icalURL: "https://a.test/f.ics", urlStorage: .database))
            expect.equal(try store.unreadableCredentials().count, 0)
        },
        TestCase(group: "Credential re-home",
                 name: "a listing with no URL yet claims no credential reference") { expect in
            // A reference with nothing behind it is indistinguishable from a
            // broken credential: doctor calls it unreadable and the migration
            // raises a prompt that cannot succeed. The reference is derived
            // when a URL is first saved, so there is nothing to gain by
            // reserving one early.
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "Test Cottage"))
            let inserted = try store.listings.insert(PlatformListing(
                propertyID: property.id!, platform: .airbnb, label: "Airbnb — Test Cottage",
                urlStorage: .keychain))

            let stored = try store.listings.find(id: inserted.id!)!
            expect.equal(stored.credentialRef, "", "no URL, so no reference")
            expect.equal(try store.unreadableCredentials().count, 0,
                         "and it must not be reported as a broken credential")
        },

        TestCase(group: "Credential re-home",
                 name: "the reference appears when a URL is first saved") { expect in
            // The other half: leaving it empty must not break the normal path.
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "Test Cottage"))
            let inserted = try store.listings.insert(PlatformListing(
                propertyID: property.id!, platform: .airbnb, label: "Airbnb — Test Cottage",
                urlStorage: .keychain))

            var withURL = try store.listings.find(id: inserted.id!)!
            withURL.icalURL = "https://a.test/f.ics"
            try store.listings.update(withURL)

            let after = try store.listings.find(id: inserted.id!)!
            expect.ok(!after.credentialRef.isEmpty, "a reference is derived on first save")
            expect.contains(after.credentialRef, "p\(property.id!)",
                            "and it is scoped to the property")
            expect.equal(try store.credentials.url(reference: after.credentialRef),
                         "https://a.test/f.ics")
        },
    ] }
}
