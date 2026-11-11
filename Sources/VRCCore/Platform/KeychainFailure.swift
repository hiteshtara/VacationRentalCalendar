import Foundation

/// What a failed Keychain read actually tells us about a credential.
///
/// This exists because of 23:05 on 2026-11-10. A backup script launched a
/// second copy of the installed app to read credential health while the running
/// app's hourly refresh fired; two code objects asked for authorization on the
/// same items in the same second; two reads returned `-128`; and the import
/// path filed that under "this credential cannot be read" and latched
/// `credentialUnreadable`, which is never retried. Two calendars stopped
/// importing permanently because of a condition that lasted one second. The
/// third feed, read at the same instant, returned HTTP 200.
///
/// The lesson is the same one the four-second deadline taught: **a transient
/// condition must not be recorded as a settled fact.** So every status code is
/// classified here, in one place, as either something a later attempt could
/// get past or something only the owner can fix.
///
/// On the distinction between a dismissed dialog and one that could not be
/// shown: `errSecUserCanceled` is returned for BOTH, and the Security framework
/// offers nothing to tell them apart. Codes that unambiguously mean "a prompt
/// was required and unavailable" exist separately and are classified as such.
/// Where the platform is ambiguous this type says so rather than guessing,
/// because guessing is what turned one cancelled dialog into two dead feeds.
public enum KeychainFailure: Sendable, Equatable {

    /// `errSecUserCanceled` (-128). The authorization dialog was dismissed, or
    /// macOS could not present one. **These are indistinguishable.** Either
    /// way it says nothing about the stored value.
    case authorizationCancelled

    /// `errSecInteractionNotAllowed` (-25308), `errSecInteractionRequired`
    /// (-25315) or `errSecInDarkWake` (-25320). A prompt was needed and there
    /// was nowhere to show it — a background process, a locked session, or a
    /// Mac woken under Power Nap with no screen. Unambiguously about the
    /// moment, not the item.
    case interactionUnavailable

    /// `errSecAuthFailed` (-25293). The item's access list does not name this
    /// code object. Retrying cannot succeed, and each attempt holds the
    /// Keychain for the rest of the process. The fix is re-entering the URL.
    case accessDenied

    /// `errSecItemNotFound` (-25300). There is nothing stored under that name.
    case itemNotFound

    /// Anything not enumerated here. Retryable — see `isRetryable`.
    case other(OSStatus)

    // Spelled numerically rather than with the `errSec*` symbols so this type
    // compiles on Linux, where Security does not exist, and so the parity
    // build sees the same rules as the Mac.
    public static let userCanceled: OSStatus = -128
    public static let authFailed: OSStatus = -25293
    public static let noSuchItem: OSStatus = -25300
    public static let interactionNotAllowed: OSStatus = -25308
    public static let interactionRequired: OSStatus = -25315
    /// "In dark wake, no UI possible". The Mac woke under Power Nap to run a
    /// scheduled refresh and there was no screen to put a dialog on.
    public static let inDarkWake: OSStatus = -25320

    public static func of(_ status: OSStatus) -> KeychainFailure {
        switch status {
        case userCanceled: return .authorizationCancelled
        case interactionNotAllowed, interactionRequired, inDarkWake:
            return .interactionUnavailable
        case authFailed: return .accessDenied
        case noSuchItem: return .itemNotFound
        default: return .other(status)
        }
    }

    /// Whether a later attempt could plausibly succeed.
    ///
    /// **An unrecognised code is retryable**, and that is a reversal of the
    /// first version of this type, which defaulted the other way. The
    /// reasoning then was that an unlisted code might be one where the read
    /// blocks, poisoning every later Keychain call in the process. That risk
    /// is real, but it is already handled somewhere else:
    /// `DeadlineFeedCredentialStore` bounds every read and reports a timeout,
    /// which is itself retryable.
    ///
    /// What the conservative default actually bought was two outages. `-128`
    /// disabled two feeds on 2026-11-10, and `-25320` — dark wake, a Mac with
    /// no screen to show a dialog on — disabled all three overnight and spent
    /// thirteen hours recording disconnections. Both transient, neither
    /// anything to do with the stored value.
    ///
    /// "A transient condition must not be recorded as a settled fact" has to
    /// cover codes nobody has enumerated yet, or the next unlisted one does it
    /// again. So only codes KNOWN to be settled latch, and the hold-off in
    /// `AuthorizationCooloffFeedCredentialStore` is what stops retrying from
    /// becoming a stream of dialogs.
    public var isRetryable: Bool { !isSettledRefusal }

    /// Whether this is a settled answer the owner has to act on, as opposed to
    /// a condition of the moment.
    ///
    /// The complete list, and the only thing that stops a feed being retried:
    ///
    /// * `accessDenied` — the item's access list names other code. macOS does
    ///   not prompt for this, it refuses, and each attempt holds the Keychain
    ///   for the rest of the process. Re-entering the URL is the fix.
    /// * `itemNotFound` — there is nothing stored to read.
    ///
    /// Everything else is a condition of the moment.
    public var isSettledRefusal: Bool {
        switch self {
        case .accessDenied, .itemNotFound: return true
        case .authorizationCancelled, .interactionUnavailable, .other: return false
        }
    }

    /// Whether an authorization decision was involved, which is what makes
    /// repeating the attempt produce another dialog.
    public var involvedAuthorization: Bool {
        switch self {
        case .authorizationCancelled, .interactionUnavailable, .accessDenied: return true
        case .itemNotFound, .other: return false
        }
    }

    public var explanation: String {
        switch self {
        case .authorizationCancelled:
            return "The Keychain authorization was cancelled. macOS reports the same "
                + "code whether the dialog was dismissed or could not be shown, so this "
                + "says nothing about the saved URL. It will be tried again."
        case .interactionUnavailable:
            return "The Keychain needed to ask for permission and there was nowhere to "
                + "show the request — a locked screen, or the Mac briefly awake with the "
                + "display off. It will be tried again."
        case .accessDenied:
            return "This feed URL cannot be read: the Keychain item's access list names "
                + "a different build of this app. macOS does not prompt in this situation, "
                + "so there is no dialog to approve. Enter the URL again under Feeds — it "
                + "is saved under a fresh entry and nothing is deleted."
        case .itemNotFound:
            return "No feed URL is stored for this listing."
        case .other(let status):
            return "The Keychain refused the read (OSStatus \(status)). This is not a "
                + "known verdict about the saved URL, so it will be tried again."
        }
    }

    /// One line for the feed row.
    public var shortSummary: String {
        switch self {
        case .authorizationCancelled:
            return "Keychain permission was cancelled — will try again"
        case .interactionUnavailable:
            return "The Keychain could not ask for permission — will try again"
        case .accessDenied:
            return "Enter this listing's URL again — the saved one cannot be read"
        case .itemNotFound:
            return "No calendar URL configured."
        case .other:
            return "The Keychain refused the read — will try again"
        }
    }
}
