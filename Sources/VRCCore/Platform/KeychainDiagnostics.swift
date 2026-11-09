import Foundation
#if canImport(Security)
import Security
#endif

/// Why a Keychain item cannot be read, answered with the actual `OSStatus`
/// rather than a story about what probably went wrong.
///
/// This exists because a hard-coded explanation was wrong for months: the
/// interesting distinction is between macOS *refusing* an item and macOS
/// *wanting to ask* about it. Those look identical to a caller that only sees a
/// timeout, and they need opposite fixes. Interaction is switched off for the
/// duration of a probe, so "it would have prompted" becomes a returned status
/// instead of a hang.
///
/// No credential value is ever returned or logged — only whether bytes came
/// back.
public struct KeychainProbe: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case readable
        case absent
        /// macOS wanted to put up an authorisation dialog.
        case needsInteraction
        /// macOS refused outright; no dialog would help.
        case refused(OSStatus)
        /// Did not return within the deadline, even with interaction off.
        case blocked
        case otherFailure(OSStatus)
    }

    public var reference: String
    public var outcome: Outcome
    public var elapsed: TimeInterval

    public var isReadable: Bool { outcome == .readable }

    public var detail: String {
        switch outcome {
        case .readable: return "readable"
        case .absent: return "no item stored"
        case .needsInteraction:
            return "macOS wants to ask permission (errSecInteractionNotAllowed, -25308)"
        case .refused(let status):
            return "refused (OSStatus \(status))"
        case .blocked: return "did not return within the deadline"
        case .otherFailure(let status): return "failed (OSStatus \(status))"
        }
    }
}

#if canImport(Security)
public enum KeychainDiagnostics {
    /// Probes one item. Runs the read on its own thread with interaction
    /// disabled, so neither a dialog nor a poisoned session can wedge the
    /// caller.
    public static func probe(
        service: String = "com.vacationrentalcalendar.feed-url",
        reference: String,
        deadline: TimeInterval = 6
    ) -> KeychainProbe {
        let started = Date()
        let semaphore = DispatchSemaphore(value: 0)
        let box = StatusBox()

        Thread.detachNewThread {
            // Process-wide, and restored immediately afterwards. With
            // interaction off a prompt becomes errSecInteractionNotAllowed.
            SecKeychainSetUserInteractionAllowed(false)
            defer { SecKeychainSetUserInteractionAllowed(true) }

            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: reference,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            query[kSecReturnData as String] = true

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            // Only whether bytes arrived. The value itself is never kept.
            box.set(status: status, gotBytes: (item as? Data)?.isEmpty == false)
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + deadline) == .timedOut {
            return KeychainProbe(reference: reference, outcome: .blocked,
                                 elapsed: Date().timeIntervalSince(started))
        }

        let elapsed = Date().timeIntervalSince(started)
        let status = box.status
        let outcome: KeychainProbe.Outcome
        switch status {
        case errSecSuccess:
            outcome = box.gotBytes ? .readable : .otherFailure(status)
        case errSecItemNotFound:
            outcome = .absent
        case errSecInteractionNotAllowed, errSecInteractionRequired:
            outcome = .needsInteraction
        case errSecAuthFailed, errSecUserCanceled:
            outcome = .refused(status)
        default:
            outcome = .otherFailure(status)
        }
        return KeychainProbe(reference: reference, outcome: outcome, elapsed: elapsed)
    }

    /// Probes every reference a store is expected to hold.
    public static func probeAll(references: [String]) -> [KeychainProbe] {
        references.map { probe(reference: $0) }
    }

    /// Written to standard error when `VRC_KEYCHAIN_DIAGNOSTICS=1`, so the
    /// GUI's own view of the Keychain can be read from a terminal. The GUI and
    /// the command-line tool are separate code objects, and only the GUI's
    /// answer settles whether the app can read its credentials.
    public static func dumpIfRequested(references: [String], role: String) {
        guard ProcessInfo.processInfo.environment["VRC_KEYCHAIN_DIAGNOSTICS"] == "1" else {
            return
        }
        FileHandle.standardError.write(Data("""
            [keychain] role=\(role) \
            executable=\(Bundle.main.executablePath ?? CommandLine.arguments[0])

            """.utf8))
        for probe in probeAll(references: references) {
            let line = "[keychain] \(probe.reference): \(probe.detail) "
                + "(\(String(format: "%.2f", probe.elapsed))s)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}

private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: OSStatus = errSecSuccess
    private var bytes = false

    func set(status: OSStatus, gotBytes: Bool) {
        lock.lock(); defer { lock.unlock() }
        stored = status; bytes = gotBytes
    }

    var status: OSStatus { lock.lock(); defer { lock.unlock() }; return stored }
    var gotBytes: Bool { lock.lock(); defer { lock.unlock() }; return bytes }
}
#endif
