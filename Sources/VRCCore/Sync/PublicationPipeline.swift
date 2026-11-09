import Foundation

/// How far a publication has actually got.
///
/// Kept deliberately separate from `AvailabilityStatus`, and deliberately
/// granular, because each step can succeed while the next fails — and because
/// the only one that says anything about the destination platform is the last.
public enum PublicationStage: String, CaseIterable, Sendable {
    /// Built on this Mac. Nothing has left it.
    case generated
    /// Entries would be added and the owner has not approved them.
    case awaitingAdditionApproval = "awaiting_addition_approval"
    /// Removals are present and the owner has not approved them.
    case awaitingRemovalApproval = "awaiting_removal_approval"
    /// The bytes are on the hosting endpoint.
    case uploaded
    /// The CDN has been purged, so the new bytes are what gets served.
    case cacheInvalidated = "cache_invalidated"
    /// Live and correct, now waiting on the platform's own polling.
    case platformRefreshPending = "platform_refresh_pending"
    /// The destination's own calendar confirms the nights.
    case verified
    case failed
    /// Rolled back to the last known good feed.
    case rolledBack = "rolled_back"

    /// **Only** `verified` means the destination platform reflects the change.
    /// A successful upload or cache purge says nothing about the platform.
    public var impliesRemoteSynchronised: Bool { self == .verified }

    public var displayName: String {
        switch self {
        case .generated: return "Generated locally"
        case .awaitingAdditionApproval: return "Awaiting your approval to block dates"
        case .awaitingRemovalApproval: return "Awaiting your approval to remove dates"
        case .uploaded: return "Uploaded — not yet live"
        case .cacheInvalidated: return "Live — awaiting platform refresh"
        case .platformRefreshPending: return "Published — awaiting platform confirmation"
        case .verified: return "Confirmed on the platform"
        case .failed: return "Failed"
        case .rolledBack: return "Rolled back to the last good feed"
        }
    }

    public var explanation: String {
        switch self {
        case .generated:
            return "Built on this Mac for you to inspect. Nothing has been sent anywhere."
        case .awaitingAdditionApproval:
            return "This would take nights off sale on the destination, so it waits for you. "
                + "Nothing has been sent anywhere."
        case .awaitingRemovalApproval:
            return "This would put previously blocked nights back on sale, so it waits for you."
        case .uploaded:
            return "The file is on the server, but the CDN may still be serving the old copy, "
                + "so platforms could still read stale availability."
        case .cacheInvalidated:
            return "The new feed is what the server now returns. Platforms have not necessarily "
                + "read it yet."
        case .platformRefreshPending:
            return "Published and live. Platforms re-read calendars on their own schedule. "
                + "A successful upload is not proof any of them imported it."
        case .verified:
            return "The destination's own calendar now shows these nights as unavailable."
        case .failed:
            return "A step failed. The previous feed is still what is being served."
        case .rolledBack:
            return "Restored to the last feed known to be good."
        }
    }
}

/// Where the bytes would go. No implementation ships in this build.
public protocol FeedHostingClient: Sendable {
    func upload(key: String, body: String, cacheControl: String) async throws
    func invalidateCache(key: String) async throws
}

public enum HostingError: Error, LocalizedError {
    case uploadFailed(String)
    case cacheInvalidationFailed(String)
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .uploadFailed(let detail): return "Upload failed: \(detail)"
        case .cacheInvalidationFailed(let detail):
            return "The CDN cache was not purged: \(detail). Platforms may still be served the "
                + "previous feed, so this publication is not complete."
        case .notConfigured:
            return "No hosting is configured. Phase D would add it."
        }
    }
}

/// Test double, and the only implementation that exists.
public actor StubHostingClient: FeedHostingClient {
    public var failUpload: String?
    public var failInvalidation: String?
    public private(set) var uploaded: [String: String] = [:]
    public private(set) var invalidatedKeys: [String] = []

    public init(failUpload: String? = nil, failInvalidation: String? = nil) {
        self.failUpload = failUpload
        self.failInvalidation = failInvalidation
    }

    public func setFailUpload(_ value: String?) { failUpload = value }
    public func setFailInvalidation(_ value: String?) { failInvalidation = value }

    public func upload(key: String, body: String, cacheControl: String) async throws {
        if let failUpload { throw HostingError.uploadFailed(failUpload) }
        uploaded[key] = body
    }

    public func invalidateCache(key: String) async throws {
        if let failInvalidation {
            throw HostingError.cacheInvalidationFailed(failInvalidation)
        }
        invalidatedKeys.append(key)
    }

    public func uploadedBody(forKey key: String) -> String? { uploaded[key] }
    public func wasInvalidated(_ key: String) -> Bool { invalidatedKeys.contains(key) }
}

/// Guards the rehearsal against ever running on the real database.
///
/// The isolation used to rest on remembering to pass a sandbox path. That is
/// not a guarantee, and an earlier rehearsal did write publication rows into
/// the production database — rows describing publications that never happened,
/// which would have corrupted the next genuine publish, because the safety
/// diff compares against the last known good feed. This makes the mistake
/// impossible to repeat silently.
public enum RehearsalIsolation {
    public enum Violation: Error, LocalizedError {
        case wouldUseProductionDatabase(String)

        public var errorDescription: String? {
            switch self {
            case .wouldUseProductionDatabase(let path):
                return "Refusing to rehearse against the production database at \(path). "
                    + "A rehearsal writes publication rows and snapshots describing "
                    + "publications that never happened; leaving those in the real database "
                    + "would corrupt the next genuine publish."
            }
        }
    }

    /// Throws unless `path` is demonstrably not the production database.
    public static func assertIsolated(
        databasePath: String,
        productionPath: String = AppPaths.databaseURL.path
    ) throws {
        let candidate = URL(fileURLWithPath: databasePath).standardizedFileURL.path
        let production = URL(fileURLWithPath: productionPath).standardizedFileURL.path
        guard candidate != production else {
            throw Violation.wouldUseProductionDatabase(candidate)
        }
        // Also refuse anything inside the application support directory, so a
        // sibling file there cannot be mistaken for a sandbox.
        let supportDirectory = AppPaths.supportDirectory.standardizedFileURL.path
        guard !candidate.hasPrefix(supportDirectory + "/") else {
            throw Violation.wouldUseProductionDatabase(candidate)
        }
    }
}

/// The outcome of attempting one destination's publication.
public struct PublicationAttempt: Sendable, Identifiable {
    public var destination: RentalPlatform
    public var stage: PublicationStage
    public var safety: PublicationSafetyReport
    public var detail: String
    public var rolledBackTo: Int?

    public var id: String { destination.rawValue }
    public var succeeded: Bool {
        stage == .platformRefreshPending || stage == .cacheInvalidated
    }
    /// Never true from a publication alone — verification is a separate act.
    public var isRemoteSynchronised: Bool { stage.impliesRemoteSynchronised }
}

/// Runs a publication through its stages, stopping at the first failure and
/// leaving the previous feed in place.
///
/// Every stage boundary is a place the pipeline can stop without lying about
/// what happened. In particular, a failed cache invalidation leaves the stage
/// at `uploaded` rather than advancing — because the server has new bytes that
/// nobody is being served, which is a different and more dangerous state than
/// either success or outright failure.
public struct PublicationPipeline: Sendable {
    let hosting: FeedHostingClient?
    let safety: FeedPublicationSafety
    let generator: CalendarFeedGenerator

    public init(
        hosting: FeedHostingClient?,
        safety: FeedPublicationSafety = FeedPublicationSafety(),
        generator: CalendarFeedGenerator = CalendarFeedGenerator()
    ) {
        self.hosting = hosting
        self.safety = safety
        self.generator = generator
    }

    /// - Parameter changeApproved: the owner's explicit consent to serve this
    ///   feed. Required for **any** change — additions take nights off sale on
    ///   the destination, removals put them back on. Never implied.
    public func publish(
        feed: DestinationFeed,
        lastKnownGood: FeedSnapshot?,
        context: PublicationContext,
        key: String,
        changeApproved: Bool = false,
        now: Date = Date()
    ) async -> PublicationAttempt {
        let report = safety.assess(
            proposed: feed, lastKnownGood: lastKnownGood, context: context
        )

        switch report.verdict {
        case .refused:
            return PublicationAttempt(
                destination: feed.destination, stage: .failed, safety: report,
                detail: report.headline,
                rolledBackTo: lastKnownGood?.revision
            )
        case .requiresRemovalApproval where !changeApproved:
            return PublicationAttempt(
                destination: feed.destination, stage: .awaitingRemovalApproval,
                safety: report, detail: report.headline
            )
        case .requiresAdditionApproval where !changeApproved:
            return PublicationAttempt(
                destination: feed.destination, stage: .awaitingAdditionApproval,
                safety: report, detail: report.headline
            )
        default:
            break
        }

        guard let hosting else {
            return PublicationAttempt(
                destination: feed.destination, stage: .failed, safety: report,
                detail: HostingError.notConfigured.localizedDescription
            )
        }

        let body = generator.makeICS(feed)
        do {
            try await hosting.upload(
                key: key, body: body, cacheControl: "public, max-age=60, must-revalidate"
            )
        } catch {
            return PublicationAttempt(
                destination: feed.destination, stage: .failed, safety: report,
                detail: (error as? LocalizedError)?.errorDescription ?? "\(error)",
                rolledBackTo: lastKnownGood?.revision
            )
        }

        do {
            try await hosting.invalidateCache(key: key)
        } catch {
            // Uploaded but not live. Reported as its own stage rather than as
            // success or failure, because both would be wrong.
            return PublicationAttempt(
                destination: feed.destination, stage: .uploaded, safety: report,
                detail: (error as? LocalizedError)?.errorDescription
                    ?? "The cache was not purged, so the previous feed may still be served."
            )
        }

        return PublicationAttempt(
            destination: feed.destination, stage: .platformRefreshPending, safety: report,
            detail: "Live. " + PlatformAdapters.capability(for: feed.destination).latencyNote
        )
    }

    /// Publishes several destinations, reporting each independently.
    ///
    /// One platform failing never rolls back another: a partial publication is
    /// reported as partial rather than being hidden behind a single verdict.
    public func publishAll(
        feeds: [DestinationFeed],
        snapshots: [RentalPlatform: FeedSnapshot],
        context: PublicationContext,
        keys: [RentalPlatform: String],
        changeApproved: Set<RentalPlatform> = [],
        now: Date = Date()
    ) async -> [PublicationAttempt] {
        var attempts: [PublicationAttempt] = []
        for feed in feeds {
            attempts.append(await publish(
                feed: feed,
                lastKnownGood: snapshots[feed.destination],
                context: context,
                key: keys[feed.destination] ?? "missing-key",
                changeApproved: changeApproved.contains(feed.destination),
                now: now
            ))
        }
        return attempts
    }
}
