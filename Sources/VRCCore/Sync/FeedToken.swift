import Foundation

/// A bearer token for one property's feed to one destination.
///
/// The endpoint authenticates by the token alone — Booking.com and Airbnb
/// cannot sign a SigV4 request — so the token *is* the credential and
/// everything here follows from that:
///
///   * the secret is generated once, handed over once, and never printed
///     again; only its SHA-256 is stored in the grant table, so a leak of the
///     grant table does not leak a feed;
///   * one token per (property, destination), so revoking Airbnb's access
///     cannot disturb Vrbo's and cannot disturb an existing subscription;
///   * tokens are **never rotated automatically**. A rotation breaks whatever
///     platform is subscribed, silently, until someone notices nights
///     reopening. Rotation is an owner action with a stated consequence.
public struct FeedToken: Sendable, Equatable {

    public let propertyID: Int64
    public let destination: RentalPlatform
    public let version: Int
    /// SHA-256 of the secret. The only form that is ever stored.
    public let hash: String
    public let createdAt: Date
    public let retiredAt: Date?

    public var isActive: Bool { retiredAt == nil }

    /// Where this token's calendar lives in the bucket.
    ///
    /// Derived from property and destination rather than from the token, so
    /// the object key is stable across a rotation and a reader of the bucket
    /// learns nothing about the secret.
    public var objectKey: String {
        "ical/p\(propertyID)-\(destination.rawValue)-v\(version).ics"
    }

    public init(
        propertyID: Int64, destination: RentalPlatform, version: Int,
        hash: String, createdAt: Date, retiredAt: Date? = nil
    ) {
        self.propertyID = propertyID
        self.destination = destination
        self.version = version
        self.hash = hash
        self.createdAt = createdAt
        self.retiredAt = retiredAt
    }

    /// Generates a new secret and the record that accompanies it.
    ///
    /// Returns the secret exactly once. It is the caller's job to hand it to
    /// the owner and forget it; nothing in this type can recover it.
    public static func mint(
        propertyID: Int64, destination: RentalPlatform, version: Int,
        now: Date = Date(),
        randomBytes: (Int) -> [UInt8] = FeedToken.secureRandom
    ) -> (secret: String, token: FeedToken) {
        let secret = Self.encode(randomBytes(32))
        return (secret, FeedToken(
            propertyID: propertyID, destination: destination, version: version,
            hash: EventKey.sha256(secret), createdAt: now))
    }

    public static func secureRandom(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes
    }

    /// URL-safe, no padding, no characters a platform's URL parser will
    /// mangle.
    static func encode(_ bytes: [UInt8]) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    public func matches(secret: String) -> Bool {
        isActive && EventKey.sha256(secret) == hash
    }

    /// Retires this token without touching any other.
    public func revoked(at date: Date) -> FeedToken {
        FeedToken(propertyID: propertyID, destination: destination, version: version,
                  hash: hash, createdAt: createdAt, retiredAt: date)
    }
}

/// The grant table the endpoint reads: token hash → object key.
///
/// Built from the active tokens, and **merged** rather than replaced, because
/// the same table carries grants this app did not create — including one a
/// platform may already be subscribed to. Replacing it wholesale is how a
/// live calendar goes dark.
public enum FeedGrantTable {

    public static func entries(for tokens: [FeedToken]) -> [String: String] {
        var table: [String: String] = [:]
        for token in tokens where token.isActive {
            table[token.hash] = token.objectKey
        }
        return table
    }

    /// Adds ours to whatever is already there. Existing keys win on conflict:
    /// an entry we did not create is one we must not silently redirect.
    public static func merge(
        existing: [String: String], adding: [String: String]
    ) -> (table: [String: String], conflicts: [String]) {
        var table = existing
        var conflicts: [String] = []
        for (hash, key) in adding {
            if let current = table[hash], current != key {
                conflicts.append(hash)
                continue
            }
            table[hash] = key
        }
        return (table, conflicts)
    }

    /// Removes exactly one grant, leaving every other untouched.
    public static func revoking(_ hash: String, from existing: [String: String])
        -> [String: String] {
        var table = existing
        table.removeValue(forKey: hash)
        return table
    }
}
