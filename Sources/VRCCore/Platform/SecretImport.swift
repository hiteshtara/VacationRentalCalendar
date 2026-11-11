import Foundation

/// A narrowly scoped transfer of one secret into the credential store.
///
/// Exists for the Booking.com outbound feed token, which the application
/// cannot read. Its ACL trusts only `/usr/bin/security` and its partition is
/// `apple-tool:`, so the app has never been on its access list — and unlike a
/// feed URL it cannot simply be re-entered, because Booking.com is already
/// subscribed to the URL that contains it. Re-issuing would mean handing the
/// platform a new URL.
///
/// So the value is handed over by the one tool that *is* trusted, in memory,
/// and written straight into the destination store under the same reference.
///
/// What this type guarantees, and what the tests assert:
///
///   * the value never appears in the result, in an error, or in any log line
///     — only a 12-character digest, enough to prove the right thing moved and
///     useless for reading a calendar;
///   * an empty or whitespace-only value is refused rather than written, so a
///     failed upstream read cannot silently destroy a credential by
///     overwriting it with nothing;
///   * the write is verified by reading it back and comparing digests;
///   * the reference name is never altered, so no platform URL changes.
///
/// It deliberately does NOT read from the legacy store, and it never deletes
/// anything: the legacy copy stays exactly where it is, for rollback.
public enum SecretImport {

    public struct Report: Sendable, Equatable, CustomStringConvertible {
        public let reference: String
        /// First 12 characters of the SHA-256. Never the value.
        public let digest: String
        public let verified: Bool

        public var description: String {
            "\(reference): imported [\(digest)]" + (verified ? " verified" : " NOT VERIFIED")
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case emptyValue(reference: String)
        case writeFailed(reference: String, detail: String)
        case verificationFailed(reference: String)

        public var errorDescription: String? {
            switch self {
            case .emptyValue(let reference):
                return "Refusing to import an empty value for \"\(reference)\". "
                    + "An upstream read that produced nothing must not overwrite a "
                    + "credential with nothing."
            case .writeFailed(let reference, let detail):
                return "Could not store \"\(reference)\": \(detail)"
            case .verificationFailed(let reference):
                return "Stored \"\(reference)\" but reading it back gave a different "
                    + "value. The credential store is not behaving as expected; nothing "
                    + "further was done."
            }
        }
    }

    public static func digest(_ value: String) -> String {
        String(EventKey.sha256(value).prefix(12))
    }

    /// Writes one secret and verifies it, returning only a digest.
    ///
    /// `value` is taken by value and never stored, logged or echoed. Callers
    /// must obtain it without putting it on a command line: a feed URL and a
    /// token are bearer credentials, and a command line is visible in `ps`
    /// and recorded in shell history.
    public static func perform(
        reference: String,
        value: String,
        into destination: FeedCredentialStore
    ) throws -> Report {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyValue(reference: reference) }

        do {
            try destination.save(url: trimmed, reference: reference)
        } catch {
            // The detail is the store's error, which never contains the value.
            throw Failure.writeFailed(
                reference: reference,
                detail: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }

        let readBack = (try? destination.url(reference: reference)) ?? nil
        guard let readBack, digest(readBack) == digest(trimmed) else {
            throw Failure.verificationFailed(reference: reference)
        }
        return Report(reference: reference, digest: digest(trimmed), verified: true)
    }
}
