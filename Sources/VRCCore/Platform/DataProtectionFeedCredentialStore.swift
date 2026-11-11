import Foundation

#if canImport(Security)
import Security

/// A credential store backed by the **data protection keychain**.
///
/// The replacement for `KeychainFeedCredentialStore`. That one builds an
/// access control list naming specific binaries, which macOS matches by
/// designated requirement — in this project, the code hash — so every rebuild
/// orphans every credential. It is also unavailable under App Sandbox.
///
/// Here, access is granted by **access group**: a property of the signing
/// team, shared by the app and its bundled helper, unchanged by rebuilding.
/// The same mechanism is the only one a sandboxed App Store build can use, so
/// this is one piece of work rather than two.
///
/// Requires a team identifier and the `keychain-access-groups` entitlement.
/// Without them `KeychainPolicy.isUsable` is false and this type refuses to
/// write, rather than silently creating ungrouped items that only the creating
/// binary can read — which would be the original bug under a new name.
public struct DataProtectionFeedCredentialStore: FeedCredentialStore {
    public let policy: KeychainPolicy

    public init(policy: KeychainPolicy) { self.policy = policy }

    public var storageDescription: String {
        policy.isUsable
            ? "macOS data protection keychain (group \(policy.accessGroup ?? "—"))"
            : "data protection keychain — UNUSABLE, no team identifier"
    }

    /// Translates a policy decision into the Security framework's spelling.
    ///
    /// Deliberately the only place `kSec*` appears for this store, so the
    /// rules can be asserted as policy on any platform and this mapping can be
    /// checked once, here.
    public static func query(for spec: KeychainItemSpec) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: spec.service,
            kSecAttrAccount as String: spec.account,
            kSecUseDataProtectionKeychain as String: spec.usesDataProtectionKeychain,
            kSecAttrSynchronizable as String: spec.synchronizable,
        ]
        if let group = spec.accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        query[kSecAttrAccessible as String] = {
            switch spec.accessibility {
            case .whenUnlocked:     return kSecAttrAccessibleWhenUnlocked
            case .afterFirstUnlock: return kSecAttrAccessibleAfterFirstUnlock
            }
        }()
        // Note what is absent: kSecAttrAccess. No access control list, which is
        // the entire point.
        return query
    }

    private func guardUsable() throws {
        guard policy.isUsable else {
            throw FeedCredentialError.keychainFailure(errSecMissingEntitlement, "access group")
        }
    }

    public func save(url: String, reference: String) throws {
        try guardUsable()
        let spec = policy.spec(forReference: reference)
        var query = Self.query(for: spec)
        let data = Data(url.utf8)

        // Update in place if it exists. Safe here in a way it was NOT for the
        // file keychain: there is no access list to inherit, so an update
        // cannot carry forward a grant that names a build which no longer
        // exists.
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            let status = SecItemUpdate(
                query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else {
                throw FeedCredentialError.keychainFailure(status, "update")
            }
            return
        }
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw FeedCredentialError.keychainFailure(status, "add")
        }
    }

    public func url(reference: String) throws -> String? {
        try guardUsable()
        var query = Self.query(for: policy.spec(forReference: reference))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw FeedCredentialError.keychainFailure(status, "read")
        }
        return String(data: data, encoding: .utf8)
    }

    public func delete(reference: String) throws {
        try guardUsable()
        let status = SecItemDelete(
            Self.query(for: policy.spec(forReference: reference)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FeedCredentialError.keychainFailure(status, "delete")
        }
    }

    /// Presence without reading the value. Never prompts — the data protection
    /// keychain does not raise authorisation dialogs at all, which is one of
    /// the reasons for moving to it.
    public func exists(reference: String) -> Bool {
        guard policy.isUsable else { return false }
        var query = Self.query(for: policy.spec(forReference: reference))
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
#endif
