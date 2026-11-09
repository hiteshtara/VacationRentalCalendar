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
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}
