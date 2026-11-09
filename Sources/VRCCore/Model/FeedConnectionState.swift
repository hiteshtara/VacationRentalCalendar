import Foundation

/// The standing state of a platform feed connection.
///
/// Distinct from "did the last fetch work?" on purpose. A revoked token is a
/// settled fact about the connection — retrying it a hundred times will not
/// change the answer, and treating it as a flaky network makes the app noisy
/// and, worse, makes a permanent problem look temporary.
public enum FeedConnectionState: String, CaseIterable, Sendable, Identifiable {
    /// No URL has been supplied yet.
    case notConfigured = "not_configured"
    /// A URL is present and the last fetch worked.
    case connected
    /// The platform rejected the credential — token revoked, deleted, or the
    /// connection it belonged to was torn down. Not retried.
    case revoked
    /// The owner switched it off deliberately.
    case disconnectedByOwner = "disconnected_by_owner"
    /// A Keychain item exists but this build cannot read it, because its
    /// access list names an earlier build by code hash. macOS does not prompt
    /// in this case, it simply refuses — and an abandoned read holds the
    /// keychain for the rest of the process, so no further attempt is made.
    case credentialUnreadable = "credential_unreadable"
    /// A URL is present but the last fetch failed in a way that may be
    /// temporary. Still retried.
    case failing
    /// State not yet established, e.g. a listing created before this column.
    case unknown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .credentialUnreadable: return "Needs the URL entered again"
        case .notConfigured: return "Not set up"
        case .connected: return "Connected"
        case .revoked: return "Disconnected by the platform"
        case .disconnectedByOwner: return "Disconnected by you"
        case .failing: return "Having trouble"
        case .unknown: return "Unknown"
        }
    }

    /// Whether the app should keep fetching this feed.
    ///
    /// A revoked credential is never retried: the platform has already given
    /// its answer, and hammering it only produces noise and a misleading
    /// failure history.
    public var shouldAttemptImport: Bool {
        switch self {
        case .connected, .failing, .unknown: return true
        // Deliberately never retried: the read cannot succeed, and attempting
        // it blocks every later Keychain operation in this process.
        case .notConfigured, .revoked, .disconnectedByOwner, .credentialUnreadable:
            return false
        }
    }

    /// Whether this is a deliberate, settled disconnection as opposed to a
    /// malfunction.
    public var isDisconnected: Bool {
        self == .revoked || self == .disconnectedByOwner
    }

    public var explanation: String {
        switch self {
        case .credentialUnreadable:
            return "The saved URL cannot be read by this build of the app. Its Keychain entry "
                + "was created by an earlier, differently-signed build, and macOS will not "
                + "transfer that permission or offer a prompt. Enter the URL again and it will "
                + "be saved to a fresh entry this build owns. Nothing is deleted."
        case .notConfigured:
            return "No calendar URL has been added for this listing yet."
        case .connected:
            return "Importing normally."
        case .revoked:
            return "The platform no longer accepts this calendar URL. That usually means the "
                + "connection it came from was deleted, so the link stopped working. It will "
                + "not be retried until you supply a new one."
        case .disconnectedByOwner:
            return "You turned this feed off. Nothing is imported from it."
        case .failing:
            return "The last import did not succeed. It will be retried."
        case .unknown:
            return "This feed has not been checked yet."
        }
    }

    /// What the owner should do, if anything.
    public var nextStep: String? {
        switch self {
        case .credentialUnreadable:
            return "Quit and reopen the app, then enter this listing's URL again under Feeds."
        case .revoked:
            return "Generate a fresh export URL on the platform and add it here."
        case .notConfigured:
            return "Add the listing's calendar export URL."
        case .failing:
            return "No action needed yet — it will be retried."
        default:
            return nil
        }
    }
}

/// One recorded change of connection state.
public struct ConnectionEvent: Identifiable, Sendable {
    public var id: Int64?
    public var listingID: Int64
    public var at: Date
    public var fromState: FeedConnectionState?
    public var toState: FeedConnectionState
    public var actor: String
    public var detail: String
    public var httpStatus: Int?

    public init(
        id: Int64? = nil,
        listingID: Int64,
        at: Date = Date(),
        fromState: FeedConnectionState? = nil,
        toState: FeedConnectionState,
        actor: String = "system",
        detail: String = "",
        httpStatus: Int? = nil
    ) {
        self.id = id
        self.listingID = listingID
        self.at = at
        self.fromState = fromState
        self.toState = toState
        self.actor = actor
        self.detail = detail
        self.httpStatus = httpStatus
    }

    public var line: String {
        var text = "\(DayMath.mediumString(at))  "
        if let fromState { text += "\(fromState.rawValue) → " }
        text += toState.rawValue
        if let httpStatus { text += "  (HTTP \(httpStatus))" }
        if !detail.isEmpty { text += "  — \(detail)" }
        return text
    }
}
