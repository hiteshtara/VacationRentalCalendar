import Foundation

/// Resolves everything the Mac application needs to talk to the AWS service,
/// and reports plainly when it cannot.
///
/// Three things are needed: the API endpoint, an access key id, and a secret
/// access key. The endpoint is not a secret and lives in `app_settings`. The
/// two credential parts are secrets and live in the Keychain alongside the feed
/// URLs, under their own references, so they are never in the database, never
/// in the repository, and never printed.
///
/// Reading them can fail for an ordinary reason — not configured yet — or for
/// the Keychain-ACL reason that has bitten this project before. Those are
/// reported differently, because the first is a setup step and the second needs
/// the credential re-entering.
public struct CloudConnection: Sendable {
    public static let endpointSettingKey = "cloud_api_endpoint"
    public static let accessKeyReference = "aws-access-key-id"
    public static let secretKeyReference = "aws-secret-access-key"
    public static let regionSettingKey = "cloud_api_region"

    public enum Availability: Sendable, Equatable {
        /// Ready to use.
        case configured(endpoint: URL, region: String)
        /// Nothing has been set up yet. Not an error.
        case notConfigured(missing: [String])
        /// The credential exists but cannot be read.
        case credentialUnreadable(String)

        /// A stored endpoint that is not HTTPS. Rejected rather than used: the
        /// request carries a SigV4 signature and the service's own data.
        case insecureEndpoint(String)

        public var isConfigured: Bool {
            if case .configured = self { return true }
            return false
        }

        public var summary: String {
            switch self {
            case .configured(let endpoint, let region):
                return "\(endpoint.host ?? endpoint.absoluteString) · \(region)"
            case .notConfigured(let missing):
                return "not configured — missing \(missing.joined(separator: ", "))"
            case .insecureEndpoint(let text):
                return "endpoint is not HTTPS — \(text)"
            case .credentialUnreadable(let detail):
                return detail
            }
        }
    }

    public let settings: SettingsRepository
    public let credentials: FeedCredentialStore

    public init(settings: SettingsRepository, credentials: FeedCredentialStore) {
        self.settings = settings
        self.credentials = credentials
    }

    /// What is and is not set up, without attempting a network call.
    /// Configuration state without reading either secret.
    ///
    /// Called while drawing the interface, so it must not block: a Keychain
    /// read can sit waiting on an authorisation prompt, and at launch there is
    /// nobody to answer one. Presence is checked instead, which needs no
    /// approval. The full read happens only when the owner asks to refresh.
    public func presence() -> Availability {
        let endpointText = (try? settings.string(Self.endpointSettingKey)) ?? nil
        let region = ((try? settings.string(Self.regionSettingKey)) ?? nil) ?? "us-east-1"

        var missing: [String] = []
        if endpointText?.isEmpty ?? true { missing.append("endpoint") }
        if !credentials.exists(reference: Self.accessKeyReference) { missing.append("access key") }
        if !credentials.exists(reference: Self.secretKeyReference) { missing.append("secret key") }

        guard missing.isEmpty,
              let endpointText, let endpoint = URL(string: endpointText) else {
            return .notConfigured(missing: missing.isEmpty ? ["endpoint"] : missing)
        }
        guard Self.isSecure(endpointText) else { return .insecureEndpoint(endpointText) }
        return .configured(endpoint: endpoint, region: region)
    }

    /// Configuration state, reading both secrets. May block on a Keychain
    /// prompt, so it belongs behind an explicit action.
    public func availability() -> Availability {
        let endpointText = (try? settings.string(Self.endpointSettingKey)) ?? nil
        let region = ((try? settings.string(Self.regionSettingKey)) ?? nil) ?? "us-east-1"

        var missing: [String] = []
        if endpointText?.isEmpty ?? true { missing.append("endpoint") }

        let accessKey: String?
        let secretKey: String?
        do {
            accessKey = try credentials.url(reference: Self.accessKeyReference)
            secretKey = try credentials.url(reference: Self.secretKeyReference)
        } catch {
            // The Keychain refused. Distinct from "not set up".
            return .credentialUnreadable(
                "The AWS credential is stored but cannot be read. "
                + ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
        }
        if accessKey?.isEmpty ?? true { missing.append("access key") }
        if secretKey?.isEmpty ?? true { missing.append("secret key") }

        guard missing.isEmpty,
              let endpointText, let endpoint = URL(string: endpointText) else {
            return .notConfigured(missing: missing.isEmpty ? ["endpoint"] : missing)
        }
        // Checked on the way out as well as on the way in, so an endpoint
        // written to the database by any other route still cannot be used.
        guard Self.isSecure(endpointText) else {
            return .insecureEndpoint(endpointText)
        }
        return .configured(endpoint: endpoint, region: region)
    }

    /// A client, or nil when not configured. Never throws for a missing
    /// configuration, because "not set up yet" is a normal state for the
    /// interface to display rather than an error to handle.
    public func makeClient(timeout: TimeInterval = 20) -> CloudSyncClient? {
        guard case .configured(let endpoint, let region) = availability() else { return nil }
        // `url(reference:)` returns an optional and can throw; `try?` makes it
        // doubly optional, so both layers are unwrapped explicitly.
        guard let accessKey = (try? credentials.url(reference: Self.accessKeyReference)) ?? nil,
              let secretKey = (try? credentials.url(reference: Self.secretKeyReference)) ?? nil
        else { return nil }

        return CloudSyncClient(
            configuration: .init(endpoint: endpoint, region: region),
            signer: SigV4Signer(accessKeyID: accessKey, secretAccessKey: secretKey,
                                region: region, service: "execute-api"),
            transport: URLSessionCloudTransport(timeout: timeout))
    }

    public static func isSecure(_ url: String) -> Bool {
        url.lowercased().hasPrefix("https://")
    }

    public func setEndpoint(_ url: String, region: String = "us-east-1") throws {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // Refused for the same reason plain-http feed URLs are: the request
        // carries a SigV4 signature, and over http both it and the reply are
        // readable in transit.
        guard Self.isSecure(trimmed) else {
            throw CloudConnectionError.insecureEndpoint(trimmed)
        }
        guard URL(string: trimmed) != nil else {
            throw CloudConnectionError.malformedEndpoint(trimmed)
        }
        try settings.set(Self.endpointSettingKey, trimmed)
        try settings.set(Self.regionSettingKey, region)
    }

    /// Stores the two credential parts. They go to the Keychain, never to the
    /// database — the same rule the feed URLs follow.
    public func setCredentials(accessKeyID: String, secretAccessKey: String) throws {
        try credentials.save(url: accessKeyID, reference: Self.accessKeyReference)
        try credentials.save(url: secretAccessKey, reference: Self.secretKeyReference)
    }
}

public enum CloudConnectionError: Error, LocalizedError, Equatable {
    case insecureEndpoint(String)
    case malformedEndpoint(String)

    public var errorDescription: String? {
        switch self {
        case .insecureEndpoint(let text):
            return "The endpoint must be https — \(text) was refused."
        case .malformedEndpoint(let text):
            return "That is not a usable URL — \(text)."
        }
    }
}

/// What the interface shows about the cloud service.
///
/// Deliberately includes the failure states. A synchronisation indicator that
/// can only say "fine" is worse than none, because it invites the owner to
/// trust a feed that stopped updating.
public struct CloudSnapshot: Sendable, Equatable {
    public enum Health: Sendable, Equatable {
        case notConfigured(String)
        case unreachable(String)
        case degraded(String)
        case healthy
    }

    public var health: Health
    public var status: CloudSyncClient.Status?
    public var intervals: [CloudSyncClient.BlockingInterval]
    public var checkedAt: Date?

    public init(
        health: Health,
        status: CloudSyncClient.Status? = nil,
        intervals: [CloudSyncClient.BlockingInterval] = [],
        checkedAt: Date? = nil
    ) {
        self.health = health
        self.status = status
        self.intervals = intervals
        self.checkedAt = checkedAt
    }

    public static let unknown = CloudSnapshot(health: .notConfigured("not checked yet"))

    public var label: String {
        switch health {
        case .notConfigured(let detail): return detail
        case .unreachable(let detail): return detail
        case .degraded(let detail): return detail
        case .healthy: return "Connected"
        }
    }

    /// Never inferred from the absence of an error: only the service saying so.
    public var isRemoteSynchronised: Bool { status?.remoteSynchronised ?? false }
    public var outboundEnabled: Bool { status?.outboundEnabled ?? false }
}
