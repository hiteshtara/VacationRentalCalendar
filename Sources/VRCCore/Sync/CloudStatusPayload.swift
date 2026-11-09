import Foundation

/// The only thing the `vrc` helper hands back to the GUI.
///
/// The GUI cannot read the AWS credential itself — on this machine a
/// login-keychain item is readable only by the exact code object that created
/// it (see docs/KEYCHAIN.md). So the GUI asks the bundled helper, which is the
/// authorized reader, and the helper returns *this* and nothing else.
///
/// By construction it carries no secret: no access key, no secret key, no
/// session token, no feed URL. Everything here is either a count, a boolean, a
/// service-supplied status string, or a date range — the same facts the Cloud
/// pane already displays. A reviewer can confirm the no-secret property by
/// reading the field list.
public struct CloudStatusPayload: Codable, Sendable, Equatable {
    public enum Health: String, Codable, Sendable {
        case healthy, degraded, unreachable, notConfigured, insecureEndpoint
    }

    /// Whether the helper reached the service and got a usable answer.
    public var ok: Bool
    public var health: Health
    /// A concise, secret-free sentence suitable for display.
    public var message: String

    public var liveSourceEvents: Int?
    public var approvedDecisions: Int?
    public var publishedDecisions: Int?
    public var openConflicts: Int?
    public var lastSuccessfulImport: String?
    public var outboundEnabled: Bool?
    public var remoteSynchronised: Bool?
    public var failingSources: [String: String]
    public var staleSources: [String: String]
    public var intervals: [Interval]

    public struct Interval: Codable, Sendable, Equatable {
        public var property: String
        public var from: String
        public var to: String
        public var basis: String
        public var source: String
    }

    public init(
        ok: Bool, health: Health, message: String,
        liveSourceEvents: Int? = nil, approvedDecisions: Int? = nil,
        publishedDecisions: Int? = nil, openConflicts: Int? = nil,
        lastSuccessfulImport: String? = nil, outboundEnabled: Bool? = nil,
        remoteSynchronised: Bool? = nil,
        failingSources: [String: String] = [:], staleSources: [String: String] = [:],
        intervals: [Interval] = []
    ) {
        self.ok = ok; self.health = health; self.message = message
        self.liveSourceEvents = liveSourceEvents
        self.approvedDecisions = approvedDecisions
        self.publishedDecisions = publishedDecisions
        self.openConflicts = openConflicts
        self.lastSuccessfulImport = lastSuccessfulImport
        self.outboundEnabled = outboundEnabled
        self.remoteSynchronised = remoteSynchronised
        self.failingSources = failingSources
        self.staleSources = staleSources
        self.intervals = intervals
    }

    /// Builds the payload from a live status and intervals.
    public static func reached(
        _ status: CloudSyncClient.Status, intervals: [CloudSyncClient.BlockingInterval]
    ) -> CloudStatusPayload {
        CloudStatusPayload(
            ok: true,
            health: status.isHealthy ? .healthy : .degraded,
            message: status.isHealthy
                ? "Connected"
                : "Connected — the service reports problems",
            liveSourceEvents: status.liveSourceEvents,
            approvedDecisions: status.approvedDecisions,
            publishedDecisions: status.publishedDecisions,
            openConflicts: status.openConflicts,
            lastSuccessfulImport: status.lastSuccessfulImport,
            outboundEnabled: status.outboundEnabled,
            remoteSynchronised: status.remoteSynchronised,
            failingSources: status.failingSources,
            staleSources: status.staleSources,
            intervals: intervals.map {
                Interval(property: $0.property, from: $0.from, to: $0.to,
                         basis: $0.basis, source: $0.source)
            })
    }

    public static func failure(_ health: Health, _ message: String) -> CloudStatusPayload {
        CloudStatusPayload(ok: false, health: health, message: message)
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"health":"unreachable","message":"could not encode status","#
                + #""failingSources":{},"staleSources":{},"intervals":[]}"#
        }
        return text
    }

    public static func decode(_ data: Data) -> CloudStatusPayload? {
        try? JSONDecoder().decode(CloudStatusPayload.self, from: data)
    }
}
