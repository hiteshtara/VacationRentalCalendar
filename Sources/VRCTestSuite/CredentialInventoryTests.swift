import Foundation
import VRCCore

/// A migration must carry every secret, not every secret the database mentions.
///
/// The live audit on 2026-11-10 found six active secrets and only three
/// database rows: the three feed URLs are referenced by `platform_listings`,
/// while `aws-access-key-id`, `aws-secret-access-key` and
/// `feed-key-1-booking_com-v1` — the Booking.com outbound feed token — are
/// referenced by nothing. `feed_tokens` is empty. A migration written the
/// obvious way, by walking listings, would have moved three and silently left
/// three behind, including a token Booking.com is already subscribed to and
/// which cannot be reproduced.
public enum CredentialInventoryTests {

    /// The real inventory, as audited. Names only — these are account names,
    /// not secrets.
    static let liveConfiguredReferences = [
        "vrbo-5550554-v6",
        "airbnb-1759472334611502986-v6",
        "booking-17482435-v3",
    ]
    /// Placeholder names on listings that have never been given a URL. Not
    /// missing secrets — there is nothing to find.
    static let liveUnconfiguredReferences = [
        "airbnb-p2-test-cottage",
        "vrbo-p2-test-cottage",
        "booking_com-p2-test-cottage",
    ]
    static let liveKeychainReferences = [
        "vrbo-5550554-v6", "airbnb-1759472334611502986-v6", "booking-17482435-v3",
        "aws-access-key-id", "aws-secret-access-key", "feed-key-1-booking_com-v1",
        // Superseded entries, kept for rollback.
        "vrbo-5550554", "vrbo-5550554-v2", "vrbo-5550554-v3", "vrbo-5550554-v4",
        "vrbo-5550554-v5",
        "airbnb-1759472334611502986", "airbnb-1759472334611502986-v2",
        "airbnb-1759472334611502986-v3", "airbnb-1759472334611502986-v4",
        "airbnb-1759472334611502986-v5",
        "booking-17482435", "booking-17482435-v2",
    ]

    public static var cases: [TestCase] { [

        TestCase(group: "Credential inventory",
                 name: "a Keychain-only secret is still migrated") { expect in
            // The whole point. These three have no row anywhere.
            let inventory = CredentialInventory.compare(
                configuredReferences: ["feed-a"],
                keychainReferences: ["feed-a", "aws-access-key-id",
                                     "aws-secret-access-key", "feed-key-1-booking_com-v1"])
            expect.equal(inventory.referencedAndPresent, ["feed-a"])
            expect.equal(inventory.presentButUnreferenced,
                         ["aws-access-key-id", "aws-secret-access-key",
                          "feed-key-1-booking_com-v1"])
            expect.equal(inventory.toMigrate.count, 4, "all four, not just the referenced one")
            expect.ok(inventory.isSafeToMigrate)
        },

        TestCase(group: "Credential inventory",
                 name: "the live inventory carries all six active secrets") { expect in
            let inventory = CredentialInventory.compare(
                configuredReferences: liveConfiguredReferences,
                unconfiguredReferences: liveUnconfiguredReferences,
                keychainReferences: liveKeychainReferences)
            for required in ["vrbo-5550554-v6", "airbnb-1759472334611502986-v6",
                             "booking-17482435-v3", "aws-access-key-id",
                             "aws-secret-access-key", "feed-key-1-booking_com-v1"] {
                expect.ok(inventory.toMigrate.contains(required),
                          "\(required) must be migrated")
            }
        },

        TestCase(group: "Credential inventory",
                 name: "the superseded entries are carried too, so rollback stays possible") { expect in
            let inventory = CredentialInventory.compare(
                configuredReferences: liveConfiguredReferences,
                unconfiguredReferences: liveUnconfiguredReferences,
                keychainReferences: liveKeychainReferences)
            // 18 Keychain items, none dropped: the legacy copies are what a
            // rollback reads, so the migration must not treat them as junk.
            expect.equal(inventory.toMigrate.count, 18)
            expect.ok(inventory.toMigrate.contains("vrbo-5550554"),
                      "the original entry is kept")
            expect.ok(inventory.toMigrate.contains("booking-17482435-v2"))
        },

        TestCase(group: "Credential inventory",
                 name: "an UNCONFIGURED listing is not a missing secret") { expect in
            // Test Cottage's three listings carry placeholder reference names
            // that no URL was ever stored under. Treating those as missing
            // secrets made the whole live inventory unmigratable, which is
            // wrong: there is nothing to lose and nothing to find.
            //
            // Every listing is created with a reference name, so the string
            // existing proves nothing. The caller must say which listings were
            // actually configured, and that is evidenced — see `wasConfigured`.
            let inventory = CredentialInventory.compare(
                configuredReferences: ["vrbo-5550554-v6",
                                       "airbnb-1759472334611502986-v6",
                                       "booking-17482435-v3"],
                unconfiguredReferences: ["airbnb-p2-test-cottage",
                                         "vrbo-p2-test-cottage",
                                         "booking_com-p2-test-cottage"],
                keychainReferences: liveKeychainReferences)
            expect.equal(inventory.referencedButMissing, [],
                         "an unconfigured listing is not a blocker")
            expect.ok(inventory.isSafeToMigrate, inventory.summary)
            expect.equal(inventory.unconfiguredPlaceholders,
                         ["airbnb-p2-test-cottage", "booking_com-p2-test-cottage",
                          "vrbo-p2-test-cottage"])
            expect.ok(!inventory.toMigrate.contains("vrbo-p2-test-cottage"),
                      "and there is nothing of theirs to carry")
        },

        TestCase(group: "Credential inventory",
                 name: "a CONFIGURED listing whose credential vanished still blocks") { expect in
            // Requirement 2, and the distinction that matters. This listing
            // was configured and its Keychain item is gone: a real secret has
            // been lost, migrating would hide it, and it must stop the run.
            let inventory = CredentialInventory.compare(
                configuredReferences: ["vrbo-5550554-v6", "airbnb-gone-v2"],
                unconfiguredReferences: ["vrbo-p2-test-cottage"],
                keychainReferences: ["vrbo-5550554-v6"])
            expect.equal(inventory.referencedButMissing, ["airbnb-gone-v2"])
            expect.ok(!inventory.isSafeToMigrate, "a lost secret is a stop condition")
            expect.contains(inventory.summary, "REFUSE")
            expect.contains(inventory.summary, "airbnb-gone-v2")
        },

        TestCase(group: "Credential inventory",
                 name: "the two cases are never conflated, even together") { expect in
            let inventory = CredentialInventory.compare(
                configuredReferences: ["present-v1", "lost-v1"],
                unconfiguredReferences: ["placeholder-a", "placeholder-b"],
                keychainReferences: ["present-v1"])
            expect.equal(inventory.referencedAndPresent, ["present-v1"])
            expect.equal(inventory.referencedButMissing, ["lost-v1"])
            expect.equal(inventory.unconfiguredPlaceholders, ["placeholder-a", "placeholder-b"])
            expect.ok(!inventory.isSafeToMigrate)
        },

        TestCase(group: "Credential inventory",
                 name: "an unconfigured listing that DOES have an item is carried anyway") { expect in
            // Belt and braces: if a placeholder turns out to have a stored
            // value, it is a secret and it travels. Nothing present is left
            // behind on the strength of how it was classified.
            let inventory = CredentialInventory.compare(
                configuredReferences: [],
                unconfiguredReferences: ["surprise-ref"],
                keychainReferences: ["surprise-ref"])
            expect.ok(inventory.toMigrate.contains("surprise-ref"))
            expect.equal(inventory.unconfiguredPlaceholders, [],
                         "it is not a placeholder if something is stored under it")
            expect.ok(inventory.isSafeToMigrate)
        },

        TestCase(group: "Credential inventory",
                 name: "configuration is evidenced, not inferred from the name") { expect in
            // `wasConfigured` is the rule the caller uses to split the two
            // lists. A reference string is not evidence; a stored URL, a
            // successful import, or a connection state only reachable after a
            // credential existed, are.
            let bare = PlatformListing(
                id: 4, propertyID: 2, platform: .airbnb, label: "Test Cottage",
                credentialRef: "airbnb-p2-test-cottage", connectionState: .unknown)
            expect.ok(!CredentialInventory.wasConfigured(bare, hasSuccessfulImport: false),
                      "a placeholder reference alone means nothing")

            expect.ok(CredentialInventory.wasConfigured(bare, hasSuccessfulImport: true),
                      "a successful import proves a credential existed")

            var connected = bare
            connected.connectionState = .connected
            expect.ok(CredentialInventory.wasConfigured(connected, hasSuccessfulImport: false))

            var unreadable = bare
            unreadable.connectionState = .credentialUnreadable
            expect.ok(CredentialInventory.wasConfigured(unreadable, hasSuccessfulImport: false),
                      "an item that cannot be read is still an item")

            var inDatabase = bare
            inDatabase.icalURL = "https://example.test/f.ics"
            inDatabase.urlStorage = .database
            expect.ok(CredentialInventory.wasConfigured(inDatabase, hasSuccessfulImport: false))

            var notConfigured = bare
            notConfigured.connectionState = .notConfigured
            expect.ok(!CredentialInventory.wasConfigured(notConfigured, hasSuccessfulImport: false))
        },

        TestCase(group: "Credential inventory",
                 name: "the live listings classify as three configured, three not") { expect in
            // The real six, as audited. 1-3 have synced; 4-6 never have.
            let live: [(PlatformListing, Bool)] = [
                (PlatformListing(id: 1, propertyID: 1, platform: .vrbo, label: "Vrbo",
                                 credentialRef: "vrbo-5550554-v6",
                                 connectionState: .failing), true),
                (PlatformListing(id: 2, propertyID: 1, platform: .airbnb, label: "Airbnb",
                                 credentialRef: "airbnb-1759472334611502986-v6",
                                 connectionState: .failing), true),
                (PlatformListing(id: 3, propertyID: 1, platform: .bookingCom, label: "Booking",
                                 credentialRef: "booking-17482435-v3",
                                 connectionState: .connected), true),
                (PlatformListing(id: 4, propertyID: 2, platform: .airbnb, label: "TC Airbnb",
                                 credentialRef: "airbnb-p2-test-cottage",
                                 connectionState: .unknown), false),
                (PlatformListing(id: 5, propertyID: 2, platform: .vrbo, label: "TC Vrbo",
                                 credentialRef: "vrbo-p2-test-cottage",
                                 connectionState: .unknown), false),
                (PlatformListing(id: 6, propertyID: 2, platform: .bookingCom, label: "TC Booking",
                                 credentialRef: "booking_com-p2-test-cottage",
                                 connectionState: .unknown), false),
            ]
            let configured = live.filter {
                CredentialInventory.wasConfigured($0.0, hasSuccessfulImport: $0.1)
            }.map(\.0.credentialRef)
            let unconfigured = live.filter {
                !CredentialInventory.wasConfigured($0.0, hasSuccessfulImport: $0.1)
            }.map(\.0.credentialRef)

            expect.equal(configured.count, 3)
            expect.equal(unconfigured.count, 3)

            let inventory = CredentialInventory.compare(
                configuredReferences: configured,
                unconfiguredReferences: unconfigured,
                keychainReferences: liveKeychainReferences)
            expect.ok(inventory.isSafeToMigrate,
                      "the live inventory is migratable: " + inventory.summary)
            expect.equal(inventory.toMigrate.count, 18,
                         "all 18 stored items travel")
        },

        TestCase(group: "Credential inventory",
                 name: "a clean inventory is safe and says what it will carry") { expect in
            let inventory = CredentialInventory.compare(
                configuredReferences: ["a", "b"], keychainReferences: ["a", "b", "c"])
            expect.ok(inventory.isSafeToMigrate)
            expect.equal(inventory.toMigrate, ["a", "b", "c"])
            expect.contains(inventory.summary, "3 secret(s) to migrate")
            expect.contains(inventory.summary, "would miss")
        },

        TestCase(group: "Credential inventory",
                 name: "the summary never contains a value, only names") { expect in
            // It is printed during a migration, so it must be safe to print.
            let inventory = CredentialInventory.compare(
                configuredReferences: ["vrbo-5550554-v6"],
                keychainReferences: ["vrbo-5550554-v6", "aws-secret-access-key"])
            let summary = inventory.summary
            expect.ok(!summary.contains("http"), "no URL can appear here")
            expect.ok(!summary.contains("AKIA"), "no key material either")
            expect.contains(summary, "aws-secret-access-key")
        },

        TestCase(group: "Credential inventory",
                 name: "empty names are ignored rather than migrated") { expect in
            let inventory = CredentialInventory.compare(
                configuredReferences: ["", "a"], keychainReferences: ["a", ""])
            expect.equal(inventory.toMigrate, ["a"])
            expect.ok(inventory.isSafeToMigrate)
        },
    ] }
}
