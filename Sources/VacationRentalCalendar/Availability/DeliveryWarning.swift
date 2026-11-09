import SwiftUI
import VRCCore

/// The claim this app refuses to let a screen imply.
///
/// Placed at the top of the availability and sync screens rather than tucked
/// into a help page, because the misunderstanding it prevents — that blocking
/// dates here protects them immediately — is the one that costs money.
struct DeliveryWarningBanner: View {
    var destination: RentalPlatform = .vrbo
    var freshness: PublicationFreshness?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                        .font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SynchronisationHonesty.headline)
                            .font(.callout.weight(.semibold))
                            .multilineTextAlignment(.leading)
                        if let freshness {
                            Text(freshness.headline)
                                .font(.caption)
                                .foregroundStyle(freshness.isStale ? .orange : .secondary)
                        } else {
                            Text("Changes reach a platform on its schedule, not yours.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(SynchronisationHonesty.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let freshness {
                        Label(freshness.describeExposureAwake(), systemImage: "timer")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Label(freshness.offlineWarning, systemImage: "powersleep")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(SynchronisationHonesty.comparison)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 9)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 9).fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9).strokeBorder(Color.orange.opacity(0.35))
        )
    }
}
