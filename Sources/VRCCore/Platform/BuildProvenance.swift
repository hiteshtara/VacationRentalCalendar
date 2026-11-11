import Foundation

/// Where this build came from, read from the bundle's Info.plist.
///
/// Exists because "the app looks unchanged" and "the app is unchanged" are
/// different claims, and only the bundle can settle which one is true.
public struct BuildProvenance: Sendable, Equatable {
    public var version: String
    public var build: String
    public var commit: String
    public var branch: String
    public var workingTree: String
    public var buildDate: String
    /// The modification time of the running executable. Independent of the
    /// plist, so a stale plist cannot make an old binary look new.
    public var executableModified: Date?

    public var isFromGit: Bool { commit != "unknown" && !commit.isEmpty }
    public var wasDirty: Bool { workingTree == "modified" }

    public var summary: String {
        var text = "\(version) (\(build))"
        if isFromGit {
            text += " · \(branch) \(commit)"
            if wasDirty { text += " +local changes" }
        }
        return text
    }

    public static func current() -> BuildProvenance {
        let info = Bundle.main.infoDictionary ?? [:]
        func string(_ key: String) -> String {
            (info[key] as? String) ?? "unknown"
        }
        var modified: Date?
        if let path = Bundle.main.executableURL?.path,
           let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
            modified = attributes[.modificationDate] as? Date
        }
        return BuildProvenance(
            version: string("CFBundleShortVersionString"),
            build: string("CFBundleVersion"),
            commit: string("VRCGitCommit"),
            branch: string("VRCGitBranch"),
            workingTree: string("VRCWorkingTree"),
            buildDate: string("VRCBuildDate"),
            executableModified: modified)
    }
}
