import SwiftUI
import VRCCore

/// One visual rule runs through the whole app, and it mirrors the app icon:
///
/// **Filled means genuinely blocked. Outlined means still sellable.**
///
/// So a confirmed reservation is a solid block, and an Airbnb cancellation
/// block — the thing this app exists to protect — is drawn as an outline,
/// because those nights are still yours to sell.
enum Theme {
    static func color(for kind: BlockKind) -> Color {
        switch kind {
        case .confirmedReservation: return Color(red: 0.14, green: 0.66, blue: 0.42)
        case .ownerBlock: return Color(red: 0.24, green: 0.43, blue: 0.94)
        case .maintenanceBlock: return Color(red: 0.93, green: 0.58, blue: 0.13)
        case .cancellationBlock: return Color(red: 0.72, green: 0.29, blue: 0.84)
        case .unknownUnavailable: return Color(red: 0.55, green: 0.57, blue: 0.62)
        }
    }

    /// True when the dates remain sellable elsewhere, and so are drawn hollow.
    static func isSellable(_ classification: EventClassification) -> Bool {
        !classification.kind.describesGenuineUnavailability || classification.needsReview
    }

    static func symbol(for kind: BlockKind) -> String {
        switch kind {
        case .confirmedReservation: return "person.fill.checkmark"
        case .ownerBlock: return "house.fill"
        case .maintenanceBlock: return "wrench.and.screwdriver.fill"
        case .cancellationBlock: return "arrow.uturn.backward.circle.fill"
        case .unknownUnavailable: return "questionmark.circle.fill"
        }
    }

    static func color(for platform: RentalPlatform) -> Color {
        switch platform {
        case .airbnb: return Color(red: 1.0, green: 0.35, blue: 0.37)
        case .vrbo: return Color(red: 0.24, green: 0.43, blue: 0.94)
        case .bookingCom: return Color(red: 0.0, green: 0.21, blue: 0.50)
        case .other: return .secondary
        }
    }
}

/// A coloured chip for one event, hollow when the dates stay sellable.
struct EventChip: View {
    let item: ClassifiedEvent
    var compact = false

    private var tint: Color { Theme.color(for: item.classification.kind) }
    private var sellable: Bool { Theme.isSellable(item.classification) }

    var body: some View {
        HStack(spacing: 4) {
            if !compact {
                Image(systemName: Theme.symbol(for: item.classification.kind))
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(label)
                .font(.system(size: compact ? 9 : 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, compact ? 4 : 6)
        .padding(.vertical, compact ? 1 : 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(sellable ? Color.clear : tint.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(tint, style: StrokeStyle(lineWidth: sellable ? 1.2 : 0,
                                                       dash: sellable ? [3, 2] : []))
        )
        .foregroundStyle(sellable ? tint : .white)
    }

    private var label: String {
        let platform = item.event.platform.shortTag
        if compact { return platform }
        return "\(platform) · \(item.classification.kind.displayName)"
    }
}

/// Explains the fill-versus-outline rule wherever the calendar is shown.
struct LegendBar: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(BlockKind.allCases) { kind in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(kind.describesGenuineUnavailability
                              ? Theme.color(for: kind) : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(
                                    Theme.color(for: kind),
                                    style: StrokeStyle(
                                        lineWidth: kind.describesGenuineUnavailability ? 0 : 1.2,
                                        dash: kind.describesGenuineUnavailability ? [] : [3, 2]
                                    )
                                )
                        )
                        .frame(width: 14, height: 11)
                    Text(kind.displayName).font(.caption2)
                }
            }
            Spacer()
            Text("Outlined = still sellable elsewhere")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.4))
    }
}
