import SwiftUI
import VRCCore

/// What one bar actually means, and whether anything is protecting it.
///
/// The panel exists because a classification alone is not actionable. Seeing
/// "unknown unavailable" tells you the app could not decide; it does not tell
/// you that the same nights are still for sale on two other platforms, which
/// is the fact that matters. So protection is assessed from the destinations'
/// own feeds and stated here — including the honest third answer, when a feed
/// is too stale for either verdict to be earned.
struct ReservationDetailPanel: View {
    let item: ClassifiedEvent
    let assessment: ProtectionAssessment
    let freshness: [FeedFreshness]
    var now: Date = Date()

    private var emphasis: CalendarEmphasis { CalendarVisibility.emphasis(for: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            rows
            Divider()
            protection
            Divider()
            Text(ProtectionAssessment.mechanismNote)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 330, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var header: some View {
        HStack(spacing: 6) {
            ChannelBadge(platform: item.event.platform)
            Text(item.event.platform.displayName)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(emphasis.label)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(TimelineView.style(for: emphasis).fill))
                .overlay(Capsule().strokeBorder(
                    TimelineView.style(for: emphasis).stroke, lineWidth: 1))
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 5) {
            field("Nights", CalendarVisibility.badge(for: item)
                .components(separatedBy: " · ").dropFirst().first ?? "")
            field("Occupied", "\(CalendarVisibility.occupiedNights(of: item.event).count) nights"
                + " — releases \(TimelineView.dayNumber(item.event.checkOut))")
            field("Classification", item.classification.kind.displayName
                + (item.classification.needsReview ? " · needs review" : ""))
            field("Decided by", item.classification.source == .manual
                ? "you, by hand" : "the app, automatically")
            field("Evidence", evidenceLine)
            field("Exportable", item.classification.kind.describesGenuineUnavailability
                ? "yes, if outbound were enabled"
                : "never — this kind is excluded by the allow-list")
        }
    }

    /// Why the app thinks what it thinks. A classification with no stated
    /// evidence is the thing that produced two wrong manual labels.
    private var evidenceLine: String {
        let rationale = item.classification.rationale
        if !rationale.isEmpty { return rationale }
        return item.classification.source == .manual
            ? "none recorded — this label was applied by hand"
            : "none"
    }

    private var protection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: assessment.isFullyProtected
                      ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(assessment.isFullyProtected ? .green : .orange)
                Text(assessment.isFullyProtected ? "Protected" : "Not protected")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(assessment.headline)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(assessment.destinations, id: \.platform.rawValue) { destination in
                HStack(spacing: 5) {
                    ChannelBadge(platform: destination.platform)
                    Text(Self.describe(destination.state))
                        .font(.system(size: 10))
                        .foregroundStyle(Self.tint(destination.state))
                }
            }
        }
    }

    static func describe(_ state: ProtectionAssessment.State) -> String {
        switch state {
        case .covered: return "these nights are held there"
        case .notCovered: return "STILL SELLABLE there"
        case .unverified(let reason): return "unverified — \(reason)"
        }
    }

    static func tint(_ state: ProtectionAssessment.State) -> Color {
        switch state {
        case .covered: return .green
        case .notCovered: return .orange
        case .unverified: return .secondary
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
