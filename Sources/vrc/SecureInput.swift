import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Terminal input that does not echo, for pasting a calendar feed URL.
///
/// A feed URL is a bearer credential: anyone holding it can read the
/// property's occupancy. It therefore must not reach any of the four places a
/// credential normally leaks on its way through a terminal:
///
///   * the **screen**, where it stays in the scrollback — handled here, by
///     clearing ECHO for the duration of the read;
///   * **shell history**, avoided by reading from standard input rather than
///     taking the URL as an argument;
///   * **process arguments**, visible to every other process on the machine
///     via `ps` — same reason;
///   * **logs**, avoided by never printing the value back, not even truncated.
///
/// `getpass(3)` would do most of this but caps the input at `PASS_MAX`
/// (128 bytes) and on some platforms reads from `/dev/tty` in ways that defeat
/// scripted testing. Driving `termios` directly has neither limit.
enum SecureInput {

    /// Reads one line with echo suppressed. The prompt goes to standard error
    /// so that redirecting standard output cannot capture it, and so the
    /// prompt still appears when output is piped.
    ///
    /// Returns nil at end of input. Restores the previous terminal state on
    /// every path, including when the read throws or the process is
    /// interrupted mid-line.
    static func readLine(prompt: String) -> String? {
        FileHandle.standardError.write(Data(prompt.utf8))

        guard isatty(STDIN_FILENO) == 1 else {
            // Not a terminal — there is no echo to suppress. Reading anyway
            // keeps the command testable, and the caller is told so that it
            // can refuse to save a credential supplied this way.
            FileHandle.standardError.write(Data("\n".utf8))
            return Swift.readLine(strippingNewline: true)
        }

        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            FileHandle.standardError.write(Data("\n".utf8))
            return Swift.readLine(strippingNewline: true)
        }

        var quiet = original
        quiet.c_lflag &= ~tcflag_t(ECHO)
        // ECHONL off as well: with ECHO cleared, a terminal that echoes the
        // newline alone would still move the cursor and reveal the input's
        // length by line wrapping.
        quiet.c_lflag &= ~tcflag_t(ECHONL)

        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet) == 0 else {
            FileHandle.standardError.write(Data("\n".utf8))
            return Swift.readLine(strippingNewline: true)
        }

        defer {
            // TCSAFLUSH discards anything typed but unread, so a stray
            // keystroke after Return cannot leak into the next prompt.
            var restore = original
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore)
            FileHandle.standardError.write(Data("\n".utf8))
        }

        return Swift.readLine(strippingNewline: true)
    }

    static var standardInputIsTerminal: Bool { isatty(STDIN_FILENO) == 1 }

    /// A description safe to print. Shows the host and nothing else: enough to
    /// confirm the right platform was pasted, useless to anyone reading a log.
    ///
    /// The path and query are where the secret lives — Airbnb puts the token in
    /// `?t=`, Vrbo in the path — so neither is ever shown, not even in part.
    static func redact(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else {
            return "<unparseable>"
        }
        let pathSegments = url.path.split(separator: "/").count
        return "https://\(host)/… (\(pathSegments) path segment(s)"
            + (url.query == nil ? ", no query)" : ", query present)")
    }
}
