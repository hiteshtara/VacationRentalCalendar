import Foundation
import CryptoKit

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
        let digest = CryptoKit.SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
