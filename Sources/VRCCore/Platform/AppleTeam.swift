import Foundation
#if canImport(Security)
import Security
#endif

/// The Apple signing team this application is distributed under.
///
/// A Team ID is **not a secret**. It appears in every signature the app
/// carries and in the access group of every Keychain item it creates, and
/// Gatekeeper shows it to anyone who asks. It is tracked in Git deliberately,
/// in exactly one place, so the build scripts, the entitlements and the
/// Keychain policy cannot drift apart — a drift that would be invisible until
/// credentials silently stopped being shared.
///
/// `Scripts/apple-config.sh` holds the same two values for the shell side, and
/// a test asserts the two agree rather than trusting them to.
public enum AppleTeam {
    /// Individual enrolment, active from 2026-11-10.
    public static let identifier = "26JLFSV9YS"

    /// The policy this app uses in production.
    public static var keychainPolicy: KeychainPolicy {
        KeychainPolicy(teamID: identifier, service: FeedCredentialService.name)
    }

    /// The team identifier of the code that is actually running.
    ///
    /// Preferred over the constant wherever it is available: it is the truth
    /// about this binary rather than a claim in source. Returns nil for
    /// unsigned or ad-hoc-signed builds, which is itself the useful answer —
    /// those cannot use an access group at all.
    public static func runningTeamIdentifier() -> String? {
        #if canImport(Security)
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        // kSecCSSigningInformation is REQUIRED: without it the returned
        // dictionary carries no team identifier and this silently reports an
        // unsigned build. A correctly signed Developer ID app then falls back
        // to the login Keychain forever, which is the exact failure this type
        // exists to detect.
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return (team?.isEmpty ?? true) ? nil : team
        #else
        return nil
        #endif
    }

    /// Whether the running build can actually use the access group.
    ///
    /// False for every ad-hoc or self-signed build, which is why the Keychain
    /// replacement cannot be exercised before a real certificate exists. A
    /// probe on 2026-11-10 confirmed it: `SecItemAdd` to the data protection
    /// keychain returned `-34018`, a missing entitlement, both with and
    /// without an access group.
    public static var runningCodeCanUseAccessGroup: Bool {
        runningTeamIdentifier() == identifier
    }
}

/// The Keychain service name, in one place for the same reason.
public enum FeedCredentialService {
    public static let name = "com.vacationrentalcalendar.feed-url"
}
