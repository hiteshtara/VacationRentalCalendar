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

        TestCase(group: "Credential re-home",
                 name: "a reference with nothing behind it counts as unreadable") { expect in
            // `vrc doctor` asked `(try? store.credentials.url(ref)) == nil`,
            // which is a DOUBLE optional: it is nil only when the read THREW.
            // A reference pointing at an item that is simply not there came
            // back as `.some(nil)` — and was reported as readable.
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "39 G Street"))
            _ = try store.listings.insert(PlatformListing(
                propertyID: property.id!, platform: .vrbo, label: "Vrbo",
                urlStorage: .keychain, credentialRef: "vrbo-missing-v1"))

            let unreadable = try store.unreadableCredentials()
            expect.equal(unreadable.count, 1, "a dangling reference is not readable")
            expect.equal(unreadable.first?.credentialRef, "vrbo-missing-v1")
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
    ] }
}
