import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The AWS Lambda runtime loop, written against the documented HTTP API.
///
/// Hand-rolled rather than taking a dependency. The protocol is four
/// endpoints, the handlers here are small, and every dependency added to this
/// package has to cross-compile to a static Linux binary — which is how these
/// are shipped, with no Docker and no Xcode.
public enum LambdaRuntime {

    public struct Invocation: Sendable {
        public var requestID: String
        public var deadline: Date?
        public var traceID: String?
        public var payload: Data
    }

    public struct HandlerError: Error, Sendable {
        public var type: String
        public var message: String
        public init(type: String = "HandlerError", message: String) {
            self.type = type
            self.message = message
        }
    }

    /// Runs until the execution environment is torn down.
    ///
    /// A thrown error is reported to Lambda as an invocation error and the loop
    /// continues: one bad payload must not take the function out of service.
    /// A failure to reach the runtime API itself is fatal, because there is
    /// then nothing to report to.
    public static func run(
        _ handle: @escaping (Invocation) throws -> Data
    ) -> Never {
        guard let endpoint = ProcessInfo.processInfo.environment["AWS_LAMBDA_RUNTIME_API"],
              !endpoint.isEmpty else {
            FileHandle.standardError.write(Data(
                "AWS_LAMBDA_RUNTIME_API is not set — this binary only runs inside Lambda.\n".utf8))
            exit(1)
        }

        let base = "http://\(endpoint)/2018-06-01/runtime"
        let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.default
            // The next-invocation request long-polls, so it must not time out.
            configuration.timeoutIntervalForRequest = 900
            return configuration
        }())

        while true {
            guard let invocation = nextInvocation(base: base, session: session) else {
                // Could not reach the runtime API. Sleeping briefly avoids a
                // hot loop while the environment shuts down.
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            do {
                let result = try handle(invocation)
                post("\(base)/invocation/\(invocation.requestID)/response",
                     body: result, session: session)
            } catch {
                let described: HandlerError = (error as? HandlerError)
                    ?? HandlerError(type: String(describing: type(of: error)),
                                    message: (error as? LocalizedError)?.errorDescription
                                        ?? "\(error)")
                let body = (try? JSONSerialization.data(withJSONObject: [
                    "errorType": described.type,
                    "errorMessage": described.message,
                ])) ?? Data("{\"errorType\":\"Unknown\"}".utf8)
                post("\(base)/invocation/\(invocation.requestID)/error",
                     body: body, session: session)
            }
        }
    }

    private static func nextInvocation(base: String, session: URLSession) -> Invocation? {
        guard let url = URL(string: "\(base)/invocation/next") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let semaphore = DispatchSemaphore(value: 0)
        var captured: (Data?, URLResponse?, Error?)
        session.dataTask(with: request) { data, response, error in
            captured = (data, response, error)
            semaphore.signal()
        }.resume()
        semaphore.wait()

        guard captured.2 == nil, let http = captured.1 as? HTTPURLResponse,
              let requestID = http.value(forHTTPHeaderField: "Lambda-Runtime-Aws-Request-Id")
        else { return nil }

        var deadline: Date?
        if let raw = http.value(forHTTPHeaderField: "Lambda-Runtime-Deadline-Ms"),
           let milliseconds = Double(raw) {
            deadline = Date(timeIntervalSince1970: milliseconds / 1000)
        }
        return Invocation(
            requestID: requestID,
            deadline: deadline,
            traceID: http.value(forHTTPHeaderField: "Lambda-Runtime-Trace-Id"),
            payload: captured.0 ?? Data())
    }

    private static func post(_ urlString: String, body: Data, session: URLSession) {
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { _, _, _ in semaphore.signal() }.resume()
        _ = semaphore.wait(timeout: .now() + 30)
    }
}

/// Small helpers shared by the handlers, so none of them hand-rolls JSON.
public enum LambdaJSON {
    public static func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    public static func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
    }

    /// An API Gateway HTTP API v2 proxy response.
    public static func httpResponse(
        _ status: Int, _ body: [String: Any], headers: [String: String] = [:]
    ) -> Data {
        var merged = ["content-type": "application/json"]
        for (key, value) in headers { merged[key] = value }
        return data([
            "statusCode": status,
            "headers": merged,
            "body": String(data: data(body), encoding: .utf8) ?? "{}",
            "isBase64Encoded": false,
        ])
    }
}
