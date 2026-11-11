import SwiftUI
import VRCCore

/// One rule runs through the whole interface, and it is the same rule as the
/// app icon:
///
/// **Solid means these nights are genuinely gone. Hollow means they are still
/// yours to sell.**
///
/// A test (`the hollow-bar rule matches what is actually exportable`) checks
/// that the rule agrees with the export gate, so the calendar cannot drift into
/// claiming something the policy would not do.
///
/// Two structural devices carry two different facts, and they are kept separate
/// on purpose: the **bar's colour and fill** say what the classification is, and
/// a **cap on its leading edge** says which platform it came from.
enum Theme {

    // MARK: Classification

    static func color(for status: EventDisplayStatus) -> Color {
        switch status {
        case .confirmed: return Color(red: 0.11, green: 0.52, blue: 0.35)
        case .ownerBlock: return Color(red: 0.24, green: 0.36, blue: 0.80)
        case .maintenance: return Color(red: 0.71, green: 0.45, blue: 0.10)
        case .cancellationBlock: return Color(red: 0.71, green: 0.29, blue: 0.82)
        case .platformRestriction: return Color(red: 0.38, green: 0.42, blue: 0.55)
        case .needsReview: return Color(red: 0.88, green: 0.54, blue: 0.12)
        case .unknown: return Color(red: 0.42, green: 0.45, blue: 0.50)
        }
    }

    static func color(for kind: BlockKind) -> Color {
        switch kind {
        case .confirmedReservation: return color(for: EventDisplayStatus.confirmed)
        case .ownerBlock: return color(for: EventDisplayStatus.ownerBlock)
        case .maintenanceBlock: return color(for: EventDisplayStatus.maintenance)
        case .cancellationBlock: return color(for: EventDisplayStatus.cancellationBlock)
        case .platformRestriction: return color(for: EventDisplayStatus.platformRestriction)
        case .unknownUnavailable: return color(for: EventDisplayStatus.unknown)
        }
    }

    // MARK: Platform

    static func color(for platform: RentalPlatform) -> Color {
        switch platform {
        case .airbnb: return Color(red: 1.00, green: 0.35, blue: 0.37)
        case .vrbo: return Color(red: 0.18, green: 0.44, blue: 0.93)
        case .bookingCom: return Color(red: 0.00, green: 0.21, blue: 0.50)
        case .other: return Color(red: 0.45, green: 0.45, blue: 0.48)
        }
    }

    /// A distinct mark per platform, so they are told apart without relying on
    /// colour alone.
    static func glyph(for platform: RentalPlatform) -> String {
        switch platform {
        case .airbnb: return "a.circle.fill"
        case .vrbo: return "v.circle.fill"
        case .bookingCom: return "b.circle.fill"
        case .other: return "questionmark.circle.fill"
        }
    }
}

// MARK: - Platform indicator

/// Platform identity, used wherever an event is named.
struct PlatformBadge: View {
    let platform: RentalPlatform
    var style: Style = .full

    enum Style { case full, compact, dot }

    var body: some View {
        switch style {
        case .dot:
            Circle()
                .fill(Theme.color(for: platform))
                .frame(width: 8, height: 8)
                .accessibilityLabel(platform.displayName)

        case .compact:
            Text(platform.shortTag)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Theme.color(for: platform)))
                .accessibilityLabel(platform.displayName)

        case .full:
            HStack(spacing: 4) {
                Image(systemName: Theme.glyph(for: platform))
                    .font(.system(size: 11))
                Text(platform.displayName)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.color(for: platform))
        }
    }
}

// MARK: - Classification indicator

struct StatusBadge: View {
    let status: EventDisplayStatus
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbolName)
                .font(.system(size: compact ? 8 : 10, weight: .bold))
            if !compact {
                Text(status.label).font(.system(size: 11, weight: .medium))
            }
        }
        .padding(.horizontal, compact ? 4 : 7)
        .padding(.vertical, compact ? 2 : 3)
        .foregroundStyle(status.isSellableElsewhere ? Theme.color(for: status) : .white)
        .background(
            Capsule()
                .fill(status.isSellableElsewhere
                      ? Theme.color(for: status).opacity(0.12)
                      : Theme.color(for: status))
        )
        .overlay(
            Capsule().strokeBorder(
                Theme.color(for: status),
                style: StrokeStyle(
                    lineWidth: status.isSellableElsewhere ? 1 : 0,
                    dash: status.isSellableElsewhere ? [3, 2] : []
                )
            )
        )
    }
}

// MARK: - The calendar bar

/// A continuous date-range bar. One bar per stay, however many days it covers.
struct EventBar: View {
    let item: ClassifiedEvent
    /// False when the stay continues in from the previous week, so the left
    /// edge is squared off and the platform cap is omitted.
    var isStart = true
    /// False when the stay continues into the next week.
    var isEnd = true
    var isSelected = false
    var height: CGFloat = 19

    private var status: EventDisplayStatus { item.displayStatus }
    private var tint: Color { Theme.color(for: status) }
    private var hollow: Bool { status.isSellableElsewhere }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: isStart ? 4 : 0,
            bottomLeadingRadius: isStart ? 4 : 0,
            bottomTrailingRadius: isEnd ? 4 : 0,
            topTrailingRadius: isEnd ? 4 : 0
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            // The platform cap. Only on the real beginning of a stay, so a bar
            // continuing from last week reads as a continuation.
            if isStart {
                Rectangle()
                    .fill(Theme.color(for: item.event.platform))
                    .frame(width: 3)
            }

            HStack(spacing: 4) {
                Image(systemName: status.symbolName)
                    .font(.system(size: 8, weight: .bold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 5)
            .padding(.trailing, 4)
        }
        .frame(height: height)
        .foregroundStyle(hollow ? tint : .white)
        .background(shape.fill(hollow ? tint.opacity(0.10) : tint))
        .overlay(
            shape.strokeBorder(
                tint,
                style: StrokeStyle(
                    lineWidth: hollow ? 1 : 0,
                    dash: hollow ? [3, 2] : []
                )
            )
        )
        .overlay(
            shape.strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
        )
        .clipShape(shape)
        .contentShape(Rectangle())
        .help("\(item.event.platform.displayName) · \(status.label) · "
            + "\(DayMath.mediumString(item.event.checkIn)) to "
            + "\(DayMath.mediumString(item.event.checkOut))")
    }

    private var label: String {
        isStart
            ? "\(item.event.platform.shortTag)  \(status.label)"
            : status.label
    }
}

// MARK: - Legend

/// Explains the fill-versus-outline rule. Shown under the calendar because the
/// rule is the one thing a new user must learn to read this screen.
struct LegendBar: View {
    var body: some View {
        HStack(spacing: 16) {
            ForEach(EventDisplayStatus.allCases.filter { $0 != .unknown }) { status in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(status.isSellableElsewhere
                              ? Theme.color(for: status).opacity(0.12)
                              : Theme.color(for: status))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3).strokeBorder(
                                Theme.color(for: status),
                                style: StrokeStyle(
                                    lineWidth: status.isSellableElsewhere ? 1 : 0,
                                    dash: status.isSellableElsewhere ? [3, 2] : []
                                )
                            )
                        )
                        .frame(width: 16, height: 11)
                    Text(status.label).font(.caption2)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                ForEach(RentalPlatform.allCases.filter { $0 != .other }) { platform in
                    HStack(spacing: 3) {
                        Rectangle().fill(Theme.color(for: platform)).frame(width: 3, height: 11)
                        Text(platform.displayName).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Dashed outline: still on sale elsewhere")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.35))
    }
}
