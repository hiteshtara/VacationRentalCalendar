import SwiftUI
import VRCCore

/// One row of the editor: a platform, and what to do about it.
///
/// Each platform is chosen independently and nothing is pre-selected, because a
/// default here would be the app quietly deciding something on the owner's
/// behalf — which is the failure this whole project is built to avoid.
struct PlatformSelector: View {
    let platform: RentalPlatform
    let capability: PlatformCapability
    /// What the platform's own calendar currently says about these nights.
    let currentState: String
    @Binding var action: AvailabilityAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                PlatformBadge(platform: platform)
                Spacer()
                Text(currentState)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("", selection: $action) {
                Text("Choose…").tag(AvailabilityAction?.none)
                ForEach(AvailabilityAction.allCases) { option in
                    Text(option.displayName).tag(AvailabilityAction?.some(option))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let action {
                Text(explanation(for: action))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Not chosen. \(platform.displayName) is left exactly as it is.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(action == nil
                              ? Color.secondary.opacity(0.2)
                              : Theme.color(for: platform).opacity(0.5))
        )
    }

    private func explanation(for action: AvailabilityAction) -> String {
        switch action {
        case .block:
            return "These nights go into the feed \(platform.displayName) reads. "
                + capability.latencyNote
        case .unblock:
            return "Our block is withdrawn from that feed. Blocks \(platform.displayName) or you "
                + "created elsewhere are untouched, and a booked night is never reopened."
        case .leaveUnchanged:
            return "Recorded as a deliberate decision to do nothing here."
        }
    }
}
