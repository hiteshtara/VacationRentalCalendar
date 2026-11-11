import Foundation

/// Produces a cloud status payload in process.
///
/// Extracted so the GUI no longer has to spawn the `vrc` helper to find out
/// whether AWS is reachable. The app and the CLI now call the same function
/// rather than one shelling out to the other, which removes three problems at
/// once:
///
/// * the helper is a second code object with its own credential access, and
///   "the app and its own helper disagree about whether a credential is
///   readable" has been the most expensive bug class in this project;
/// * a nested bare executable cannot carry the `keychain-access-groups`
///   entitlement at all, so after the Keychain migration the helper could not
///   do this work even if asked;
/// * spawning a subprocess to parse its stdout is a parsing problem nobody
///   needs when the logic is already a library.
public enum CloudStatusService {

    /// Reads the cloud status, returning a payload that never carries a secret.
    ///
    /// Every failure is a payload rather than a thrown error, because the
    /// caller is a status indicator: "not configured" and "unreachable" are
    /// answers, not exceptions.
    public static func status(for connection: CloudConnection) -> CloudStatusPayload {
        guard let client = connection.makeClient() else {
            switch connection.availability() {
            case .insecureEndpoint:
                return .failure(.insecureEndpoint, "The stored endpoint is not https.")
            case .credentialUnreadable:
                return .failure(.notConfigured,
                                "The stored AWS credential cannot be read by this build.")
            default:
                return .failure(.notConfigured, "No AWS endpoint or credentials stored.")
            }
        }
        do {
            let status = try client.status()
            let intervals = (try? client.availability()) ?? []
            return .reached(status, intervals: intervals)
        } catch {
            return .failure(.unreachable, "Could not reach the AWS service.")
        }
    }
}
