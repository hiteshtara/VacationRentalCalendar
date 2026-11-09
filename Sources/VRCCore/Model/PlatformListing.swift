import Foundation

/// Where a listing's iCal export URL actually lives.
public enum FeedURLStorage: String, Codable, CaseIterable, Sendable {
    /// Kept in the Keychain (or the protected-file fallback). The default for
    /// anything the owner types in, because the URL is a bearer credential.
    case keychain
    /// Kept in the SQLite file. Only for sample and fixture feeds that carry no
    /// secret, such as a `file://` path used by the tests.
    case database

    public var displayName: String {
        self == .keychain ? "Keychain (recommended)" : "Database (non-secret feeds only)"
    }
}

/// One platform's listing of one property, with its own iCal export URL.
public struct PlatformListing: Identifiable, Hashable, Sendable {
    public var id: Int64?
    public var propertyID: Int64
    public var platform: RentalPlatform
    /// Human label, e.g. "Vrbo — 39 G Street (5550554)".
    public var label: String
    /// The platform's calendar *export* URL. Read-only; never published onward.
    ///
    /// When `urlStorage == .keychain` this is populated from the credential
    /// store on read and written back to it on save — it is never persisted in
    /// the database in that mode.
    public var icalURL: String
    public var urlStorage: FeedURLStorage
    /// Keychain account name for this listing's URL.
    public var credentialRef: String
    /// Whether this listing's feed participates in automatic refresh.
    public var autoRefreshEnabled: Bool
    public var lastSyncAt: Date?
    public var lastSyncSummary: String
    /// Standing state of the connection, as distinct from the last fetch.
    public var connectionState: FeedConnectionState
    public var connectionChangedAt: Date?
    public var connectionDetail: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        propertyID: Int64,
        platform: RentalPlatform,
        label: String,
        icalURL: String = "",
        urlStorage: FeedURLStorage = .keychain,
        credentialRef: String = "",
        autoRefreshEnabled: Bool = true,
        lastSyncAt: Date? = nil,
        lastSyncSummary: String = "",
        connectionState: FeedConnectionState = .unknown,
        connectionChangedAt: Date? = nil,
        connectionDetail: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.propertyID = propertyID
        self.platform = platform
        self.label = label
        self.icalURL = icalURL
        self.urlStorage = urlStorage
        self.credentialRef = credentialRef
        self.autoRefreshEnabled = autoRefreshEnabled
        self.lastSyncAt = lastSyncAt
        self.lastSyncSummary = lastSyncSummary
        self.connectionState = connectionState
        self.connectionChangedAt = connectionChangedAt
        self.connectionDetail = connectionDetail
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var hasURL: Bool { !icalURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Whether an import should even be attempted. A revoked credential is
    /// never retried, regardless of the auto-refresh setting.
    public var isImportable: Bool {
        autoRefreshEnabled && connectionState.shouldAttemptImport
    }

    /// Host-only description, safe to show in the UI and in logs. The secret
    /// part of a feed URL is the path, so the path is never displayed.
    public var redactedURL: String {
        guard hasURL else { return "not set" }
        guard let components = URLComponents(string: icalURL), let host = components.host else {
            return "set (unparseable)"
        }
        return "https://\(host)/… (hidden)"
    }
}
