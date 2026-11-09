import Foundation
import VRCCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The small slice of S3 the handlers need. A protocol so the handler tests
/// run with no network and no account.
public protocol ObjectStore: Sendable {
    func get(key: String) throws -> Data
    func put(key: String, body: Data, contentType: String) throws
    func putIfAbsent(key: String, body: Data, contentType: String) throws -> Bool
}

public protocol FunctionInvoker: Sendable {
    func invoke(function: String, payload: Data) throws
}

public protocol CacheInvalidator: Sendable {
    func invalidate(paths: [String]) throws
}

public protocol SecretReader: Sendable {
    func secret(id: String) throws -> [String: String]
}

// MARK: - Real implementations

public struct S3ObjectStore: ObjectStore {
    let bucket: String
    let region: String
    let signer: SigV4Signer
    let sessionToken: String?

    public init(bucket: String, region: String, accessKeyID: String,
                secretAccessKey: String, sessionToken: String?) {
        self.bucket = bucket
        self.region = region
        self.sessionToken = sessionToken
        self.signer = SigV4Signer(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
                                  region: region, service: "s3")
    }

    private func url(_ key: String) throws -> URL {
        let escaped = key.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(
                CharacterSet(charactersIn: "-._~"))) ?? String($0)
        }.joined(separator: "/")
        guard let url = URL(string: "https://\(bucket).s3.\(region).amazonaws.com/\(escaped)")
        else { throw LambdaRuntime.HandlerError(message: "bad object key \(key)") }
        return url
    }

    public func get(key: String) throws -> Data {
        var request = URLRequest(url: try url(key))
        request.httpMethod = "GET"
        if let sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        try signer.sign(&request, payload: Data())
        let (data, status) = try perform(request)
        guard status == 200 else {
            throw LambdaRuntime.HandlerError(
                type: "S3", message: "GET \(key) returned \(status)")
        }
        return data
    }

    public func put(key: String, body: Data, contentType: String) throws {
        var request = URLRequest(url: try url(key))
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        // Short, revalidated cache. A stale feed is harmless when it is
        // missing a block and dangerous when it is missing a reopening.
        request.setValue("public, max-age=60, must-revalidate",
                         forHTTPHeaderField: "Cache-Control")
        if let sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        request.httpBody = body
        try signer.sign(&request, payload: body)
        let (_, status) = try perform(request)
        guard (200...299).contains(status) else {
            throw LambdaRuntime.HandlerError(
                type: "S3", message: "PUT \(key) returned \(status)")
        }
    }

    /// Used for the publication receipt, so two publishers cannot both claim
    /// to have produced the same revision.
    public func putIfAbsent(key: String, body: Data, contentType: String) throws -> Bool {
        var request = URLRequest(url: try url(key))
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("*", forHTTPHeaderField: "If-None-Match")
        if let sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        request.httpBody = body
        try signer.sign(&request, payload: body)
        let (_, status) = try perform(request)
        if status == 412 { return false }
        guard (200...299).contains(status) else {
            throw LambdaRuntime.HandlerError(
                type: "S3", message: "conditional PUT \(key) returned \(status)")
        }
        return true
    }

    private func perform(_ request: URLRequest) throws -> (Data, Int) {
        let semaphore = DispatchSemaphore(value: 0)
        var captured: (Data?, URLResponse?, Error?)
        URLSession.shared.dataTask(with: request) { data, response, error in
            captured = (data, response, error)
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 40) != .timedOut else {
            throw LambdaRuntime.HandlerError(type: "S3", message: "request timed out")
        }
        if let error = captured.2 { throw error }
        return (captured.0 ?? Data(), (captured.1 as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public struct LambdaFunctionInvoker: FunctionInvoker {
    let region: String
    let signer: SigV4Signer
    let sessionToken: String?

    public init(region: String, accessKeyID: String, secretAccessKey: String,
                sessionToken: String?) {
        self.region = region
        self.sessionToken = sessionToken
        self.signer = SigV4Signer(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
                                  region: region, service: "lambda")
    }

    public func invoke(function: String, payload: Data) throws {
        guard let url = URL(string:
            "https://lambda.\(region).amazonaws.com/2015-03-31/functions/\(function)/invocations")
        else { throw LambdaRuntime.HandlerError(message: "bad function name") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Event, not RequestResponse: the fetcher must not wait for the
        // processor, and must not fail because the processor was slow.
        request.setValue("Event", forHTTPHeaderField: "X-Amz-Invocation-Type")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        request.httpBody = payload
        try signer.sign(&request, payload: payload)

        let semaphore = DispatchSemaphore(value: 0)
        var status = 0
        var failure: Error?
        URLSession.shared.dataTask(with: request) { _, response, error in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            failure = error
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        if let failure { throw failure }
        guard (200...299).contains(status) else {
            throw LambdaRuntime.HandlerError(
                type: "Lambda", message: "invoking \(function) returned \(status)")
        }
    }
}

public struct CloudFrontInvalidator: CacheInvalidator {
    let distributionID: String
    let signer: SigV4Signer
    let sessionToken: String?

    public init(distributionID: String, accessKeyID: String, secretAccessKey: String,
                sessionToken: String?) {
        self.distributionID = distributionID
        self.sessionToken = sessionToken
        // CloudFront is a global service and signs against us-east-1.
        self.signer = SigV4Signer(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
                                  region: "us-east-1", service: "cloudfront")
    }

    public func invalidate(paths: [String]) throws {
        guard let url = URL(string:
            "https://cloudfront.amazonaws.com/2020-05-31/distribution/\(distributionID)/invalidation")
        else { throw LambdaRuntime.HandlerError(message: "bad distribution id") }

        let reference = "vrc-\(Int(Date().timeIntervalSince1970))"
        let quantity = paths.count
        let items = paths.map { "<Path>\($0)</Path>" }.joined()
        let body = Data((
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<InvalidationBatch xmlns=\"http://cloudfront.amazonaws.com/doc/2020-05-31/\">"
            + "<Paths><Quantity>\(quantity)</Quantity><Items>\(items)</Items></Paths>"
            + "<CallerReference>\(reference)</CallerReference>"
            + "</InvalidationBatch>").utf8)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
        if let sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        request.httpBody = body
        try signer.sign(&request, payload: body)

        let semaphore = DispatchSemaphore(value: 0)
        var status = 0
        var failure: Error?
        URLSession.shared.dataTask(with: request) { _, response, error in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            failure = error
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        if let failure { throw failure }
        guard (200...299).contains(status) else {
            throw LambdaRuntime.HandlerError(
                type: "CloudFront",
                message: "invalidation returned \(status) — the feed at the origin is new but "
                    + "readers may still be served the old one")
        }
    }
}

public struct SecretsManagerReader: SecretReader {
    let region: String
    let signer: SigV4Signer
    let sessionToken: String?

    public init(region: String, accessKeyID: String, secretAccessKey: String,
                sessionToken: String?) {
        self.region = region
        self.sessionToken = sessionToken
        self.signer = SigV4Signer(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
                                  region: region, service: "secretsmanager")
    }

    public func secret(id: String) throws -> [String: String] {
        guard let url = URL(string: "https://secretsmanager.\(region).amazonaws.com/")
        else { throw LambdaRuntime.HandlerError(message: "bad region") }
        let payload = LambdaJSON.data(["SecretId": id])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("secretsmanager.GetSecretValue", forHTTPHeaderField: "X-Amz-Target")
        if let sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        request.httpBody = payload
        try signer.sign(&request, payload: payload)

        let semaphore = DispatchSemaphore(value: 0)
        var captured: (Data?, URLResponse?, Error?)
        URLSession.shared.dataTask(with: request) { data, response, error in
            captured = (data, response, error)
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 20) != .timedOut else {
            throw LambdaRuntime.HandlerError(type: "SecretsManager", message: "timed out")
        }
        if let error = captured.2 { throw error }
        let status = (captured.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let data = captured.0 else {
            // Deliberately does not echo the response body: an error from
            // Secrets Manager can quote the secret id, and a log is the wrong
            // place for it.
            throw LambdaRuntime.HandlerError(
                type: "SecretsManager", message: "GetSecretValue returned \(status)")
        }
        let envelope = LambdaJSON.object(data)
        guard let secretString = envelope["SecretString"] as? String,
              let inner = try? JSONSerialization.jsonObject(with: Data(secretString.utf8)),
              let map = inner as? [String: Any] else {
            throw LambdaRuntime.HandlerError(
                type: "SecretsManager", message: "the secret is not a JSON object")
        }
        return map.compactMapValues { $0 as? String }
    }
}
