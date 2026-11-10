import Foundation

/// Stops a retryable Keychain failure from turning into a stream of dialogs.
///
/// Making a cancelled authorization retryable fixes the latch, but on its own
/// it invites the opposite fault: a "Refresh all" pass walks three feeds, each
/// read raises a dialog, and dismissing one produces two more. An hourly timer
/// then repeats that for as long as the condition lasts.
///
/// So after an authorization-related failure this holds off on reads for that
/// one reference. Nothing else is affected: other references are untouched,
/// presence checks still work because they read attributes and cannot prompt,
/// and a settled refusal is passed straight through — delaying `accessDenied`
/// would only postpone the message the owner needs.
///
/// The hold-off is deliberately **not** a backoff that grows. It is a fixed,
/// short window whose only job is to collapse a burst of automatic reads into
/// one. An explicit refresh by the owner clears it, because a prompt is
/// tolerable when they just asked for one and is not tolerable on a timer.
///
/// Process-scoped and in memory on purpose: it is a statement about what just
/// happened on this machine in the last few minutes, not a fact worth storing.
public final class AuthorizationCooloffFeedCredentialStore: FeedCredentialStore, @unchecked Sendable {

    /// Long enough to collapse one refresh pass and the burst of retries
    /// around it; short enough that a real recovery is not delayed.
    public static let defaultCooloff: TimeInterval = 600

    private let wrapped: FeedCredentialStore
    private let cooloff: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var holdUntil: [String: Date] = [:]

    public init(
        wrapping wrapped: FeedCredentialStore,
        cooloff: TimeInterval = AuthorizationCooloffFeedCredentialStore.defaultCooloff,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.wrapped = wrapped
        self.cooloff = cooloff
        self.now = now
    }

    public var storageDescription: String { wrapped.storageDescription }

    public func save(url: String, reference: String) throws {
        try wrapped.save(url: url, reference: reference)
        allowRetry(reference: reference)
    }

    public func delete(reference: String) throws {
        try wrapped.delete(reference: reference)
        allowRetry(reference: reference)
    }

    /// Attribute-only, so it cannot prompt and is never held off. The UI asks
    /// this on every redraw and must keep getting an answer.
    public func exists(reference: String) -> Bool { wrapped.exists(reference: reference) }

    /// Clears the hold-off for one reference. Called when the owner asks for a
    /// refresh themselves, and whenever a URL is saved or removed.
    public func allowRetry(reference: String) {
        lock.lock(); holdUntil[reference] = nil; lock.unlock()
    }

    /// When this reference will next be read, if it is being held off.
    public func heldUntil(reference: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let until = holdUntil[reference], now() < until else { return nil }
        return until
    }

    public func url(reference: String) throws -> String? {
        if let until = heldUntil(reference: reference) {
            throw FeedCredentialError.authorizationSuppressed(retryAt: until)
        }
        do {
            let value = try wrapped.url(reference: reference)
            allowRetry(reference: reference)
            return value
        } catch let error as FeedCredentialError {
            // Only hold off where asking again would raise another dialog, and
            // only where asking again might actually help. A settled refusal
            // is reported immediately and every time.
            if let failure = error.keychainFailure,
               failure.involvedAuthorization, failure.isRetryable {
                lock.lock(); holdUntil[reference] = now() + cooloff; lock.unlock()
            }
            throw error
        }
    }
}
