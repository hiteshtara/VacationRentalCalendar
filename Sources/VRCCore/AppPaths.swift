import Foundation

public enum AppPaths {
    public static let folderName = "VacationRentalCalendar"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    public static var databaseURL: URL {
        supportDirectory.appendingPathComponent("VacationRentalCalendar.sqlite")
    }

    /// Executables that should share one Keychain grant: the app bundle's own
    /// binary and the `vrc` command-line tool built beside it.
    public static func siblingExecutablePaths() -> [String] {
        var paths: [String] = []
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let directory = executable.deletingLastPathComponent()
        for name in ["VacationRentalCalendar", "vrc"] {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                paths.append(candidate.path)
            }
        }
        return paths
    }

    public static var exportsDirectory: URL {
        supportDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    public static func ensureDirectories() {
        for url in [supportDirectory, exportsDirectory] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
