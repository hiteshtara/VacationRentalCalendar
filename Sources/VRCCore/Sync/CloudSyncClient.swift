import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Mac application's view of the cloud service.
///
/// Every request is SigV4-signed with an IAM credential from the Keychain, and
/// the API rejects anything unsigned before our code runs. There is no token
/// to refresh and no login state to get wrong — `SigV4Signer` is the one
/// already used for S3 and R2.
///
/// Reads are ordinary. Writes are not: a decision submitted twice must not
/// become two decisions, and a write whose outcome is unknown must not be
/// retried until it is known. Both are handled here rather than left to the
/// caller, because "did that apply?" is exactly the question a user cannot
/// answer.
public struct CloudSyncClient: Sendable {

    public struct Configuration: Sendable {
        public var endpoint: URL
        public var region: String
        public init(endpoint: URL, region: String = "us-east-1") {
            self.endpoint = endpoint
            self.region = region
        }
    }

    public struct Status: Sendable, Equatable {
        public var liveSourceEvents: Int
        public var approvedDecisions: Int
        public var publishedDecisions: Int
        public var openConflicts: Int
        public var lastSuccessfulImport: String
        public var outboundEnabled: Bool
        /// Always false from the service. Publishing a feed is not evidence a
        /// platform has read it, and the interface must never imply otherwise.
        public var remoteSynchronised: Bool
        /// Sources whose most recent import failed, with the reason.
        public var failingSources: [String: String]
        /// Sources whose last success is older than the freshness window.
        public var staleSources: [String: String]

        public var isHealthy: Bool { failingSources.isEmpty && staleSources.isEmpty }
    }

    public struct BlockingInterval: Sendable, Equatable {
        public var property: String
        public var from: String
        public var to: String
        public var basis: String
        public var source: String
    }

    /// The result of a mutating request. `uncertain` is a first-class outcome,
    /// not an error: the caller must reconcile before trying again.
    public enum WriteOutcome: Sendable, Equatable {
        case applied(id: String)
        /// The service recognised the idempotency key and did nothing.
        case alreadyApplied(id: String)
        case rejected(reason: String)
        case uncertain(reason: String)
    }

    public enum CloudError: Error, LocalizedError, Equatable {
        case notConfigured
        case unauthorised
        case serviceUnavailable(String)
        case malformed(String)
        case transport(String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "The cloud service is not configured on this Mac."
            case .unauthorised:
                return "The cloud service rejected this Mac's credentials. "
                    + "Check the IAM access key stored in the Keychain."
            case .serviceUnavailable(let detail):
                return "The cloud service could not answer: \(detail)"
            case .malformed(let detail):
                return "The cloud service returned something unreadable: \(detail)"
            case .transport(let detail):
                return "Could not reach the cloud service: \(detail)"
            }
        }
    }

    public struct Response: Sendable {
        public var statusCode: Int
        public var body: Data
        public init(statusCode: Int, body: Data) {
            self.statusCode = statusCode
            self.body = body
        }
    }

    /// Abstracted so the client is testable with no network and no credentials.
    public protocol Transport: Sendable {
        func send(_ request: URLRequest) throws -> Response
    }

    public let configuration: Configuration
    public let signer: SigV4Signer
    public let transport: Transport
    /// How old a source's last success may be before it is called stale.
    public let freshnessWindow: TimeInterval

    public init(
        configuration: Configuration,
        signer: SigV4Signer,
        transport: Transport,
        freshnessWindow: TimeInterval = 6 * 3600
    ) {
        self.configuration = configuration
        self.signer = signer
        self.transport = transport
        self.freshnessWindow = freshnessWindow
    }

    // MARK: Reads

    public func status() throws -> Status {
        let object = try get("/status")
        return Status(
            liveSourceEvents: object["liveSourceEvents"] as? Int ?? 0,
            approvedDecisions: object["approvedDecisions"] as? Int ?? 0,
            publishedDecisions: object["publishedDecisions"] as? Int ?? 0,
            openConflicts: object["openConflicts"] as? Int ?? 0,
            lastSuccessfulImport: object["lastSuccessfulImport"] as? String ?? "never",
            outboundEnabled: object["outboundEnabled"] as? Bool ?? false,
            // Never inferred: if the service does not say so, it is false.
            remoteSynchronised: object["remoteSynchronised"] as? Bool ?? false,
            failingSources: (object["failingSources"] as? [String: String]) ?? [:],
            staleSources: (object["staleSources"] as? [String: String]) ?? [:])
    }

    public func availability() throws -> [BlockingInterval] {
        let object = try get("/availability")
        guard let rows = object["blocking"] as? [[String: Any]] else {
            throw CloudError.malformed("no blocking intervals in the response")
        }
        return rows.map {
            BlockingInterval(
                property: $0["property"] as? String ?? "",
                from: $0["from"] as? String ?? "",
                to: $0["to"] as? String ?? "",
                basis: $0["basis"] as? String ?? "",
                source: $0["source"] as? String ?? "")
        }
    }

    // MARK: Writes

    /// Submits an owner-approved decision.
    ///
    /// The idempotency key is derived from the decision's own content, so a
    /// resubmission of the same decision carries the same key and the service
    /// can recognise it. A random key per attempt would defeat the point.
    public static func idempotencyKey(for decision: AvailabilityDecision) -> String {
        EventKey.sha256([
            String(decision.propertyID),
            decision.destination.rawValue,
            decision.action.rawValue,
            DayMath.icalDateString(decision.startDay),
            DayMath.icalDateString(decision.endDay),
            decision.publicationUID,
            decision.status.rawValue,
        ].joined(separator: "\u{1F}"))
    }

    public func submit(decision: AvailabilityDecision) throws -> WriteOutcome {
        // Only an approved decision is ever sent. Submitting a draft would ask
        // the service to hold something the owner has not agreed to.
        guard decision.status == .approved else {
            return .rejected(reason:
                "only an approved decision may be submitted; this one is "
                + decision.status.rawValue)
        }
        let key = Self.idempotencyKey(for: decision)
        let payload: [String: Any] = [
            "publicationUID": decision.publicationUID,
            "propertyID": decision.propertyID,
            "destination": decision.destination.rawValue,
            "action": decision.action.rawValue,
            "from": DayMath.icalDateString(decision.startDay),
            "to": DayMath.icalDateString(decision.endDay),
            "reason": decision.reason,
            // Stated explicitly so the service never has to infer it. This
            // submits a decision; it does not ask for publication.
            "publish": false,
        ]
        return try post("/decisions", payload: payload, idempotencyKey: key)
    }

    /// Asks the service whether a decision with this publication UID is
    /// already recorded. This is the reconciliation step: after an uncertain
    /// write, the answer decides whether a retry is safe.
    public func isRecorded(publicationUID: String) throws -> Bool {
        let escaped = publicationUID.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))
            ?? publicationUID
        let object = try get("/decisions/\(escaped)")
        return (object["found"] as? Bool) ?? false
    }

    /// Submit, and if the outcome is uncertain, find out what happened before
    /// deciding whether to try again.
    ///
    /// This is the whole point of the idempotency key. A blind retry after a
    /// timeout risks a duplicate decision; never retrying risks silently
    /// losing the owner's approval. Reconciling first avoids both.
    public func submitReconciling(
        decision: AvailabilityDecision, attempts: Int = 3
    ) throws -> WriteOutcome {
        var attempt = 0
        var lastReason = ""
        while attempt < max(1, attempts) {
            attempt += 1
            let outcome = try submit(decision: decision)
            switch outcome {
            case .applied, .alreadyApplied, .rejected:
                return outcome
            case .uncertain(let reason):
                lastReason = reason
                // Reconcile. If the write did land, report it as applied
                // rather than trying again.
                if let recorded = try? isRecorded(
                    publicationUID: decision.publicationUID), recorded {
                    return .alreadyApplied(id: decision.publicationUID)
                }
                // Not recorded, so the write genuinely did not apply and the
                // idempotency key makes another attempt safe.
                continue
            }
        }
        return .uncertain(reason:
            "after \(attempt) attempt(s) the service never confirmed, and the decision is "
            + "not recorded: \(lastReason). It has NOT been applied — nothing was published.")
    }

    // MARK: Plumbing

    private func get(_ path: String) throws -> [String: Any] {
        var request = URLRequest(url: configuration.endpoint.appendingPathComponent(path))
        request.httpMethod = "GET"
        return try perform(&request, payload: Data())
    }

    private func post(
        _ path: String, payload: [String: Any], idempotencyKey: String
    ) throws -> WriteOutcome {
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        var request = URLRequest(url: configuration.endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Signed as part of the request, so it cannot be stripped or altered
        // in transit without invalidating the signature.
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")

        do {
            // The idempotency key is brought inside the signature: it decides
            // whether a retried submission creates a second decision, so it
            // must not be strippable or alterable in transit.
            try signer.sign(&request, payload: body, alsoSign: ["Idempotency-Key"])
        } catch {
            throw CloudError.transport("could not sign the request: \(error)")
        }
        request.httpBody = body

        let response: Response
        do {
            response = try transport.send(request)
        } catch {
            // No response at all. For a write this is precisely uncertain.
            return .uncertain(reason: "no response from the service: \(error)")
        }

        let object = (try? JSONSerialization.jsonObject(with: response.body))
            as? [String: Any] ?? [:]

        switch response.statusCode {
        case 200, 201:
            let id = object["publicationUID"] as? String ?? object["id"] as? String ?? ""
            return (object["alreadyApplied"] as? Bool == true)
                ? .alreadyApplied(id: id) : .applied(id: id)
        case 409:
            return .alreadyApplied(id: object["publicationUID"] as? String ?? "")
        case 400, 422:
            return .rejected(reason: object["error"] as? String ?? "the service refused it")
        case 401, 403:
            throw CloudError.unauthorised
        default:
            // 5xx, 429, anything else: the write may or may not have applied.
            return .uncertain(reason:
                "HTTP \(response.statusCode) " + (object["error"] as? String ?? ""))
        }
    }

    private func perform(_ request: inout URLRequest, payload: Data) throws -> [String: Any] {
        do {
            try signer.sign(&request, payload: payload)
        } catch {
            throw CloudError.transport("could not sign the request: \(error)")
        }
        let response: Response
        do {
            response = try transport.send(request)
        } catch {
            throw CloudError.transport("\(error)")
        }
        switch response.statusCode {
        case 200:
            guard let object = (try? JSONSerialization.jsonObject(with: response.body))
                as? [String: Any] else {
                throw CloudError.malformed("the body was not a JSON object")
            }
            return object
        case 401, 403:
            throw CloudError.unauthorised
        default:
            let object = (try? JSONSerialization.jsonObject(with: response.body))
                as? [String: Any] ?? [:]
            throw CloudError.serviceUnavailable(
                "HTTP \(response.statusCode) " + (object["detail"] as? String ?? ""))
        }
    }
}

/// The real transport. Blocking, like the rest of the synchronous surface.
public struct URLSessionCloudTransport: CloudSyncClient.Transport {
    public let timeout: TimeInterval
    private let session: URLSession

    public init(timeout: TimeInterval = 20, session: URLSession = .shared) {
        self.timeout = timeout
        self.session = session
    }

    public func send(_ request: URLRequest) throws -> CloudSyncClient.Response {
        var request = request
        request.timeoutInterval = timeout
        let semaphore = DispatchSemaphore(value: 0)
        var captured: (Data?, URLResponse?, Error?)
        let task = session.dataTask(with: request) { data, response, error in
            captured = (data, response, error)
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw CloudSyncClient.CloudError.transport("the request timed out")
        }
        if let error = captured.2 { throw error }
        return CloudSyncClient.Response(
            statusCode: (captured.1 as? HTTPURLResponse)?.statusCode ?? 0,
            body: captured.0 ?? Data())
    }
}
