import Foundation

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
    case notText
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "\"\(value)\" is not a usable calendar URL."
        case .insecureURL(let scheme):
            return "Calendar URLs must use https (got \(scheme)). A plain http feed would expose "
                + "your private calendar token to anyone on the network."
        case .httpError(let status):
            return "The platform returned HTTP \(status)."
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
