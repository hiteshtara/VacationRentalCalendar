import SwiftUI
import VRCCore

/// What the AWS staging service knows, and how that compares with this Mac.
///
/// Read-only throughout. There is no button here that publishes, approves, or
/// enables a schedule; the pane exists so the owner can see the service rather
/// than take its word for anything.
struct CloudPane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                connectionCard
                if let status = state.cloud.status {
                    importCard(status)
                    countsCard(status)
                }
                intervalsCard
                Text("""
                     This pane reads the staging service only. Outbound \
                     publishing and scheduled imports are off, and nothing \
                     here changes availability on any platform.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Connection

    private var connectionCard: some View {
        Card(title: "AWS staging") {
            HStack(spacing: 9) {
                CloudHealthDot(health: state.cloud.health)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.system(size: 14, weight: .medium))
                    Text(state.cloudConfiguration.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button {
                    state.refreshFromCloud()
                } label: {
                    if state.isCloudRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh from AWS", systemImage: "arrow.clockwise.icloud")
                    }
                }
                .disabled(state.isCloudRefreshing || !state.isCloudConfigured)
            }

            // One concise line, only when there is something to act on. The
            // health label and the remedy are shown once, not stacked.
            if let guidance = guidance {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(guidance.isError ? .orange : .secondary)
                    Text(guidance.text)
                        .font(.caption)
                        .foregroundStyle(guidance.isError ? .orange : .secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let checked = state.cloud.checkedAt {
                Text("Checked \(DayMath.mediumString(checked)) at "
                     + Self.time.string(from: checked))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Not checked yet").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// At most one line: the single most useful next step, or the health
    /// message when the service itself reported a problem. Never both.
    private var guidance: (text: String, isError: Bool)? {
        switch state.cloudConfiguration {
        case .notConfigured:
            return ("Store the endpoint and an IAM access key: "
                    + "vrc cloud set-endpoint <url>, then vrc cloud set-credentials.",
                    false)
        case .insecureEndpoint:
            return ("The stored endpoint is not https. Set it again with "
                    + "vrc cloud set-endpoint https://…", true)
        case .credentialUnreadable:
            return ("The bundled vrc helper is missing from the app bundle. "
                    + "Reinstall with ./Scripts/build-app.sh --install.", true)
        case .configured:
            switch state.cloud.health {
            case .healthy, .notConfigured:
                return nil
            case .degraded(let detail), .unreachable(let detail):
                return (detail, true)
            }
        }
    }

    private var headline: String {
        switch state.cloud.health {
        case .healthy: return "Connected"
        case .degraded: return "Connected — reporting problems"
        case .unreachable: return "Cannot reach the service"
        case .notConfigured:
            if case .insecureEndpoint = state.cloudConfiguration {
                return "Endpoint refused — not https"
            }
            return "Not configured"
        }
    }

    // MARK: - Imports

    private func importCard(_ status: CloudSyncClient.Status) -> some View {
        Card(title: "Last successful import") {
            Text(status.lastSuccessfulImport.isEmpty
                 ? "The service reports no successful import yet."
                 : status.lastSuccessfulImport)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)

            if status.failingSources.isEmpty && status.staleSources.isEmpty {
                Label("No failing or stale sources", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
            }
            ForEach(status.failingSources.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                Label("\(entry.key) failed: \(entry.value)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            ForEach(status.staleSources.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                Label("\(entry.key) is stale: \(entry.value)", systemImage: "clock.badge.xmark")
                    .font(.caption).foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func countsCard(_ status: CloudSyncClient.Status) -> some View {
        Card(title: "In the cloud database") {
            HStack(alignment: .top, spacing: 26) {
                Tally("Events", status.liveSourceEvents)
                Tally("Approved", status.approvedDecisions)
                Tally("Published", status.publishedDecisions)
                Tally("Conflicts", status.openConflicts,
                      tint: status.openConflicts > 0 ? .orange : nil)
            }
            HStack(spacing: 7) {
                Text(status.outboundEnabled ? "Outbound publishing ON" : "Outbound publishing off")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(
                        (status.outboundEnabled ? Color.orange : Color.green).opacity(0.15)))
                    .foregroundStyle(status.outboundEnabled ? Color.orange : Color.green)
                // Reported by the service, never inferred from a clean request.
                Text(status.remoteSynchronised
                     ? "Platforms confirmed"
                     : "Platform confirmation unknown")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Intervals

    private var intervalsCard: some View {
        Card(title: "Cloud availability") {
            if state.cloud.intervals.isEmpty {
                Text(state.cloud.status == nil
                     ? "Refresh to read what the service has blocked."
                     : "The service reports no blocking intervals.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let cloudOnly = Set(state.cloudOnlyIntervals.map(Self.key))
                ForEach(Array(state.cloud.intervals.enumerated()), id: \.offset) { pair in
                    let interval = pair.element
                    HStack(alignment: .top, spacing: 9) {
                        // Source is stated on every row. Cloud and local rows
                        // never share a style, so neither can be mistaken for
                        // the other.
                        Text("AWS")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(Color.purple.opacity(0.16)))
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(CloudInterval.describe(interval))
                                .font(.system(size: 13))
                            Text("\(interval.source) · \(interval.basis)"
                                 + " · \(CloudInterval.nights(interval)) night"
                                 + (CloudInterval.nights(interval) == 1 ? "" : "s"))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if cloudOnly.contains(Self.key(interval)) {
                            Text("not on this Mac")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        } else {
                            Text("also local")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                    Divider()
                }
                Text("\(state.events.count) event"
                     + (state.events.count == 1 ? "" : "s")
                     + " in the local database for comparison.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private static func key(_ interval: CloudSyncClient.BlockingInterval) -> String {
        "\(interval.property)|\(interval.from)|\(interval.to)|\(interval.source)"
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

/// A health dot whose colour is derived from the service's own report.
struct CloudHealthDot: View {
    let health: CloudSnapshot.Health

    var body: some View {
        Image(systemName: symbol).foregroundStyle(tint)
    }

    private var symbol: String {
        switch health {
        case .healthy: return "checkmark.icloud.fill"
        case .degraded: return "exclamationmark.icloud.fill"
        case .unreachable: return "xmark.icloud.fill"
        case .notConfigured: return "icloud.slash"
        }
    }

    private var tint: Color {
        switch health {
        case .healthy: return .green
        case .degraded: return .orange
        case .unreachable: return .red
        case .notConfigured: return .secondary
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }
}

private struct Tally: View {
    let label: String
    let value: Int
    var tint: Color?

    init(_ label: String, _ value: Int, tint: Color? = nil) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(tint ?? .primary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
