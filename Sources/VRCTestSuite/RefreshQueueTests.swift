import Foundation
import VRCCore

/// Tests for the per-feed Refresh action's gating.
///
/// The bug these exist for, 2026-11-10: the owner clicked Refresh on Airbnb,
/// then on Vrbo and Booking.com. Only Airbnb imported. `sync_runs` recorded
/// nothing at all for the other two — no success, no failure, no connection
/// change — and every path through `ImportService.importFeed` records a run,
/// so the import was never entered.
///
/// The cause was the view's `disabled(!hasCredential || state.isRefreshing)`.
/// `isRefreshing` was a single app-wide flag held for the WHOLE of one feed's
/// import, which for Airbnb was ten seconds (22:08:46 → 22:08:56, a Keychain
/// prompt inside it). While it was held, every per-feed Refresh button in the
/// app rendered disabled, so the two later clicks were discarded by SwiftUI
/// with no record and no feedback. The owner clicked correctly; the button was
/// dead.
///
/// So the rule being established: a Refresh request is never silently dropped.
/// A feed that is already busy coalesces, and a feed that is merely waiting on
/// another feed's turn is QUEUED and runs afterwards.
public enum RefreshQueueTests {

    // MARK: - Fixtures

    static func listing(
        _ id: Int64,
        property: Int64 = 1,
        platform: RentalPlatform = .vrbo,
        state: FeedConnectionState = .connected,
        url: String = "",
        storage: FeedURLStorage = .keychain,
        ref: String = "ref"
    ) -> PlatformListing {
        PlatformListing(
            id: id, propertyID: property, platform: platform,
            label: "listing \(id)", icalURL: url, urlStorage: storage,
            credentialRef: ref, connectionState: state
        )
    }

    static func property(_ id: Int64, archived: Bool = false) -> Property {
        Property(id: id, name: "property \(id)",
                 archivedAt: archived ? Date() : nil)
    }

    /// Drives the queue the way `AppState.runRefreshes` does, recording what
    /// ran and what was skipped.
    ///
    /// Deliberately built out of the SHIPPED primitives — `request`, `finish`
    /// and `nextRunnable` — rather than reimplementing their logic, so the
    /// ordering and skipping rules under test are the ones the app uses. The
    /// app's own ten-line loop around them cannot be unit-tested here: this
    /// project has Command Line Tools only, so there is no way to host the
    /// SwiftUI target in a test.
    static func drain(
        _ queue: inout FeedRefreshQueue,
        startingWith start: Int64,
        runnable: (Int64) -> Bool = { _ in true }
    ) -> (ran: [Int64], skipped: [Int64]) {
        var ran: [Int64] = []
        var skipped: [Int64] = []
        var current: Int64? = start
        while let id = current {
            // An import reports failure in its return value and never throws,
            // so the loop advances identically whatever the outcome was.
            ran.append(id)
            queue.finish(listingID: id)
            current = queue.nextRunnable(
                isRunnable: runnable, onSkip: { skipped.append($0) })
        }
        return (ran, skipped)
    }

    public static var cases: [TestCase] { [

        // MARK: - Starting, queueing, coalescing

        TestCase(group: "RefreshQueue",
                 name: "a request on an idle queue starts at once") { expect in
            var queue = FeedRefreshQueue()
            expect.equal(queue.request(listingID: 1), .startNow,
                         "nothing else is running, so it runs")
            expect.ok(queue.isBusy(listingID: 1))
            expect.ok(queue.hasWorkInFlight)
        },

        TestCase(group: "RefreshQueue",
                 name: "a second feed requested during the first is queued, NOT dropped") { expect in
            // The regression. Previously this click hit a disabled button and
            // vanished; now it is held and run when the first finishes.
            var queue = FeedRefreshQueue()
            expect.equal(queue.request(listingID: 1), .startNow)
            expect.equal(queue.request(listingID: 3), .queued,
                         "Booking.com waits its turn rather than being discarded")
            expect.ok(queue.isBusy(listingID: 3), "and the row shows it is pending")
        },

        TestCase(group: "RefreshQueue",
                 name: "an idle feed stays clickable while another feed refreshes") { expect in
            // The other half of the fix: one feed refreshing must not disable
            // the whole settings pane, which is what made the bug invisible.
            var queue = FeedRefreshQueue()
            _ = queue.request(listingID: 1)
            expect.ok(!queue.isBusy(listingID: 2),
                      "Airbnb's row is not disabled by Vrbo's refresh")
            expect.ok(!queue.isBusy(listingID: 3))
        },

        TestCase(group: "RefreshQueue",
                 name: "clicking a busy feed again coalesces instead of queueing twice") { expect in
            var queue = FeedRefreshQueue()
            _ = queue.request(listingID: 1)
            expect.equal(queue.request(listingID: 1), .alreadyPending,
                         "an impatient second click must not import twice")
            _ = queue.request(listingID: 3)
            expect.equal(queue.request(listingID: 3), .alreadyPending)
            queue.finish(listingID: 1)
            expect.equal(queue.next(), 3)
            expect.equal(queue.next(), nil, "3 was queued once, not twice")
        },

        TestCase(group: "RefreshQueue",
                 name: "finishing one feed hands the turn to the next in order") { expect in
            var queue = FeedRefreshQueue()
            _ = queue.request(listingID: 2)
            _ = queue.request(listingID: 1)
            _ = queue.request(listingID: 3)
            queue.finish(listingID: 2)
            expect.equal(queue.next(), 1, "first queued, first run")
            queue.finish(listingID: 1)
            expect.equal(queue.next(), 3)
            queue.finish(listingID: 3)
            expect.equal(queue.next(), nil)
            expect.ok(!queue.hasWorkInFlight, "and the queue drains completely")
        },

        TestCase(group: "RefreshQueue",
                 name: "a drained queue reports every feed idle") { expect in
            // A latched flag is how three feeds went silent for an hour once
            // already. Draining must leave nothing marked busy.
            var queue = FeedRefreshQueue()
            _ = queue.request(listingID: 1)
            _ = queue.request(listingID: 3)
            queue.finish(listingID: 1)
            _ = queue.next()
            queue.finish(listingID: 3)
            _ = queue.next()
            for id in Int64(1)...Int64(6) {
                expect.ok(!queue.isBusy(listingID: id), "listing \(id) is idle")
            }
            expect.ok(!queue.hasWorkInFlight)
        },

        // MARK: - Requirement 1: Refresh all

        TestCase(group: "RefreshQueue",
                 name: "a bulk pass holds the queue, so a per-feed click queues behind it") { expect in
            // Refresh all imports every feed in turn. A per-feed click during
            // it must not start a second concurrent import — the Keychain is
            // the shared resource — but it must not be dropped either.
            var queue = FeedRefreshQueue()
            expect.ok(queue.beginBulk(), "the pass starts")
            expect.ok(queue.hasWorkInFlight)
            expect.equal(queue.request(listingID: 1), .queued,
                         "a click during Refresh all waits rather than vanishing")
            expect.equal(queue.next(), nil, "and cannot jump ahead of the pass")
            queue.endBulk()
            expect.equal(queue.next(), 1, "it runs once the pass is done")
        },

        TestCase(group: "RefreshQueue",
                 name: "a bulk pass refuses to start while a feed is refreshing") { expect in
            var queue = FeedRefreshQueue()
            _ = queue.request(listingID: 1)
            expect.ok(!queue.beginBulk(), "Refresh all waits for a clear queue")
            queue.finish(listingID: 1)
            expect.ok(queue.beginBulk())
            queue.endBulk()
            expect.ok(!queue.hasWorkInFlight)
        },

        TestCase(group: "RefreshQueue",
                 name: "a bulk pass does not disable individual rows on its own") { expect in
            // Refresh all shows its own progress; it must not leave every row
            // looking broken, which is the appearance the old flag gave.
            var queue = FeedRefreshQueue()
            _ = queue.beginBulk()
            expect.ok(!queue.isBusy(listingID: 1))
            expect.ok(!queue.isBusy(listingID: 2))
        },

        TestCase(group: "RefreshQueue",
                 name: "a second bulk pass cannot overlap the first") { expect in
            // The auto-refresh timer fires on its own schedule and must never
            // start a pass on top of a running one.
            var queue = FeedRefreshQueue()
            expect.ok(queue.beginBulk())
            expect.ok(!queue.beginBulk(), "the timer's pass is refused, not doubled")
            queue.endBulk()
            expect.ok(queue.beginBulk(), "and the next cycle may run")
        },

        TestCase(group: "RefreshQueue",
                 name: "everything clicked during a bulk pass runs after it, once each") { expect in
            var queue = FeedRefreshQueue()
            _ = queue.beginBulk()
            expect.equal(queue.request(listingID: 3), .queued)
            expect.equal(queue.request(listingID: 1), .queued)
            expect.equal(queue.request(listingID: 3), .alreadyPending)
            queue.endBulk()
            guard let first = queue.next() else { return expect.fail("nothing queued") }
            let result = drain(&queue, startingWith: first)
            expect.equal(result.ran, [3, 1], "in the order they were clicked")
            expect.ok(!queue.hasWorkInFlight)
        },

        TestCase(group: "RefreshQueue",
                 name: "finishing a feed that was never started changes nothing") { expect in
            // Defensive: a cancelled task must not clear someone else's turn.
            var queue = FeedRefreshQueue()
            _ = queue.request(listingID: 1)
            queue.finish(listingID: 9)
            expect.ok(queue.isBusy(listingID: 1), "listing 1 is still running")
            expect.ok(queue.hasWorkInFlight)
        },

        // MARK: - Requirement 2: a visible state per feed

        TestCase(group: "RefreshQueue",
                 name: "each feed reports its own progress state") { expect in
            var queue = FeedRefreshQueue()
            _ = queue.request(listingID: 1)
            _ = queue.request(listingID: 3)
            expect.equal(queue.state(of: 1), .refreshing, "the one importing")
            expect.equal(queue.state(of: 3), .queued, "the one waiting its turn")
            expect.equal(queue.state(of: 2), .idle, "and an untouched feed")
        },

        TestCase(group: "RefreshQueue",
                 name: "the progress state has a distinct label for each case") { expect in
            // The old button said "Refresh" whether it was working, waiting or
            // dead. Each state must read differently or the owner cannot tell
            // a queued feed from an ignored click.
            let labels = [FeedRefreshQueue.FeedState.idle.buttonLabel,
                          FeedRefreshQueue.FeedState.refreshing.buttonLabel,
                          FeedRefreshQueue.FeedState.queued.buttonLabel]
            expect.equal(Set(labels).count, 3, "got \(labels)")
            expect.equal(FeedRefreshQueue.FeedState.idle.buttonLabel, "Refresh")
            expect.ok(FeedRefreshQueue.FeedState.refreshing.showsProgress,
                      "an importing feed shows a spinner")
            expect.ok(FeedRefreshQueue.FeedState.queued.showsProgress,
                      "so does a waiting one — it is pending, not finished")
            expect.ok(!FeedRefreshQueue.FeedState.idle.showsProgress)
        },

        TestCase(group: "RefreshQueue",
                 name: "state follows the feed through its whole turn") { expect in
            var queue = FeedRefreshQueue()
            _ = queue.request(listingID: 1)
            _ = queue.request(listingID: 2)
            expect.equal(queue.state(of: 2), .queued)
            queue.finish(listingID: 1)
            _ = queue.next()
            expect.equal(queue.state(of: 2), .refreshing, "promoted, not forgotten")
            expect.equal(queue.state(of: 1), .idle, "and the finished one is released")
            queue.finish(listingID: 2)
            expect.equal(queue.state(of: 2), .idle)
        },

        // MARK: - Requirements 3 & 4: nothing discarded, nothing doubled

        TestCase(group: "RefreshQueue",
                 name: "five rapid clicks on one feed import it exactly once") { expect in
            // Requirement 4. The outcomes also prove requirement 3: every
            // click gets an answer, so the app can say "already refreshing"
            // instead of appearing to do nothing.
            var queue = FeedRefreshQueue()
            var outcomes: [FeedRefreshQueue.Outcome] = []
            for _ in 0..<5 { outcomes.append(queue.request(listingID: 1)) }
            expect.equal(outcomes.first, .startNow)
            expect.equal(outcomes.dropFirst().filter { $0 != .alreadyPending }.count, 0,
                         "got \(outcomes)")
            let result = drain(&queue, startingWith: 1)
            expect.equal(result.ran, [1], "one import, not five")
        },

        TestCase(group: "RefreshQueue",
                 name: "rapid clicks across three feeds run each exactly once, in order") { expect in
            var queue = FeedRefreshQueue()
            // The owner's actual sequence: Airbnb, then Vrbo, then Booking.com,
            // each within the previous one's import window, with an impatient
            // repeat thrown in.
            expect.equal(queue.request(listingID: 2), .startNow)
            expect.equal(queue.request(listingID: 1), .queued)
            expect.equal(queue.request(listingID: 3), .queued)
            expect.equal(queue.request(listingID: 1), .alreadyPending)
            let result = drain(&queue, startingWith: 2)
            expect.equal(result.ran, [2, 1, 3], "all three, in click order")
            expect.equal(result.skipped, [])
            expect.ok(!queue.hasWorkInFlight)
        },

        TestCase(group: "RefreshQueue",
                 name: "no request is answered with silence") { expect in
            // Requirement 3 stated directly: every outcome is one the UI can
            // report. There is no "dropped" case to return.
            var queue = FeedRefreshQueue()
            var seen: Set<FeedRefreshQueue.Outcome> = []
            seen.insert(queue.request(listingID: 1))
            seen.insert(queue.request(listingID: 2))
            seen.insert(queue.request(listingID: 1))
            expect.equal(seen, [.startNow, .queued, .alreadyPending],
                         "all three outcomes are distinguishable")
            for outcome in seen {
                expect.ok(!outcome.ownerMessage.isEmpty,
                          "\(outcome) must be explainable to the owner")
            }
        },

        // MARK: - Requirement 5: serial, and failure-tolerant

        TestCase(group: "RefreshQueue",
                 name: "only one feed is ever importing at a time") { expect in
            var queue = FeedRefreshQueue()
            _ = queue.request(listingID: 1)
            _ = queue.request(listingID: 2)
            _ = queue.request(listingID: 3)
            expect.equal(queue.runningListingID, 1)
            expect.equal(queue.next(), nil, "nothing starts while 1 holds the turn")
            queue.finish(listingID: 1)
            expect.equal(queue.next(), 2)
            expect.equal(queue.runningListingID, 2, "exactly one at a time")
            expect.equal(queue.next(), nil)
        },

        TestCase(group: "RefreshQueue",
                 name: "a feed whose import fails does not block the ones behind it") { expect in
            // Requirement 5. `importFeed` reports failure in its return value
            // and never throws, so the chain advances the same way either way.
            // The companion source check asserts that signature cannot change
            // without this being revisited.
            var queue = FeedRefreshQueue()
            _ = queue.request(listingID: 1)
            _ = queue.request(listingID: 2)
            _ = queue.request(listingID: 3)
            let result = drain(&queue, startingWith: 1)
            expect.equal(result.ran, [1, 2, 3],
                         "2 and 3 still ran after 1's outcome, whatever it was")
            expect.ok(!queue.hasWorkInFlight, "and nothing is left latched")
        },

        TestCase(group: "RefreshQueue",
                 name: "ImportService.importFeed stays non-throwing, so a chain cannot break") { expect in
            // Guards requirement 5 at the source. If `importFeed` ever gains
            // `throws`, the serial loop would unwind on the first failure and
            // silently abandon every feed queued behind it — the exact class
            // of silent loss this whole type exists to end.
            guard let source = try? String(
                contentsOfFile: "Sources/VRCCore/Logic/ImportService.swift",
                encoding: .utf8) else {
                return expect.fail("cannot read ImportService.swift")
            }
            expect.contains(source,
                            "public func importFeed(for listing: PlatformListing, now: Date = Date()) async -> ImportReport")
            expect.ok(!source.contains("async throws -> ImportReport"),
                      "importFeed must not throw")
        },

        // MARK: - Requirement 8: stale work is not run

        TestCase(group: "RefreshQueue",
                 name: "a feed removed while it waited is skipped, and the next one runs") { expect in
            // What the app refuses at this level is a listing that no longer
            // exists: a property delete cascades to its listings, so a queued
            // id can outlive its row and there is nothing left to import or to
            // record a run against. A feed whose property was merely ARCHIVED
            // still goes to `ImportService`, which refuses it and writes an
            // explicit skipped run — see the Archived import group.
            var queue = FeedRefreshQueue()
            _ = queue.request(listingID: 1)
            _ = queue.request(listingID: 2)   // its listing goes away while waiting
            _ = queue.request(listingID: 3)
            let result = drain(&queue, startingWith: 1, runnable: { $0 != 2 })
            expect.equal(result.ran, [1, 3], "2 was not imported")
            expect.equal(result.skipped, [2], "and its skip is reported, not hidden")
            expect.ok(!queue.hasWorkInFlight)
        },

        TestCase(group: "RefreshQueue",
                 name: "a queue of feeds that all went stale drains without running any") { expect in
            var queue = FeedRefreshQueue()
            _ = queue.request(listingID: 1)
            _ = queue.request(listingID: 2)
            _ = queue.request(listingID: 3)
            let result = drain(&queue, startingWith: 1, runnable: { _ in false })
            expect.equal(result.ran, [1], "only the one already in flight")
            expect.equal(result.skipped, [2, 3])
            expect.ok(!queue.hasWorkInFlight, "a fully stale queue still clears")
        },

        TestCase(group: "RefreshQueue",
                 name: "nextRunnable releases a skipped feed's busy state") { expect in
            // A skipped feed must not be left looking pending for ever.
            var queue = FeedRefreshQueue()
            _ = queue.request(listingID: 1)
            _ = queue.request(listingID: 2)
            queue.finish(listingID: 1)
            expect.equal(queue.nextRunnable(isRunnable: { _ in false }), nil)
            expect.equal(queue.state(of: 2), .idle, "released, not stuck on Queued")
            expect.ok(!queue.hasWorkInFlight)
        },

        // MARK: - Requirement 6: the queue outlives a view

        TestCase(group: "RefreshQueue",
                 name: "reading the queue never mutates it, so redrawing cannot drop work") { expect in
            // SwiftUI reads this on every redraw, and a view can be rebuilt or
            // navigated away from mid-import. Reads are non-mutating by type,
            // and the queue is held by the app-scoped state object rather than
            // by any view, so navigating away leaves the waiting list intact.
            var queue = FeedRefreshQueue()
            _ = queue.request(listingID: 1)
            _ = queue.request(listingID: 3)
            let before = queue
            for id in Int64(1)...Int64(6) {
                _ = queue.isBusy(listingID: id)
                _ = queue.state(of: id)
            }
            _ = queue.hasWorkInFlight
            _ = queue.runningListingID
            _ = queue.isBulkRunning
            expect.equal(queue, before, "a redraw changed the queue")
            expect.equal(queue.state(of: 3), .queued, "3 is still waiting its turn")
        },

        TestCase(group: "RefreshQueue",
                 name: "the Refresh button's state is owned by the app, not the view") { expect in
            // Requirement 6 at the source. The queue must live on AppState and
            // the per-row button must read it from there — a view-local
            // @State copy would reset on navigation and lose queued work. The
            // click itself is an unstructured Task, which is not cancelled
            // when the row disappears.
            guard let feeds = try? String(
                contentsOfFile: "Sources/VacationRentalCalendar/FeedsView.swift",
                encoding: .utf8),
                  let state = try? String(
                contentsOfFile: "Sources/VacationRentalCalendar/AppState.swift",
                encoding: .utf8) else {
                return expect.fail("cannot read the app sources")
            }
            expect.contains(state, "@Published private(set) var refreshQueue = FeedRefreshQueue()")
            expect.contains(feeds, "state.refreshState(for: listing)")
            expect.ok(!feeds.contains("@State private var refreshQueue"),
                      "the queue must not be view-local")
            expect.ok(!feeds.contains("state.isRefreshing"),
                      "no per-feed control may gate on the app-wide flag again")
        },
    ] + eligibilityCases + multiPropertyCases }

    // MARK: - Requirement 8 (and 7): what is still worth importing

    static var eligibilityCases: [TestCase] { [

        TestCase(group: "RefreshEligibility",
                 name: "a connected Keychain-backed feed is runnable") { expect in
            let verdict = FeedRefreshEligibility.of(
                listing: listing(1, state: .connected),
                property: property(1), hasStoredCredential: true)
            expect.equal(verdict, .runnable)
            expect.ok(verdict.canRun)
        },

        TestCase(group: "RefreshEligibility",
                 name: "a feed whose property was archived is not runnable") { expect in
            // The case requirement 8 names: the owner archives a property
            // while one of its feeds sits in the queue.
            let verdict = FeedRefreshEligibility.of(
                listing: listing(1, state: .connected),
                property: property(1, archived: true), hasStoredCredential: true)
            expect.equal(verdict, .propertyArchived)
            expect.ok(!verdict.canRun)
            expect.contains(verdict.explanation, "archived")
        },

        TestCase(group: "RefreshEligibility",
                 name: "a feed whose property has vanished is not runnable") { expect in
            let verdict = FeedRefreshEligibility.of(
                listing: listing(1), property: nil, hasStoredCredential: true)
            expect.equal(verdict, .propertyArchived)
            expect.ok(!verdict.canRun, "a missing property is not a reason to import")
        },

        TestCase(group: "RefreshEligibility",
                 name: "every state that must never be retried is refused") { expect in
            // Mirrors shouldAttemptImport rather than restating it: a revoked
            // or unreadable credential is never retried, because the attempt
            // blocks every later Keychain call in the process.
            for state: FeedConnectionState in
                [.revoked, .disconnectedByOwner, .credentialUnreadable, .notConfigured] {
                let verdict = FeedRefreshEligibility.of(
                    listing: listing(1, state: state),
                    property: property(1), hasStoredCredential: true)
                expect.equal(verdict, .notConnected(state), "\(state) must be refused")
                expect.ok(!verdict.canRun)
            }
        },

        TestCase(group: "RefreshEligibility",
                 name: "a retryable state is still runnable") { expect in
            // A timeout says the Keychain was slow, not that the credential is
            // broken. Treating the two alike silenced three feeds for an hour.
            for state: FeedConnectionState in [.connected, .failing, .unknown] {
                let verdict = FeedRefreshEligibility.of(
                    listing: listing(1, state: state),
                    property: property(1), hasStoredCredential: true)
                expect.ok(verdict.canRun, "\(state) must stay retryable")
            }
        },

        TestCase(group: "RefreshEligibility",
                 name: "a feed with no URL and no credential is not runnable") { expect in
            // Requirement 7's unconfigured half. Test Cottage's three feeds
            // are exactly this.
            let verdict = FeedRefreshEligibility.of(
                listing: listing(1, state: .unknown, ref: ""),
                property: property(1), hasStoredCredential: false)
            expect.equal(verdict, .noFeedURL)
            expect.contains(verdict.explanation, "No calendar URL")
        },

        TestCase(group: "RefreshEligibility",
                 name: "a feed whose URL lives in the database needs no Keychain item") { expect in
            // The other storage mode must not be mistaken for unconfigured.
            let verdict = FeedRefreshEligibility.of(
                listing: listing(1, state: .connected,
                                 url: "https://example.test/c.ics", storage: .database),
                property: property(1), hasStoredCredential: false)
            expect.equal(verdict, .runnable)
        },

        TestCase(group: "RefreshEligibility",
                 name: "an archived property outranks every other reason") { expect in
            // Order matters only for the message shown; the answer is no
            // either way. Archived is reported first because it is the fact
            // the owner changed.
            let verdict = FeedRefreshEligibility.of(
                listing: listing(1, state: .revoked, ref: ""),
                property: property(1, archived: true), hasStoredCredential: false)
            expect.equal(verdict, .propertyArchived)
        },

        TestCase(group: "RefreshEligibility",
                 name: "every refusal can be explained to the owner") { expect in
            for verdict: FeedRefreshEligibility in
                [.propertyArchived, .notConnected(.revoked), .noFeedURL] {
                expect.ok(!verdict.explanation.isEmpty, "\(verdict) needs a reason")
            }
            expect.equal(FeedRefreshEligibility.runnable.explanation, "")
        },
    ] }

    // MARK: - Requirement 7: several properties, mixed configuration

    static var multiPropertyCases: [TestCase] { [

        TestCase(group: "RefreshQueue multi-property",
                 name: "six feeds across two properties each run exactly once") { expect in
            // 39 G Street is listings 1-3; Test Cottage is 4-6.
            var queue = FeedRefreshQueue()
            var outcomes: [FeedRefreshQueue.Outcome] = []
            for id in Int64(1)...Int64(6) { outcomes.append(queue.request(listingID: id)) }
            expect.equal(outcomes.first, .startNow)
            expect.equal(outcomes.dropFirst().filter { $0 != .queued }.count, 0)
            let result = drain(&queue, startingWith: 1)
            expect.equal(result.ran, [1, 2, 3, 4, 5, 6])
            expect.equal(Set(result.ran).count, 6, "no feed ran twice")
            expect.ok(!queue.hasWorkInFlight)
        },

        TestCase(group: "RefreshQueue multi-property",
                 name: "one property's feeds do not disable the other's rows") { expect in
            var queue = FeedRefreshQueue()
            _ = queue.request(listingID: 1)
            _ = queue.request(listingID: 2)
            for id in Int64(4)...Int64(6) {
                expect.ok(!queue.isBusy(listingID: id),
                          "Test Cottage listing \(id) stays clickable")
            }
        },

        TestCase(group: "RefreshQueue multi-property",
                 name: "a mixed property imports its configured feeds and skips the rest") { expect in
            // Test Cottage has no URLs at all, and 39 G Street has three.
            // This exercises the shared rule directly; in the running app the
            // same verdict is reached inside `ImportService`, which also
            // writes the skipped run that keeps the refusal in the history.
            let properties: [Int64: Property] = [1: property(1), 2: property(2)]
            let listings: [Int64: PlatformListing] = [
                1: listing(1, property: 1, platform: .vrbo, state: .connected),
                2: listing(2, property: 1, platform: .airbnb, state: .connected),
                3: listing(3, property: 1, platform: .bookingCom, state: .connected),
                4: listing(4, property: 2, platform: .airbnb, state: .unknown, ref: ""),
                5: listing(5, property: 2, platform: .vrbo, state: .unknown, ref: ""),
                6: listing(6, property: 2, platform: .bookingCom, state: .unknown, ref: ""),
            ]
            let configured: Set<Int64> = [1, 2, 3]

            func runnable(_ id: Int64) -> Bool {
                guard let listing = listings[id] else { return false }
                return FeedRefreshEligibility.of(
                    listing: listing,
                    property: properties[listing.propertyID],
                    hasStoredCredential: configured.contains(id)
                ).canRun
            }

            var queue = FeedRefreshQueue()
            for id in Int64(1)...Int64(6) { _ = queue.request(listingID: id) }
            let result = drain(&queue, startingWith: 1, runnable: runnable)
            expect.equal(result.ran, [1, 2, 3], "only the configured feeds imported")
            expect.equal(result.skipped, [4, 5, 6], "and the rest were reported")
            expect.ok(!queue.hasWorkInFlight)
        },

        TestCase(group: "RefreshQueue multi-property",
                 name: "archiving a property mid-queue skips only its feeds") { expect in
            // The owner archives Test Cottage while all six are queued. The
            // rule is asserted here; the recorded skip it produces in the app
            // is asserted in the Archived import group.
            let properties: [Int64: Property] = [
                1: property(1), 2: property(2, archived: true),
            ]
            let listings: [Int64: PlatformListing] = Dictionary(
                uniqueKeysWithValues: (Int64(1)...Int64(6)).map { id in
                    (id, listing(id, property: id <= 3 ? 1 : 2, state: .connected))
                })

            func runnable(_ id: Int64) -> Bool {
                guard let listing = listings[id] else { return false }
                return FeedRefreshEligibility.of(
                    listing: listing,
                    property: properties[listing.propertyID],
                    hasStoredCredential: true
                ).canRun
            }

            var queue = FeedRefreshQueue()
            for id in Int64(1)...Int64(6) { _ = queue.request(listingID: id) }
            let result = drain(&queue, startingWith: 1, runnable: runnable)
            expect.equal(result.ran, [1, 2, 3], "39 G Street's feeds still imported")
            expect.equal(result.skipped, [4, 5, 6], "the archived property's did not")
        },
    ] }
}
