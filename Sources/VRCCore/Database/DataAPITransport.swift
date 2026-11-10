import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The real transport: a SigV4-signed POST to the regional Data API endpoint.
///
/// Reuses `SigV4Signer`, which already signs the S3 and R2 clients. The only
/// differences are the service name and the endpoint, both parameters.
public struct URLSessionDataAPITransport: DataAPITransport {
    public let region: String
    public let signer: SigV4Signer
    public let timeout: TimeInterval
    private let session: URLSession

    public init(
        region: String,
        accessKeyID: String,
        secretAccessKey: String,
        sessionToken: String? = nil,
        timeout: TimeInterval = 30,
        session: URLSession = .shared
    ) {
        self.region = region
        self.signer = SigV4Signer(
            accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
            region: region, service: "rds-data")
        self.timeout = timeout
        self.session = session
        self.sessionToken = sessionToken
    }

    private let sessionToken: String?

    /// Lambda supplies short-lived role credentials through the environment,
    /// which is why the session token is carried: a long-lived access key is
    /// never needed server-side.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URLSessionDataAPITransport {
        guard let key = environment["AWS_ACCESS_KEY_ID"],
              let secret = environment["AWS_SECRET_ACCESS_KEY"] else {
            throw DataAPIError.notConfigured("AWS credentials are not in the environment")
        }
        let region = environment["AWS_REGION"] ?? environment["AWS_DEFAULT_REGION"] ?? "us-east-1"
        return URLSessionDataAPITransport(
            region: region, accessKeyID: key, secretAccessKey: secret,
            sessionToken: environment["AWS_SESSION_TOKEN"])
    }

    public func send(_ call: DataAPICall) throws -> DataAPIResult {
        guard let url = URL(string: "https://rds-data.\(region).amazonaws.com/\(call.action.rawValue)")
        else { throw DataAPIError.notConfigured("endpoint for region \(region)") }

        let payload = try JSONSerialization.data(
            withJSONObject: call.body, options: [.sortedKeys])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        request.httpBody = payload
        try signer.sign(&request, payload: payload)

        // Blocking by design — see the note on DataStore. The handler owns its
        // thread, so there is no executor to starve.
        let semaphore = DispatchSemaphore(value: 0)
        var captured: (Data?, URLResponse?, Error?)
        let task = session.dataTask(with: request) { data, response, error in
            captured = (data, response, error)
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw DataAPIError.indeterminate(
                "the Data API did not respond within \(Int(timeout))s")
        }

        if let error = captured.2 { throw error }
        let status = (captured.1 as? HTTPURLResponse)?.statusCode ?? 0
        let object = captured.0.flatMap {
            try? JSONSerialization.jsonObject(with: $0)
        } as? [String: Any]
        return DataAPIResult(statusCode: status, payload: object ?? [:])
    }
}

/// Records calls and replays scripted responses. Everything about the store's
/// behaviour that matters — parameterisation, retries, fail-closed — is
/// testable through this without an AWS account.
public final class RecordingDataAPITransport: DataAPITransport, @unchecked Sendable {
    public struct Scripted: Sendable {
        public var statusCode: Int
        public var payload: [String: Any]
        public init(statusCode: Int = 200, payload: [String: Any] = [:]) {
            self.statusCode = statusCode
            self.payload = payload
        }
    }

    private let lock = NSLock()
    private var scripted: [Scripted]
    private var recorded: [DataAPICall] = []
    private var thrown: Error?

    public init(responses: [Scripted] = []) { self.scripted = responses }

    public func enqueue(_ response: Scripted) {
        lock.lock(); scripted.append(response); lock.unlock()
    }

    public func throwOnNext(_ error: Error) {
        lock.lock(); thrown = error; lock.unlock()
    }

    public var calls: [DataAPICall] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    public var executedSQL: [String] {
        calls.compactMap { $0.body["sql"] as? String }
    }

    public func send(_ call: DataAPICall) throws -> DataAPIResult {
        lock.lock()
        recorded.append(call)
        if let error = thrown { thrown = nil; lock.unlock(); throw error }
        let next = scripted.isEmpty
            ? Scripted(statusCode: 200, payload: ["numberOfRecordsUpdated": 0])
            : scripted.removeFirst()
        lock.unlock()
        return DataAPIResult(statusCode: next.statusCode, payload: next.payload)
    }
}
