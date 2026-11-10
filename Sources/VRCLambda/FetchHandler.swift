import Foundation
import VRCCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads each source calendar and decides whether anything actually
/// changed — without touching the database.
///
/// That is the entire point. Waking Aurora costs a five-minute minimum pause
/// delay, so a poll that finds no news must not wake it. The comparison is a
/// semantic hash of the normalised event set, held in S3 beside the raw
/// payload, so `DTSTAMP` regenerating on every request does not read as a
/// change.
///
/// This handler parses untrusted third-party content, so it is the one that
/// holds no database credential and no outbound feed token. It cannot write to
/// the system of record and it cannot publish.
public struct FetchHandler {
    let context: ServiceContext
    let fetcher: FeedFetching
    let objects: ObjectStore
    let invoker: FunctionInvoker

    public init(
        context: ServiceContext,
        fetcher: FeedFetching,
        objects: ObjectStore,
        invoker: FunctionInvoker
    ) {
        self.context = context
        self.fetcher = fetcher
        self.objects = objects
        self.invoker = invoker
    }

    public struct Source: Sendable {
        public var name: String
        public var url: String
        public init(name: String, url: String) {
            self.name = name
            self.url = url
        }
    }

    public struct Outcome: Sendable {
        public var checked = 0
        public var changed: [String] = []
        public var unchanged: [String] = []
        public var failed: [String: String] = [:]
        public var notModified: [String] = []
    }

    public func run(sources: [Source], now: Date = Date()) throws -> Outcome {
        try context.requireNoDatabase()
        var outcome = Outcome()

        for source in sources {
            outcome.checked += 1
            let hashKey = "hashes/\(source.name).sha256"
            let previousHash = (try? objects.get(key: hashKey))
                .flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let response: FeedResponse
            do {
                response = try blocking { try await fetcher.fetch(urlString: source.url) }
            } catch {
                // A failed fetch records nothing and withdraws nothing. The
                // database guards would refuse a mass withdrawal anyway, but
                // the cheapest place to not do it is here.
                outcome.failed[source.name] =
                    (error as? LocalizedError)?.errorDescription ?? "\(error)"
                continue
            }

            if response.httpStatus == 304 {
                outcome.notModified.append(source.name)
                continue
            }

            let parsed: ICalParseResult
            do {
                parsed = try ICalParser.parse(response.text)
            } catch {
                outcome.failed[source.name] =
                    (error as? LocalizedError)?.errorDescription ?? "\(error)"
                continue
            }

            let hash = SemanticFeedHash.hash(parsed.events)
            if hash == previousHash {
                outcome.unchanged.append(source.name)
                continue
            }

            // Something genuinely changed. Persist the payload for forensics,
            // record the new hash, and only now wake the processor.
            let payloadKey = "payloads/\(source.name)/\(Int(now.timeIntervalSince1970)).ics"
            try objects.put(key: payloadKey, body: Data(response.text.utf8),
                            contentType: "text/calendar")
            try objects.put(key: hashKey, body: Data(hash.utf8), contentType: "text/plain")
            outcome.changed.append(source.name)

            try invoker.invoke(function: try context.value("VRC_PROCESS_FUNCTION"),
                               payload: LambdaJSON.data([
                                   "source": source.name,
                                   "payloadKey": payloadKey,
                                   "eventCount": parsed.events.count,
                               ]))
        }
        return outcome
    }
}

/// Bridges one async call into the synchronous handler. Safe here because the
/// runtime loop gives each invocation its own thread.
func blocking<T>(_ work: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?
    Task {
        do { result = .success(try await work()) }
        catch { result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    switch result! {
    case .success(let value): return value
    case .failure(let error): throw error
    }
}
