// Probes what this machine actually permits in the data protection keychain.
//
//   swift Scripts/keychain-probe.swift [access-group]
//
// Answers a question that cannot be settled by reading documentation: does a
// write to the data protection keychain succeed from a binary with no
// entitlements, and does it succeed with an access group?
//
// Isolated by construction. It uses a service name that exists nowhere else in
// the product, writes a fixed dummy value, and deletes what it wrote. It
// cannot see, alter or delete a real feed credential, and it never reads one.

import Foundation
import Security

let service = "com.vacationrentalcalendar.keychain-probe"
let account = "probe-\(UUID().uuidString.prefix(8))"
let dummy = "https://example.invalid/not-a-real-credential.ics"
let group = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil

func describe(_ status: OSStatus) -> String {
    let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
    return "\(status) (\(text))"
}

func attempt(label: String, accessGroup: String?) {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecUseDataProtectionKeychain as String: true,
        kSecAttrSynchronizable as String: false,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }

    var add = query
    add[kSecValueData as String] = Data(dummy.utf8)
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    print("  \(label)")
    print("    SecItemAdd           \(describe(addStatus))")

    if addStatus == errSecSuccess {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let readStatus = SecItemCopyMatching(read as CFDictionary, &item)
        let value = (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
        print("    SecItemCopyMatching  \(describe(readStatus))")
        print("    round trip           \(value == dummy ? "OK" : "MISMATCH")")
        // Always clean up. Nothing this script writes is allowed to survive it.
        print("    SecItemDelete        \(describe(SecItemDelete(query as CFDictionary)))")
    }
}

print("Data protection keychain probe")
print("  service: \(service)  (test-only; no real credential is touched)")
print("")
attempt(label: "without an access group", accessGroup: nil)
if let group {
    print("")
    attempt(label: "with access group \(group)", accessGroup: group)
}
