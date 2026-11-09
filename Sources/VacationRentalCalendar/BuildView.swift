import SwiftUI
import VRCCore

/// Which build is actually running.
///
/// The plist records what the build script was told; the executable's
/// modification time is read from disk. They are shown separately on purpose —
/// if the two disagree, the installed bundle is not what was just built.
struct BuildView: View {
    private let provenance = BuildProvenance.current()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                Row("Version", "\(provenance.version) (\(provenance.build))")
                Row("Branch", provenance.branch)
                Row("Commit", provenance.commit)
                Row("Working tree", provenance.workingTree)
                Row("Built", provenance.buildDate)
                Row("Executable written", executableModified)

                if provenance.wasDirty {
                    Label("Built from a modified working tree, so the commit "
                          + "above does not fully describe this binary.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !provenance.isFromGit {
                    Label("No git provenance recorded — this bundle predates "
                          + "provenance stamping, or was built outside the repository.",
                          systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().padding(.vertical, 4)
                Text("Code signature").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                SignatureRow()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var executableModified: String {
        guard let date = provenance.executableModified else { return "unknown" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

private struct SignatureRow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: state.signature.kind.survivesRebuild
                  ? "checkmark.seal" : "exclamationmark.triangle")
                .foregroundStyle(state.signature.kind.survivesRebuild ? .green : .orange)
            Text(state.signature.explanation)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Row: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
        }
    }
}
