import Foundation

/// First-run data.
///
/// Note what is *not* here: no feed URL. Each listing carries only the Keychain
/// account name its URL is stored under, so this file is safe to commit and the
/// credential never enters source control.
public enum SeedData {

    public struct ListingSeed: Sendable {
        public let platform: RentalPlatform
        public let label: String
        public let credentialRef: String
        public let autoRefresh: Bool
    }

    public struct PropertySeed: Sendable {
        public let name: String
        public let address: String
        public let notes: String
        public let listings: [ListingSeed]
    }

    /// 39 G Street, South Boston — Vrbo 5550554 and the Airbnb listing for the
    /// same unit. Both feeds are read-only imports.
    public static let gStreet = PropertySeed(
        name: "39 G Street",
        address: "39 G Street, South Boston, MA",
        notes: """
        Vrbo property ID 5550554. The Vrbo feed uses the ?nonTentative form, so \
        tentative holds are excluded by the platform before this app sees them.

        Both feeds are imported read-only. Airbnb's export for this unit labels \
        every unavailable range "Airbnb (Not available)" with no description, so \
        none of its blocks can be told apart from a booking by the feed alone — \
        every one of them needs your review before it can affect Vrbo or \
        Booking.com.
        """,
        listings: [
            ListingSeed(
                platform: .vrbo,
                label: "Vrbo — 39 G Street (5550554)",
                credentialRef: "vrbo-5550554",
                autoRefresh: true
            ),
            ListingSeed(
                platform: .airbnb,
                label: "Airbnb — 39 G Street",
                credentialRef: "airbnb-1759472334611502986",
                autoRefresh: true
            ),
        ]
    )

    public static let all: [PropertySeed] = [gStreet]

    /// Inserts the seed data unless a property with the same name already
    /// exists. Safe to call on every launch.
    @discardableResult
    public static func apply(to store: RentalStore) throws -> [String] {
        var created: [String] = []
        let existingNames = Set(try store.properties.all().map(\.name))

        for seed in all where !existingNames.contains(seed.name) {
            let property = try store.properties.insert(
                Property(name: seed.name, address: seed.address, notes: seed.notes)
            )
            guard let propertyID = property.id else { continue }
            created.append(seed.name)

            for listingSeed in seed.listings {
                try store.listings.insert(
                    PlatformListing(
                        propertyID: propertyID,
                        platform: listingSeed.platform,
                        label: listingSeed.label,
                        // Left empty on purpose: the URL is read from the
                        // Keychain under `credentialRef`.
                        icalURL: "",
                        urlStorage: .keychain,
                        credentialRef: listingSeed.credentialRef,
                        autoRefreshEnabled: listingSeed.autoRefresh
                    )
                )
                created.append("  \(listingSeed.platform.displayName): \(listingSeed.label)")
            }
        }
        return created
    }
}
