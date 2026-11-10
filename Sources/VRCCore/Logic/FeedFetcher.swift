import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct FeedResponse: Sendable {
    public var text: String
    public var httpStatus: Int?

    public init(text: String, httpStatus: Int? = nil) {
        self.text = text
        self.httpStatus = httpStatus
    }
}

public enum FeedFetchError: Error, LocalizedError {
    case invalidURL(String)
    case insecureURL(String)
    case httpError(Int)
    /// The platform rejected the credential itself. Distinct from a transient
    /// failure because retrying cannot help — the answer will not change until
    /// a new URL is supplied.
    case credentialRejected(status: Int, detail: String)
    case notText
    case transport(String)

    /// Whether this means the connection is finished rather than merely unwell.
    public var indicatesRevokedCredential: Bool {
        if case .credentialRejected = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "\"\(value)\" is not a usable calendar URL."
        case .insecureURL(let scheme):
            return "Calendar URLs must use https (got \(scheme)). A plain http feed would expose "
                + "your private calendar token to anyone on the network."
        case .httpError(let status):
            return "The platform returned HTTP \(status)."
        case .credentialRejected(let status, let detail):
            return "The platform no longer accepts this calendar URL (HTTP \(status)"
                + (detail.isEmpty ? "" : ": \(detail)") + "). It was most likely revoked when "
                + "the connection it belonged to was deleted. A new export URL is needed."
        case .notText:
            return "The response was not readable text."
        case .transport(let message):
            return message
        }
    }
}

/// Fetches a feed. Abstracted so the tests can run entirely offline.
public protocol FeedFetching: Sendable {
    func fetch(urlString: String) async throws -> FeedResponse
}

public struct URLSessionFeedFetcher: FeedFetching {
    private let session: URLSession
    public let allowFileURLs: Bool

    public init(session: URLSession = .shared, allowFileURLs: Bool = false) {
        self.session = session
        self.allowFileURLs = allowFileURLs
    }

    public func fetch(urlString: String) async throws -> FeedResponse {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw FeedFetchError.invalidURL(trimmed)
        }

        if scheme == "file" {
            guard allowFileURLs else { throw FeedFetchError.insecureURL(scheme) }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                throw FeedFetchError.notText
            }
            return FeedResponse(text: text, httpStatus: 200)
        }

        // webcal:// is what the platforms' "copy link" buttons often produce.
        var resolved = url
        if scheme == "webcal" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            guard let upgraded = components?.url else { throw FeedFetchError.invalidURL(trimmed) }
            resolved = upgraded
        } else if scheme != "https" {
            throw FeedFetchError.insecureURL(scheme)
        }

        var request = URLRequest(url: resolved)
        request.httpMethod = "GET"
        request.timeoutInterval = 45
        request.setValue(
            "VacationRentalCalendar/1.0 (read-only calendar import)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/calendar, text/plain, */*", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            if let status, !(200...299).contains(status) {
                let body = String(data: data.prefix(512), encoding: .utf8) ?? ""
                if Self.indicatesRevocation(status: status, body: body) {
                    throw FeedFetchError.credentialRejected(
                        status: status, detail: Self.summarise(body)
                    )
                }
                throw FeedFetchError.httpError(status)
            }
            guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
                throw FeedFetchError.notText
            }
            return FeedResponse(text: text, httpStatus: status)
        } catch let error as FeedFetchError {
            throw error
        } catch {
            throw FeedFetchError.transport(error.localizedDescription)
        }
    }
}

public extension URLSessionFeedFetcher {
    /// Decides whether a non-success response means the credential is dead.
    ///
    /// 401, 403 and 410 are unambiguous. 400 and 404 are judged on the body,
    /// because those codes cover both "this token is not valid" — which is
    /// final — and ordinary server-side trouble, which is not. Booking.com,
    /// for instance, answers a deleted token with
    /// `400 {"detail":"Invalid Token"}`.
    static func indicatesRevocation(status: Int, body: String) -> Bool {
        if [401, 403, 410].contains(status) { return true }
        guard [400, 404].contains(status) else { return false }
        let haystack = body.lowercased()
        let markers = [
            "invalid token", "token not found", "unknown token", "expired",
            "not found", "no longer", "revoked", "unauthorized", "forbidden",
            "invalid key", "invalid calendar",
        ]
        return markers.contains { haystack.contains($0) }
    }

    /// Pulls a short human-readable reason out of a JSON or text error body.
    static func summarise(_ body: String) -> String {
        guard !body.isEmpty else { return "" }
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["detail", "message", "error", "title"] {
                if let value = object[key] as? String, !value.isEmpty { return value }
            }
        }
        return String(body.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Serves canned feeds. Used by the tests and by the sample data loader.
public struct StubFeedFetcher: FeedFetching {
    public var responses: [String: Result<FeedResponse, FeedFetchError>]

    public init(responses: [String: Result<FeedResponse, FeedFetchError>]) {
        self.responses = responses
    }

    public init(texts: [String: String]) {
        self.responses = texts.mapValues { .success(FeedResponse(text: $0, httpStatus: 200)) }
    }

    public func fetch(urlString: String) async throws -> FeedResponse {
        guard let response = responses[urlString] else {
            throw FeedFetchError.invalidURL(urlString)
        }
        return try response.get()
    }
}
