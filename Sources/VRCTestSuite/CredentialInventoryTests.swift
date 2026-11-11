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
    static let liveDatabaseReferences = [
        "vrbo-5550554-v6",
        "airbnb-1759472334611502986-v6",
        "booking-17482435-v3",
        // The Test Cottage listings reference names that were never stored.
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
                databaseReferences: ["feed-a"],
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
                databaseReferences: liveDatabaseReferences,
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
                databaseReferences: liveDatabaseReferences,
                keychainReferences: liveKeychainReferences)
            // 18 Keychain items, none dropped: the legacy copies are what a
            // rollback reads, so the migration must not treat them as junk.
            expect.equal(inventory.toMigrate.count, 18)
            expect.ok(inventory.toMigrate.contains("vrbo-5550554"),
                      "the original entry is kept")
            expect.ok(inventory.toMigrate.contains("booking-17482435-v2"))
        },

        TestCase(group: "Credential inventory",
                 name: "a reference pointing at nothing refuses the migration") { expect in
            // Test Cottage's three listings reference names never stored. A
            // disagreement between the database and the Keychain has to be
            // understood before anything is copied, not papered over.
            let inventory = CredentialInventory.compare(
                databaseReferences: liveDatabaseReferences,
                keychainReferences: liveKeychainReferences)
            expect.equal(inventory.referencedButMissing,
                         ["airbnb-p2-test-cottage", "booking_com-p2-test-cottage",
                          "vrbo-p2-test-cottage"])
            expect.ok(!inventory.isSafeToMigrate,
                      "dangling references are a stop condition")
            expect.contains(inventory.summary, "REFUSE")
        },

        TestCase(group: "Credential inventory",
                 name: "a clean inventory is safe and says what it will carry") { expect in
            let inventory = CredentialInventory.compare(
                databaseReferences: ["a", "b"], keychainReferences: ["a", "b", "c"])
            expect.ok(inventory.isSafeToMigrate)
            expect.equal(inventory.toMigrate, ["a", "b", "c"])
            expect.contains(inventory.summary, "3 secret(s) to migrate")
            expect.contains(inventory.summary, "would miss")
        },

        TestCase(group: "Credential inventory",
                 name: "the summary never contains a value, only names") { expect in
            // It is printed during a migration, so it must be safe to print.
            let inventory = CredentialInventory.compare(
                databaseReferences: ["vrbo-5550554-v6"],
                keychainReferences: ["vrbo-5550554-v6", "aws-secret-access-key"])
            let summary = inventory.summary
            expect.ok(!summary.contains("http"), "no URL can appear here")
            expect.ok(!summary.contains("AKIA"), "no key material either")
            expect.contains(summary, "aws-secret-access-key")
        },

        TestCase(group: "Credential inventory",
                 name: "empty names are ignored rather than migrated") { expect in
            let inventory = CredentialInventory.compare(
                databaseReferences: ["", "a"], keychainReferences: ["a", ""])
            expect.equal(inventory.toMigrate, ["a"])
            expect.ok(inventory.isSafeToMigrate)
        },
    ] }
}
