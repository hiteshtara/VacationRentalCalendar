import Foundation
import VRCCore

/// Everything a handler needs, assembled once per execution environment.
///
/// Built lazily and reused across invocations, because Lambda keeps the
/// process alive between them and rebuilding the store each time would mean a
/// fresh connection and a fresh secret fetch for no reason.
public final class ServiceContext: @unchecked Sendable {
    public let environment: [String: String]
    public let actor: String

    private let lock = NSLock()
    private var cachedStore: DataAPIStore?

    public init(
        actor: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.actor = actor
        self.environment = environment
    }

    /// The database. Deliberately absent from the fetcher, which is given no
    /// credential and would fail here — see `requireNoDatabase`.
    public func store() throws -> DataAPIStore {
        lock.lock(); defer { lock.unlock() }
        if let cachedStore { return cachedStore }
        var configuration = try DataAPIStore.Configuration.fromEnvironment(environment)
        configuration.actor = actor
        let store = DataAPIStore(
            transport: try URLSessionDataAPITransport.fromEnvironment(environment),
            configuration: configuration)
        cachedStore = store
        return store
    }

    public func value(_ key: String) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw LambdaRuntime.HandlerError(
                type: "Misconfigured", message: "\(key) is not set")
        }
        return value
    }

    public var outboundEnabled: Bool {
        (environment["VRC_OUTBOUND_ENABLED"] ?? "false").lowercased() == "true"
    }

    /// Asserts at runtime what IAM already enforces: this handler holds no
    /// database credential. Two independent statements of the same rule, so a
    /// future policy edit that widened the fetcher's access would still be
    /// caught here.
    public func requireNoDatabase() throws {
        if environment["VRC_DB_SECRET_ARN"] != nil {
            throw LambdaRuntime.HandlerError(
                type: "PrivilegeViolation",
                message: "this handler must not be given a database credential")
        }
    }
}
