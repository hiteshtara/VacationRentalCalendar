import Foundation

/// The gate a destructive test setup must pass before it deletes anything.
///
/// The PostgreSQL integration suite truncates the database it is pointed at —
/// `properties`, `reservations`, `holds`, `events`, `classifications`,
/// `availability_decisions`, `platform_listings`, `sync_runs` and more — so
/// that it can compare a known workflow against a known starting point. That
/// is correct behaviour for a scratch database. On 2026-11-09 it was pointed
/// at the shared staging cluster and emptied it, destroying the synthetic demo
/// rows, two synthetic approved decisions and a `platform_listings` row.
///
/// So the setup is not softened. The aim is constrained instead, and the rule
/// is **fail closed**: a target is refused unless it proves itself disposable.
/// Four independent things must all be true, and any one of them missing — or
/// merely unreadable — is a refusal:
///
/// 1. **The operator consents**, through an environment variable whose value
///    is a sentence rather than a flag, so no CI template that enables every
///    `VRC_` variable can turn it on by accident.
/// 2. **The target is not on the deny-list.** This is checked before anything
///    else about the name and nothing overrides it, so appending a friendly
///    suffix to a protected identifier does not get past it.
/// 3. **A cluster names itself disposable**, matched against an allow-list.
///    The house style is to allow-list so that a name nobody has considered is
///    refused by default rather than permitted by default — the same reasoning
///    as `describesGenuineUnavailability`.
/// 4. **The database itself carries a disposable marker.** This is the
///    strongest of the four, because it travels with the database rather than
///    with the invocation: a shared cluster does not have one and cannot
///    acquire one by accident.
///
/// Compare `RehearsalIsolation`, which solves the same shape of problem for
/// publication rehearsals against the local SQLite database.
public enum DestructiveTestIsolation {

    /// The variable the operator must set, and the only value that counts.
    public static let consentVariable = "VRC_DESTRUCTIVE_TESTS"
    public static let consentValue = "i-understand-this-truncates"

    /// The `app_settings` key whose value must be `true` in the target
    /// database. `app_settings` is deliberately not in the suite's truncation
    /// list, so the marker survives the very operation it authorizes.
    public static let markerKey = "disposable_database"

    /// What the destructive setup is about to be pointed at.
    public enum Target: Sendable, Equatable {
        /// A remote cluster, named by its RDS cluster identifier.
        case cluster(identifier: String)
        /// A local database, named however the caller can best describe it —
        /// host, port and database name.
        case local(label: String)

        public var described: String {
            switch self {
            case .cluster(let identifier): return identifier
            case .local(let label): return label
            }
        }
    }

    /// `LocalizedError` alone is not enough: the test harness, `print` and
    /// string interpolation all show the enum case name, so the explanation
    /// written below would never reach the person who needs it.
    public enum Refusal: Error, LocalizedError, CustomStringConvertible, Equatable {
        public var description: String { errorDescription ?? "refused" }

        case noOperatorConsent
        case protectedTarget(String)
        case clusterNotNamedDisposable(String)
        case notMarkedDisposable(String)
        case markerUnreadable(String)

        public var errorDescription: String? {
            switch self {
            case .noOperatorConsent:
                return "Refusing to run a destructive test setup: \(consentVariable) is not "
                    + "set to the required value. This setup truncates tables. Set "
                    + "\(consentVariable)=\(consentValue) only when the target database is "
                    + "genuinely disposable."
            case .protectedTarget(let name):
                return "Refusing to truncate \"\(name)\": it is a protected database. "
                    + "Shared staging and anything resembling production are never valid "
                    + "targets for a destructive test, whatever else is configured. Create a "
                    + "disposable cluster instead — the Phase C point-in-time-recovery "
                    + "procedure produces one — run against that, and delete it afterwards."
            case .clusterNotNamedDisposable(let name):
                return "Refusing to truncate cluster \"\(name)\": its identifier does not "
                    + "declare it disposable. Name a throwaway cluster with one of "
                    + Self.disposableMarkers.map { "\"\($0)\"" }.joined(separator: ", ")
                    + " so that a cluster nobody has considered is refused by default."
            case .notMarkedDisposable(let name):
                return "Refusing to truncate \"\(name)\": the database does not carry the "
                    + "disposable marker. Set app_settings.\(markerKey) = 'true' in the "
                    + "target database to confirm it is a sandbox whose rows may be deleted."
            case .markerUnreadable(let name):
                return "Refusing to truncate \"\(name)\": the disposable marker could not be "
                    + "read, so whether this database may be emptied is unknown. An unknown "
                    + "answer is a refusal — the one guess that matters here is the wrong one."
            }
        }

        static let disposableMarkers = DestructiveTestIsolation.disposableMarkers
    }

    /// Names that are never valid destructive targets, matched as a
    /// case-insensitive substring so a suffix cannot launder them.
    ///
    /// `staging` alone is deliberately absent: a disposable clone of staging
    /// (`vrc-staging-pitr`) is exactly the right target, while the shared
    /// cluster is named in full.
    public static let protectedFragments = [
        "vrc-staging-main",
        "prod",
        "production",
        "priyanka",
        "vrc-live",
    ]

    /// A cluster identifier must contain one of these to be a candidate.
    public static let disposableMarkers = [
        "scratch", "throwaway", "disposable", "pitr", "ephemeral", "sandbox",
    ]

    /// Throws unless `target` is demonstrably disposable.
    ///
    /// - Parameter marker: reads `app_settings.disposable_database` from the
    ///   target database. Returning `nil` means no such row; throwing means
    ///   the question could not be answered, and both are refusals.
    public static func assertDisposable(
        _ target: Target,
        environment: [String: String],
        marker: () throws -> String?
    ) throws {
        // 1. Operator consent, exactly.
        guard environment[consentVariable] == consentValue else {
            throw Refusal.noOperatorConsent
        }

        // 2. The deny-list, before any other judgement about the name and
        //    above every other signal.
        let name = target.described
        let lowered = name.lowercased()
        if protectedFragments.contains(where: { lowered.contains($0) }) {
            throw Refusal.protectedTarget(name)
        }

        // 3. A remote cluster must name itself disposable. A local database is
        //    not asked to, because its label is a host and port rather than a
        //    name anyone chose — but it is still subject to the deny-list
        //    above, since a tunnel can put a shared cluster behind localhost.
        if case .cluster(let identifier) = target {
            guard disposableMarkers.contains(where: { lowered.contains($0) }) else {
                throw Refusal.clusterNotNamedDisposable(identifier)
            }
        }

        // 4. The database's own consent, and no assumption if it cannot be read.
        let value: String?
        do {
            value = try marker()
        } catch {
            throw Refusal.markerUnreadable(name)
        }
        guard let value,
              value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true" else {
            throw Refusal.notMarkedDisposable(name)
        }
    }
}
