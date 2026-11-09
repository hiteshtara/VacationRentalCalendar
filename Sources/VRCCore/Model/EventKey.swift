import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
// swift-crypto provides the same API surface under a different module name.
// SHA256, HMAC and SymmetricKey are source-compatible, so nothing below
// changes shape -- which matters, because an AWS SigV4 signature that differs
// by a byte is simply rejected, and the iCal event keys are persisted.
import Crypto
#endif

/// Stable identity for an imported event.
///
/// Classifications and export approvals hang off this key rather than off a
/// database row id, so a decision the owner made survives re-import, a feed
/// edit, a database rebuild, or the event vanishing and coming back.
public enum EventKey {
    public static func make(listingID: Int64, uid: String, recurrenceID: String?) -> String {
        let material = "\(listingID)\u{1F}\(uid)\u{1F}\(recurrenceID ?? "")"
        return sha256(material)
    }

    public static func sha256(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
