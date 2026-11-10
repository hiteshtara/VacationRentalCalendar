import Foundation

/// How a credential item should be stored, stated as policy rather than as a
/// Security framework call.
///
/// Separated from the `kSec*` plumbing on purpose. Which keychain, which
/// access group, which accessibility class, never synchronised, never an
/// access control list — those are decisions, and decisions should be
/// assertable on any platform, including the Linux build. Translating them
/// into CFDictionaries is Apple-only and is tested where it can run.
public struct KeychainItemSpec: Equatable, Sendable {

    /// When the system will hand the item over.
    public enum Accessibility: String, Equatable, Sendable {
        /// Only while the device is unlocked.
        case whenUnlocked
        /// After the first unlock since boot. Correct here: imports run on a
        /// timer and the screen may lock while the app is open, and
        /// `whenUnlocked` would make those fail silently.
        case afterFirstUnlock
    }

    public var service: String
    /// The credential reference. Carried through untouched — the database
    /// records it, and a changed one loses the pointer to the credential.
    public var account: String
    /// `<TeamID>.<group>`. Nil when no team identifier is configured, which
    /// means the policy is not usable and must not silently write anything.
    public var accessGroup: String?
    public var accessibility: Accessibility
    /// The data protection keychain, not the file keychain. The file keychain
    /// is where access control lists live, and the ACL is the thing being
    /// removed.
    public var usesDataProtectionKeychain: Bool
    /// iCloud Keychain. Always false: a feed URL is a bearer token for a whole
    /// booking calendar, and syncing it would put it on every device on the
    /// account.
    public var synchronizable: Bool
    /// Always false. Present so a regression is a failing assertion rather
    /// than an absence nobody notices.
    public var usesLegacyAccessControlList: Bool
}

/// Builds item specifications for this app.
///
/// The access group is the heart of it. A macOS file-keychain ACL identifies
/// code by its designated requirement, which for this project has repeatedly
/// been the binary's code hash — so every rebuild orphans every credential.
/// An access group belongs to the signing TEAM instead, so the app and its
/// bundled helper share one, and rebuilding changes nothing.
///
/// It is also the only scheme available under App Sandbox, which makes this
/// the same piece of work as the App Store move rather than a separate one.
public struct KeychainPolicy: Sendable {
    public let teamID: String
    public let service: String
    /// The group every code object in the bundle shares.
    public static let groupSuffix = "com.vacationrentalcalendar.shared"

    public init(teamID: String, service: String) {
        self.teamID = teamID
        self.service = service
    }

    /// `<TeamID>.<suffix>`, or nil when there is no team identifier.
    public var accessGroup: String? {
        teamID.isEmpty ? nil : "\(teamID).\(Self.groupSuffix)"
    }

    /// Whether this policy can actually be used. An unsigned or
    /// team-less build must be refused rather than left to write ungrouped
    /// items that only the creating binary can read — which is the old bug
    /// with a new name.
    public var isUsable: Bool { accessGroup != nil }

    public func spec(forReference reference: String) -> KeychainItemSpec {
        KeychainItemSpec(
            service: service,
            account: reference,
            accessGroup: accessGroup,
            accessibility: .afterFirstUnlock,
            usesDataProtectionKeychain: true,
            synchronizable: false,
            usesLegacyAccessControlList: false)
    }
}
