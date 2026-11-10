import Foundation
import VRCCore

/// Runs the bundled `vrc` helper to get cloud status, because the GUI cannot
/// read the AWS credential itself.
///
/// On this machine a login-keychain item is readable only by the exact code
/// object that created it, and the GUI and the helper are different code
/// objects (see docs/KEYCHAIN.md). The helper is the authorized reader: it
/// holds the credential, signs the request, and returns only
/// `CloudStatusPayload` — counts, booleans, service status strings and date
/// ranges, never a secret.
///
/// The invocation is deliberately rigid: a fixed executable path, a fixed
/// argument vector, no shell, and output that is accepted only if it decodes to
/// the expected type. Nothing the GUI holds is interpolated into a command.
enum HelperCloudClient {
    enum Failure: Error, Equatable {
        case helperMissing
        case timedOut
        case noOutput
        case unreadableOutput
    }

    /// The bundled helper, located next to the running executable. Resolved
    /// from the bundle, not from any user input or environment variable.
    static func helperURL() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let candidate = executable.deletingLastPathComponent()
            .appendingPathComponent("vrc")
        return FileManager.default.isExecutableFile(atPath: candidate.path)
            ? candidate : nil
    }

    /// Runs `vrc cloud check --json` and returns the decoded payload.
    ///
    /// Synchronous and blocking; callers run it off the main thread. A deadline
    /// guards against the helper hanging (for instance on a Keychain prompt,
    /// which should not happen for the helper's own items but must never wedge
    /// the app).
    static func status(timeout: TimeInterval = 25) -> Result<CloudStatusPayload, Failure> {
        guard let helper = helperURL() else { return .failure(.helperMissing) }

        let process = Process()
        process.executableURL = helper
        // Fixed, literal arguments. No shell, no interpolation.
        process.arguments = ["cloud", "check", "--json"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Reading the keychain and signing happen in the helper; keep its
        // environment minimal and inherited, with diagnostics off so nothing
        // extra is written anywhere.
        var environment = ProcessInfo.processInfo.environment
        environment["VRC_KEYCHAIN_DIAGNOSTICS"] = nil
        process.environment = environment

        // Drain stdout on a background reader so a large body cannot deadlock
        // against a full pipe buffer while we wait.
        let outputData = DataBox()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                outputData.append(chunk)
            }
        }

        do {
            try process.run()
        } catch {
            return .failure(.helperMissing)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            // stderr is drained and discarded; it never reaches the GUI.
            _ = try? stderr.fileHandleForReading.readToEnd()
            return .failure(.timedOut)
        }

        // Ensure the reader has flushed.
        usleep(50_000)
        stdout.fileHandleForReading.readabilityHandler = nil
        _ = try? stderr.fileHandleForReading.readToEnd()

        let data = outputData.value
        guard !data.isEmpty else { return .failure(.noOutput) }
        // Accept only the last non-empty line, and only if it decodes. Anything
        // that is not a valid payload is rejected rather than shown.
        let lines = data.split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }
        guard let last = lines.last,
              let payload = CloudStatusPayload.decode(Data(last)) else {
            return .failure(.unreadableOutput)
        }
        return .success(payload)
    }

    /// `status()`, but giving a sleeping cluster the one chance it needs.
    ///
    /// Aurora Serverless v2 is at minimum capacity 0 with a 300s auto-pause,
    /// so the first call after an idle spell is the one that wakes it and is
    /// expected to fail. Without this the Cloud pane reports "Could not reach
    /// the AWS service" every time it is opened on a cold cluster — reliably,
    /// not occasionally. See `CloudRetryPolicy`.
    ///
    /// `sleep` and `attempt` are injectable so the sequencing can be exercised
    /// without a five-second pause or a real cluster.
    static func statusWakingSleepingCluster(
        timeout: TimeInterval = 25,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        attempt: (TimeInterval) -> Result<CloudStatusPayload, Failure> = {
            status(timeout: $0)
        }
    ) -> Result<CloudStatusPayload, Failure> {
        let first = attempt(timeout)
        let worthRetrying: Bool
        switch first {
        case .success(let payload):
            worthRetrying = CloudRetryPolicy.shouldRetry(payload.health)
        case .failure(.timedOut):
            // The helper itself ran out of time, which on a cold cluster means
            // the same thing: the database was still waking.
            worthRetrying = true
        case .failure(.helperMissing), .failure(.noOutput), .failure(.unreadableOutput):
            // Nothing about these improves by asking again.
            worthRetrying = false
        }
        guard worthRetrying else { return first }
        sleep(CloudRetryPolicy.delay)
        return attempt(timeout)
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}
