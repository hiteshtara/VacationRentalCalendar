import SwiftUI
import VRCCore

/// Where each destination stands — and, as importantly, what is not known.
struct SyncStatusView: View {
    @EnvironmentObject var state: AppState
    @State private var inspecting: RentalPlatform?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DeliveryWarningBanner()
                gate
                ForEach(state.syncStates) { syncState in
                    destinationCard(syncState)
                }
                Divider()
                history
                Spacer(minLength: 20)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $inspecting) { platform in
            FeedInspector(destination: platform).environmentObject(state)
        }
    }

    private var gate: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: OutboundSyncGate.isEnabled ? "lock.open.fill" : "lock.fill")
                .foregroundStyle(OutboundSyncGate.isEnabled ? .orange : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(OutboundSyncGate.isEnabled
                     ? "Publishing is ON"
                     : "Publishing is switched off")
                    .font(.caption.weight(.semibold))
                Text(OutboundSyncGate.explanation)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill((OutboundSyncGate.isEnabled ? Color.orange : Color.green).opacity(0.09)))
    }

    private func destinationCard(_ syncState: DestinationSyncState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PlatformBadge(platform: syncState.destination)
                Spacer()
                Button("Inspect feed") { inspecting = syncState.destination }
                    .controlSize(.small)
            }

            Text(syncState.headline)
                .font(.subheadline.weight(.medium))

            HStack(spacing: 16) {
                counter("Approved", syncState.approvedCount, .green)
                counter("Published", syncState.publishedCount, .blue)
                counter("Awaiting platform", syncState.awaitingRefreshCount, .orange)
                counter("Confirmed", syncState.verifiedCount, .green)
            }

            // The distinction the brief insists on, stated every time.
            Text("Publishing a file is not proof \(syncState.destination.displayName) imported "
                + "it. \(syncState.capability.latencyNote)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(PlatformAdapters.adapter(for: syncState.destination)
                .verificationStrategy().note)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let generated = syncState.lastGeneratedAt {
                Text("Feed last generated \(DayMath.mediumString(generated))")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
    }

    private func counter(_ title: String, _ value: Int, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? tint : .secondary)
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Audit history", systemImage: "list.bullet.rectangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if state.auditEntries.isEmpty {
                Text("Nothing recorded yet.").font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(state.auditEntries.prefix(40)) { entry in
                    Text(entry.line)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The exact feed a destination would be served, entry by entry, with reasons.
struct FeedInspector: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let destination: RentalPlatform
    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PlatformBadge(platform: destination)
                Text("would receive").foregroundStyle(.secondary)
                Spacer()
                Toggle("Raw .ics", isOn: $showRaw).toggleStyle(.switch).controlSize(.small)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            if let feed = state.destinationFeed(for: destination) {
                if showRaw {
                    ScrollView {
                        Text(CalendarFeedGenerator().makeICS(feed))
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            summary(feed)
                            column("Included", feed.included, .green)
                            column("Held back", feed.excluded, .secondary)
                        }
                        .padding(12)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No feed", systemImage: "doc",
                    description: Text("Choose a property first.")
                )
            }

            Divider()
            HStack(spacing: 7) {
                Image(systemName: "lock.fill").foregroundStyle(.green)
                Text("This is generated on your Mac for inspection. It is not served anywhere.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        }
        .frame(width: 640, height: 560)
    }

    private func summary(_ feed: DestinationFeed) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading) {
                Text("\(feed.included.count)").font(.title2.weight(.semibold)).monospacedDigit()
                Text("entries, \(feed.includedNights) nights")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading) {
                Text("\(feed.excluded.count)").font(.title2.weight(.semibold))
                    .monospacedDigit().foregroundStyle(.secondary)
                Text("held back").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func column(
        _ title: String, _ entries: [FeedEntryDecision], _ tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint)
            if entries.isEmpty {
                Text("Nothing.").font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("\(DayMath.mediumString(entry.startDay)) → "
                            + "\(DayMath.mediumString(entry.endDay))")
                            .font(.caption.monospacedDigit())
                        Text(entry.origin == .availabilityDecision ? "your block" : "source")
                            .font(.system(size: 9))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                        Spacer()
                    }
                    Text(entry.reason)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3)))
            }
        }
    }
}
