import Foundation

/// Which feeds are refreshing, and which are waiting their turn.
///
/// This exists because of a silent failure on 2026-11-10. The app held ONE
/// app-wide `isRefreshing` flag and the per-feed Refresh button was disabled
/// whenever it was set. A feed's import takes as long as its Keychain read and
/// its HTTP fetch — ten seconds for Airbnb that day, twenty when a Keychain
/// read hits its deadline — and for the whole of that window every other
/// feed's Refresh button was dead. Clicking it did nothing, recorded nothing,
/// and said nothing: `ImportService` was never entered, so not even a failed
/// `sync_run` was written to show the attempt.
///
/// Two rules follow, and they are the whole of this type:
///
/// 1. **One feed refreshing never disables another.** `isBusy` is asked about
///    a specific listing, so only that row's button goes quiet.
/// 2. **A request is never dropped.** Imports still run one at a time — the
///    Keychain is the shared resource, and an abandoned read poisons the
///    process for every later call — so a request that cannot start now is
///    queued and run in turn. Silently discarding it is what hid the fault.
///
/// Deliberately a plain value type with no concurrency of its own: the app
/// owns it on the main actor, which is also what lets SwiftUI observe it. It
/// holds no URL, no credential and no platform detail — only listing ids.
public struct FeedRefreshQueue: Sendable, Equatable {

    /// What the caller should do with a request it just made.
    public enum Outcome: Sendable, Equatable {
        /// Nothing was running; start importing this feed now.
        case startNow
        /// Another feed is importing; this one will run when it finishes.
        case queued
        /// This feed is already running or already waiting. Do nothing — an
        /// impatient second click must not import the same feed twice.
        case alreadyPending

        /// What to tell the owner. Every outcome has one: a click that
        /// produces no visible answer is indistinguishable from the dead
        /// button this type replaced, even when coalescing it was correct.
        public var ownerMessage: String {
            switch self {
            case .startNow: return "Refreshing now…"
            case .queued: return "Waiting for the current refresh to finish."
            case .alreadyPending: return "Already refreshing — nothing to repeat."
            }
        }
    }

    /// What one feed's row should show.
    public enum FeedState: Sendable, Equatable {
        /// Not refreshing. The button is live.
        case idle
        /// Importing right now.
        case refreshing
        /// Waiting for another feed to finish.
        case queued

        /// The three must read differently. The old button said "Refresh"
        /// while disabled, so a working feed, a waiting feed and an ignored
        /// click all looked the same.
        public var buttonLabel: String {
            switch self {
            case .idle: return "Refresh"
            case .refreshing: return "Refreshing…"
            case .queued: return "Queued"
            }
        }

        /// Whether the row shows a progress indicator. A queued feed shows one
        /// too: it is pending, not finished.
        public var showsProgress: Bool { self != .idle }

        /// Whether the row's button accepts a click.
        public var acceptsClick: Bool { self == .idle }
    }

    private var running: Int64?
    private var waiting: [Int64] = []
    /// A "Refresh all" pass. It imports every feed in turn, so it occupies the
    /// queue as a whole rather than appearing as any one listing.
    private var bulkRunning = false

    public init() {}

    /// True while this feed is importing or waiting to. The only thing a view
    /// should disable a row's Refresh button on.
    public func isBusy(listingID: Int64) -> Bool {
        running == listingID || waiting.contains(listingID)
    }

    /// What this feed's row should show.
    public func state(of listingID: Int64) -> FeedState {
        if running == listingID { return .refreshing }
        if waiting.contains(listingID) { return .queued }
        return .idle
    }

    /// True while any feed is importing or waiting. For the global progress
    /// indicator — never for disabling a per-feed button.
    public var hasWorkInFlight: Bool {
        running != nil || bulkRunning || !waiting.isEmpty
    }

    /// True while a "Refresh all" pass is running.
    public var isBulkRunning: Bool { bulkRunning }

    /// The feed currently importing, if any.
    public var runningListingID: Int64? { running }

    /// Records a request to refresh one feed.
    public mutating func request(listingID: Int64) -> Outcome {
        if isBusy(listingID: listingID) { return .alreadyPending }
        guard running == nil, !bulkRunning else {
            waiting.append(listingID)
            return .queued
        }
        running = listingID
        return .startNow
    }

    /// Marks a feed's import as over. Ignores a listing that was not the one
    /// running, so a stray or cancelled task cannot hand away another feed's
    /// turn.
    public mutating func finish(listingID: Int64) {
        guard running == listingID else { return }
        running = nil
    }

    /// Takes the next waiting feed and marks it running. Returns nil when
    /// nothing is waiting, which is the signal that the queue has drained.
    public mutating func next() -> Int64? {
        guard running == nil, !bulkRunning, !waiting.isEmpty else { return nil }
        let id = waiting.removeFirst()
        running = id
        return id
    }

    /// Takes the next waiting feed that is still worth importing.
    ///
    /// A feed can wait in this queue for as long as the imports ahead of it
    /// take, and the owner can archive a property or disconnect a feed in that
    /// time. Running the stale request anyway would import against something
    /// they had just taken out of service, so each one is re-checked at the
    /// moment its turn comes. A refused feed is released — never left showing
    /// "Queued" for ever — and reported through `onSkip` rather than dropped
    /// quietly.
    public mutating func nextRunnable(
        isRunnable: (Int64) -> Bool,
        onSkip: (Int64) -> Void = { _ in }
    ) -> Int64? {
        while let id = next() {
            if isRunnable(id) { return id }
            finish(listingID: id)
            onSkip(id)
        }
        return nil
    }

    /// Starts a "Refresh all" pass. Returns false when a feed is already
    /// importing, because imports stay one at a time.
    public mutating func beginBulk() -> Bool {
        guard running == nil, !bulkRunning else { return false }
        bulkRunning = true
        return true
    }

    /// Ends the pass. Anything that queued behind it can now run.
    public mutating func endBulk() {
        bulkRunning = false
    }
}
