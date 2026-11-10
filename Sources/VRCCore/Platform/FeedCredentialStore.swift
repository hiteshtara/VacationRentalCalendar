import Foundation
#if canImport(Security)
import Security
#endif

/// A platform iCal export URL is a credential, not a setting.
///
/// Airbnb, Vrbo and Booking.com all authenticate those URLs by obscurity alone:
/// the URL contains a long random token and anyone holding it can read the
/// whole booking calendar for that listing, with no password. So feed URLs are
/// kept out of the SQLite file and out of any export, and live in the Keychain.
public protocol FeedCredentialStore: Sendable {
    func save(url: String, reference: String) throws
    func url(reference: String) throws -> String?
    func delete(reference: String) throws
    /// Shown in the UI so the owner knows where their URLs actually ended up.
    var storageDescription: String { get }
    /// Whether a credential is stored, without reading its value. Must not
    /// prompt — it is called while drawing the interface.
    func exists(reference: String) -> Bool
}

public extension FeedCredentialStore {
    func exists(reference: String) -> Bool {
        ((try? url(reference: reference)) ?? nil) != nil
    }
}

public enum FeedCredentialError: Error, LocalizedError {
    case keychainFailure(OSStatus, String)
    case timedOut
    case notFound(reference: String)

    public var errorDescription: String? {
        switch self {
        case .keychainFailure(let status, let operation):
            return "Keychain \(operation) failed (OSStatus \(status))."
        case .notFound(let reference):
            return "No feed URL is stored under \"\(reference)\"."
        case .timedOut:
            return "This feed URL cannot be read, and macOS will not offer to fix it.\n\n"
                + "The Keychain item's access list names an older build of this app by its "
                + "code hash. The app has since been signed with a certificate, so its hash "
                + "changed and no longer matches. macOS does not prompt in this situation — it "
                + "simply refuses — so there is no dialog to approve.\n\n"
                + "Fix it by entering the URL again under Feeds. It is saved under a fresh "
                + "Keychain entry owned by the current app, and the old entry is left untouched. "
                + "Nothing is deleted and no credential is regenerated."
        }
    }
}

// MARK: - Keychain

/// Generic-password items in the login keychain, one per listing.
///
/// Two details decide whether this works in practice, and both were learned the
/// hard way on this machine:
///
/// 1. **The app must create its own items.** A macOS keychain ACL records which
///    code may read an item. An item created by `/usr/bin/security` lists
///    `security` and nothing else, so the app blocks on an authorisation prompt
///    forever. Items this type creates list the running app, so it reads them
///    back silently, including after a restart.
///
/// 2. **The signing identity must be stable.** An ACL entry identifies code by
///    its designated requirement. For an ad-hoc signature that is the code
///    hash, which changes on every rebuild, so every rebuild asks again. Signed
///    with a real or self-signed certificate, the requirement is tied to the
///    certificate instead and survives rebuilds. See `Scripts/setup-signing.sh`.
#if canImport(Security)
public struct KeychainFeedCredentialStore: FeedCredentialStore {
    public let service: String
    /// Extra executables added to each new item's ACL, so one grant covers both
    /// the app bundle and the `vrc` command-line tool.
    public let additionalTrustedPaths: [String]

    public init(
        service: String = "com.vacationrentalcalendar.feed-url",
        additionalTrustedPaths: [String] = []
    ) {
        self.service = service
        self.additionalTrustedPaths = additionalTrustedPaths
    }

    public var storageDescription: String { "macOS Keychain (login)" }

    private func baseQuery(_ reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
    }

    /// Builds an ACL naming this process plus any extra executables. Returns
    /// nil when the ACL cannot be built, in which case the item is created with
    /// the default ACL — which still names the creating app.
    private func makeAccess() -> SecAccess? {
        var paths = additionalTrustedPaths
        paths.insert(Bundle.main.executablePath ?? CommandLine.arguments[0], at: 0)

        var trusted: [SecTrustedApplication] = []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            var application: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &application) == errSecSuccess,
               let application {
                trusted.append(application)
            }
        }
        guard !trusted.isEmpty else { return nil }

        var access: SecAccess?
        let status = SecAccessCreate(
            "Vacation Rental Calendar feed URL" as CFString,
            trusted as CFArray,
            &access
        )
        return status == errSecSuccess ? access : nil
    }

    public func save(url: String, reference: String) throws {
        let data = Data(url.utf8)
        let query = baseQuery(reference)

        // Update in place when the item already exists, so its ACL — and the
        // grant the owner already gave — is preserved.
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            let status = SecItemUpdate(
                query as CFDictionary, [kSecValueData as String: data] as CFDictionary
            )
            guard status == errSecSuccess else {
                throw FeedCredentialError.keychainFailure(status, "update")
            }
            return
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "Vacation Rental Calendar feed URL"
        attributes[kSecAttrDescription as String] = "Private platform calendar export URL"
        attributes[kSecAttrComment as String] =
            "Read-only iCal export URL. Treat as a password: anyone holding it can read this "
            + "listing's booking calendar."
        if let access = makeAccess() {
            attributes[kSecAttrAccess as String] = access
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw FeedCredentialError.keychainFailure(status, "add")
        }
    }

    public func url(reference: String) throws -> String? {
        var query = baseQuery(reference)
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
        let status = SecItemDelete(baseQuery(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FeedCredentialError.keychainFailure(status, "delete")
        }
    }

    /// Whether an item exists, without reading its contents. Checking presence
    /// does not need ACL approval, so this never prompts and is safe to call
    /// while drawing the UI.
    public func exists(reference: String) -> Bool {
        var query = baseQuery(reference)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

/// How the running code is signed, which is what decides whether Keychain
/// grants survive a rebuild.
public struct CodeSignatureInfo: Sendable {
    public enum Kind: String, Sendable {
        case unsigned
        case adHoc
        case certificate

        /// Whether the code's *identity* is stable across rebuilds.
        ///
        /// NOT whether Keychain access survives one. It does not: items are
        /// written with `SecTrustedApplicationCreateFromPath`, which pins the
        /// binary's code hash at the moment of writing, so a rebuild loses
        /// access even when the certificate and designated requirement are
        /// byte-identical. Conflating the two caused a real outage — an app
        /// update silently disconnected every platform feed.
        public var identityIsStable: Bool { self == .certificate }
    }

    public var kind: Kind
    public var identifier: String?
    public var authority: String?

    public init(kind: Kind, identifier: String? = nil, authority: String? = nil) {
        self.kind = kind
        self.identifier = identifier
        self.authority = authority
    }

    public var explanation: String {
        switch kind {
        case .certificate:
            return "Signed with \(authority ?? "a certificate"), so Keychain permission granted "
                + "once keeps working after you rebuild the app."
        case .adHoc:
            return "Ad-hoc signed. macOS will ask for Keychain permission again after every "
                + "rebuild, because an ad-hoc signature changes each time. Run "
                + "Scripts/setup-signing.sh once to fix that permanently."
        case .unsigned:
            return "Unsigned. macOS cannot remember a Keychain grant for unsigned code. Run "
                + "Scripts/setup-signing.sh once."
        }
    }

    /// Reads the signature of the running executable.
    public static func current() -> CodeSignatureInfo {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return CodeSignatureInfo(kind: .unsigned)
        }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as NSDictionary? else {
            return CodeSignatureInfo(kind: .unsigned)
        }

        let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
        let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate]

        guard let certificates, let leaf = certificates.first else {
            // No certificate chain: ad-hoc if there is a signature at all.
            let hasSignature = dictionary[kSecCodeInfoIdentifier as String] != nil
            return CodeSignatureInfo(
                kind: hasSignature ? .adHoc : .unsigned, identifier: identifier
            )
        }
        let authority = SecCertificateCopySubjectSummary(leaf) as String?
        return CodeSignatureInfo(kind: .certificate, identifier: identifier, authority: authority)
    }
}
#endif // canImport(Security)

// MARK: - In memory (tests)

public final class InMemoryFeedCredentialStore: FeedCredentialStore, @unchecked Sendable {
    private var table: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public var storageDescription: String { "in-memory (test only)" }

    public func save(url: String, reference: String) throws {
        lock.lock(); defer { lock.unlock() }
        table[reference] = url
    }

    public func url(reference: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return table[reference]
    }

    public func delete(reference: String) throws {
        lock.lock(); defer { lock.unlock() }
        table.removeValue(forKey: reference)
    }
}

// MARK: - Deadline guard

/// Runs credential reads with a deadline.
///
/// This exists because of a hard lesson from this machine: a locally built,
/// ad-hoc-signed binary reading a Keychain item it does not own blocks forever
/// on an authorisation prompt that the app cannot see or dismiss. An app that
/// freezes on launch is worse than one that explains itself, so every Keychain
/// call gets a time limit and the app carries on without it.
public final class DeadlineFeedCredentialStore: FeedCredentialStore, @unchecked Sendable {
    private let wrapped: FeedCredentialStore
    private let timeout: TimeInterval

    /// The bound exists so an abandoned authorisation prompt cannot freeze the
    /// app forever. Four seconds was too tight: on a busy machine an ordinary
    /// read exceeded it, and the timeout was misread as a broken credential,
    /// which silently disconnected three working feeds for an hour. Twenty
    /// still prevents a frozen app and no longer trips on load.
    public static let defaultTimeout: TimeInterval = 20

    public init(wrapping wrapped: FeedCredentialStore,
                timeout: TimeInterval = DeadlineFeedCredentialStore.defaultTimeout) {
        self.wrapped = wrapped
        self.timeout = timeout
    }

    public var storageDescription: String { wrapped.storageDescription }

    public func exists(reference: String) -> Bool { wrapped.exists(reference: reference) }

    private func withDeadline<T>(
        _ operation: @escaping @Sendable () throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        DispatchQueue.global(qos: .userInitiated).async {
            do { box.set(.success(try operation())) }
            catch { box.set(.failure(error)) }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw FeedCredentialError.timedOut
        }
        switch box.value {
        case .success(let value): return value
        case .failure(let error): throw error
        case .none: throw FeedCredentialError.timedOut
        }
    }

    public func save(url: String, reference: String) throws {
        let wrapped = self.wrapped
        try withDeadline { try wrapped.save(url: url, reference: reference) }
    }

    public func url(reference: String) throws -> String? {
        let wrapped = self.wrapped
        return try withDeadline { try wrapped.url(reference: reference) }
    }

    public func delete(reference: String) throws {
        let wrapped = self.wrapped
        try withDeadline { try wrapped.delete(reference: reference) }
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?

    func set(_ result: Result<T, Error>) {
        lock.lock(); defer { lock.unlock() }
        stored = result
    }

    var value: Result<T, Error>? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}


/// A credential store whose items EXIST but cannot be read.
///
/// Models the situation this project keeps hitting: a Keychain item whose
/// access list names a build that no longer exists, so `exists` succeeds and
/// the read fails. Test-only, and in VRCCore rather than the test target so
/// the Linux build compiles it too.
public final class UnreadableFeedCredentialStore: FeedCredentialStore, @unchecked Sendable {
    private let present: Set<String>
    public init(presentReferences: [String]) { self.present = Set(presentReferences) }

    public var storageDescription: String { "unreadable (test only)" }
    public func save(url: String, reference: String) throws {}
    public func delete(reference: String) throws {}
    public func exists(reference: String) -> Bool { present.contains(reference) }

    public func url(reference: String) throws -> String? {
        guard present.contains(reference) else { return nil }
        throw FeedCredentialError.keychainFailure(-25293, "read")
    }
}


/// A credential store whose reads never return in time.
///
/// Models the real failure of 2026-11-10: the machine was busy, a Keychain
/// read exceeded `DeadlineFeedCredentialStore`'s limit, and the timeout was
/// classified as "this build cannot read its credentials" — a latched state
/// that stops all further attempts. Three working feeds went silent and a
/// genuine Airbnb reservation went unseen for an hour.
///
/// Test-only, and in VRCCore rather than the test target so Linux compiles it.
public final class TimingOutFeedCredentialStore: FeedCredentialStore, @unchecked Sendable {
    public init() {}
    public var storageDescription: String { "times out (test only)" }
    public func save(url: String, reference: String) throws {}
    public func delete(reference: String) throws {}
    public func exists(reference: String) -> Bool { true }
    public func url(reference: String) throws -> String? {
        throw FeedCredentialError.timedOut
    }
}
