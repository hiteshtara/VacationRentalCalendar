import Foundation

/// Moving credentials between two stores, planned before anything is written.
///
/// Planning first is the point. Every credential incident in this project has
/// come from a write whose effect nobody checked: an in-place save that kept a
/// stale access list, a verification that grepped a command which does not
/// exist, a summary that contradicted its own per-item output. A plan can be
/// read, printed and argued with before a single item moves.
///
/// Nothing is ever deleted. The source entry survives every outcome, so a
/// migration that turns out to be wrong is recoverable.
public enum CredentialMigration {

    public enum Outcome: String, Equatable, Sendable {
        /// Readable in the source and absent from the destination.
        case willMigrate
        /// Present in the destination already. Migration is repeatable.
        case alreadyPresent
        /// An item exists in the source but cannot be read — the state after a
        /// rebuild. Named so the owner can re-enter it; never guessed at and
        /// never replaced with an empty entry.
        case sourceUnreadable
        /// No item at all. Never configured is not the same as broken.
        case notConfigured
    }

    /// One reference's plan.
    ///
    /// `CustomStringConvertible` deliberately prints the digest and never the
    /// value: a plan is meant to be looked at, and a feed URL is a bearer
    /// token for a whole booking calendar.
    public struct Step: Equatable, Sendable, CustomStringConvertible {
        public let reference: String
        public let outcome: Outcome
        /// First 12 characters of the SHA-256 of the source value. Enough to
        /// prove the right value moved, useless for reading a calendar.
        public let sourceDigest: String?

        public var description: String {
            "\(reference): \(outcome.rawValue)" + (sourceDigest.map { " [\($0)]" } ?? "")
        }
    }

    public struct Result: Equatable, Sendable {
        public var migrated: Int
        public var alreadyPresent: Int
        public var notConfigured: Int
        public var failed: Int
    }

    static func digest(_ value: String) -> String {
        String(EventKey.sha256(value).prefix(12))
    }

    /// Decides what WOULD happen. Reads the source, writes nothing.
    public static func plan(
        references: [String], from source: FeedCredentialStore, to destination: FeedCredentialStore
    ) throws -> [Step] {
        references.map { reference in
            if destination.exists(reference: reference) {
                return Step(reference: reference, outcome: .alreadyPresent, sourceDigest: nil)
            }
            guard source.exists(reference: reference) else {
                return Step(reference: reference, outcome: .notConfigured, sourceDigest: nil)
            }
            // `try?` flattens a throwing call returning String? into String?,
            // which would make "the read failed" and "there is no value" the
            // same answer. They are not, so this is explicit.
            do {
                guard let value = try source.url(reference: reference) else {
                    return Step(reference: reference, outcome: .sourceUnreadable,
                                sourceDigest: nil)
                }
                return Step(reference: reference, outcome: .willMigrate,
                            sourceDigest: digest(value))
            } catch {
                return Step(reference: reference, outcome: .sourceUnreadable, sourceDigest: nil)
            }
        }
    }

    /// Carries out a plan, verifying each copy by reading it back.
    ///
    /// A write that reports success without being checked is how this project
    /// has been misled before, so a step only counts as migrated when the
    /// destination returns the same value the source held.
    @discardableResult
    public static func apply(
        _ plan: [Step], from source: FeedCredentialStore, to destination: FeedCredentialStore
    ) throws -> Result {
        var result = Result(migrated: 0, alreadyPresent: 0, notConfigured: 0, failed: 0)
        for step in plan {
            switch step.outcome {
            case .alreadyPresent: result.alreadyPresent += 1
            case .notConfigured:  result.notConfigured += 1
            case .sourceUnreadable: result.failed += 1
            case .willMigrate:
                let value: String
                do {
                    guard let read = try source.url(reference: step.reference) else {
                        result.failed += 1
                        continue
                    }
                    value = read
                } catch {
                    result.failed += 1
                    continue
                }
                do {
                    try destination.save(url: value, reference: step.reference)
                } catch {
                    result.failed += 1
                    continue
                }
                // Read back. The source entry is never deleted either way.
                let readBack = try? destination.url(reference: step.reference)
                if readBack == value { result.migrated += 1 } else { result.failed += 1 }
            }
        }
        return result
    }
}
