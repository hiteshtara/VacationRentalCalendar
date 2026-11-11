import SwiftUI
import VRCCore

/// What a plan would do, shown before anything is written.
struct AvailabilityPreviewView: View {
    let preview: VRCCore.AvailabilityPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Before anything is saved", systemImage: "eye")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(preview.nightsDescription)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(preview.lines) { line in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        PlatformBadge(platform: line.destination, style: .compact)
                        Text(line.action.displayName)
                            .font(.caption.weight(.medium))
                        Spacer()
                        if !line.canProceed {
                            Label("Refused", systemImage: "nosign")
                                .font(.caption2).foregroundStyle(.red)
                        } else if line.validation.needsReview {
                            Label("Check first", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2).foregroundStyle(.orange)
                        } else {
                            Label("No conflicts", systemImage: "checkmark.circle")
                                .font(.caption2).foregroundStyle(.green)
                        }
                    }

                    ForEach(line.validation.violations) { violation in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: icon(for: violation.severity))
                                .font(.system(size: 9))
                                .foregroundStyle(color(for: violation.severity))
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(violation.message)
                                    .font(.caption2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("\(violation.rule.rawValue) · \(violation.rule.title)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    ForEach(line.validation.notes, id: \.self) { note in
                        Text(note)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(line.canProceed
                              ? Color.secondary.opacity(0.06)
                              : Color.red.opacity(0.07))
                )
            }
        }
    }

    private func icon(for severity: RuleViolation.Severity) -> String {
        switch severity {
        case .blocking: return "nosign"
        case .requiresReview: return "exclamationmark.triangle.fill"
        case .advisory: return "info.circle"
        }
    }

    private func color(for severity: RuleViolation.Severity) -> Color {
        switch severity {
        case .blocking: return .red
        case .requiresReview: return .orange
        case .advisory: return .secondary
        }
    }
}
