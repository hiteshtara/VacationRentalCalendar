import SwiftUI
import VRCCore

/// Everything actually booked, and the three conflict categories.
///
/// Opens on what matters: whether anyone is double booked, then who is
/// staying. Blocks and restrictions live elsewhere.
struct ReservationsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                conflictSummary
                reservationList
                Spacer(minLength: 24)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Conflicts, by category

    private var conflictSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conflicts").font(.title3.weight(.semibold))

            HStack(spacing: 10) {
                ForEach(ConflictCategory.allCases) { category in
                    categoryTile(category)
                }
            }

            ForEach(ConflictCategory.allCases) { category in
                let items = state.findings(category)
                if !items.isEmpty {
                    categorySection(category, items)
                }
            }

            if !state.availabilityDifferences.isEmpty {
                differencesSection
            }

            if state.visibleFindings.isEmpty && state.availabilityDifferences.isEmpty {
                Label("Nothing overlaps and every platform agrees.",
                      systemImage: "checkmark.seal")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .padding(.vertical, 6)
            }
        }
    }

    private func categoryTile(_ category: ConflictCategory) -> some View {
        let count = category == .availabilityDiscrepancy
            ? state.availabilityDifferences.count
            : state.findings(category).count
        let tint: Color = category.isUrgent
            ? .red
            : (category == .unverifiedBookingConflict ? .orange : .secondary)

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: category.severitySymbol)
                    .font(.system(size: 11))
                    .foregroundStyle(count > 0 ? tint : Color.secondary.opacity(0.5))
                Text("\(count)")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(count > 0 ? tint : .secondary)
            }
            Text(category.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(count > 0 && category.isUrgent
                      ? Color.red.opacity(0.07)
                      : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(count > 0 && category.isUrgent
                              ? Color.red.opacity(0.35) : Color.secondary.opacity(0.15))
        )
    }

    private func categorySection(
        _ category: ConflictCategory, _ items: [ConflictFinding]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(category.title).font(.headline)
            Text(category.explanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(items) { finding in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(finding.dateRangeDescription)
                            .font(.system(size: 13, weight: .medium)).monospacedDigit()
                        Text("\(finding.nights) night\(finding.nights == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if finding.acknowledged {
                            Label("Seen", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                    HStack(alignment: .top, spacing: 14) {
                        side(finding.sideA, finding.verificationA)
                        side(finding.sideB, finding.verificationB)
                    }
                    Text(finding.detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if category.isUrgent || category == .unverifiedBookingConflict {
                        HStack {
                            Spacer()
                            Button(finding.acknowledged ? "Mark unseen" : "Mark as seen") {
                                finding.acknowledged
                                    ? state.unacknowledge(finding: finding)
                                    : state.acknowledge(finding: finding)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
            }
        }
    }

    private func side(_ value: ConflictSide, _ verification: ReservationVerification?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            PlatformBadge(platform: value.platform)
            Text(value.summary).font(.system(size: 12)).lineLimit(1)
            Text("\(DayMath.mediumString(value.checkIn)) → \(DayMath.mediumString(value.checkOut))")
                .font(.caption2).foregroundStyle(.secondary)
            if let verification {
                Text(verification.label)
                    .font(.system(size: 9))
                    .foregroundStyle(verification == .platformEvidenced ? .green : .orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var differencesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ConflictCategory.availabilityDiscrepancy.title).font(.headline)
            Text(ConflictCategory.availabilityDiscrepancy.explanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(state.availabilityDifferences.prefix(14)) { difference in
                HStack(spacing: 10) {
                    Text(DayMath.mediumString(difference.day))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .frame(width: 110, alignment: .leading)
                    ForEach([RentalPlatform.airbnb, .vrbo, .bookingCom]) { platform in
                        if let status = difference.statuses[platform] {
                            HStack(spacing: 3) {
                                PlatformBadge(platform: platform, style: .dot)
                                Text(status.shortLabel)
                                    .font(.caption2)
                                    .foregroundStyle(status == .unknown ? .orange : .secondary)
                            }
                            .frame(width: 92, alignment: .leading)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 3)
            }
            if state.availabilityDifferences.count > 14 {
                Text("and \(state.availabilityDifferences.count - 14) more dates")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Reservations

    private var reservationList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reservations").font(.title3.weight(.semibold))
            if state.reservations.isEmpty {
                Text("No confirmed reservations have been imported yet.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(state.reservations) { item in
                    Button {
                        state.select(eventKey: item.event.eventKey)
                    } label: {
                        HStack(spacing: 12) {
                            PlatformBadge(platform: item.event.platform)
                                .frame(width: 110, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(DayMath.mediumString(item.event.checkIn)) → "
                                    + "\(DayMath.mediumString(item.event.checkOut))")
                                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                                Text("\(item.event.nights) night"
                                    + "\(item.event.nights == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ReservationVerification.of(item).label)
                                .font(.caption2)
                                .foregroundStyle(
                                    ReservationVerification.of(item) == .platformEvidenced
                                        ? .green : .orange
                                )
                        }
                        .padding(11)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Feeds, sync history and filtered export, moved out of the main navigation.
struct SettingsPane: View {
    @EnvironmentObject var state: AppState
    @State private var tab: Tab = .feeds

    enum Tab: String, CaseIterable, Identifiable {
        case feeds, export, history, build
        var id: String { rawValue }
        var title: String {
            switch self {
            case .feeds: return "Calendar feeds"
            case .export: return "Filtered export"
            case .history: return "Sync history"
            case .build: return "This build"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 380)
            .padding(10)
            Divider()
            switch tab {
            case .feeds: FeedsView()
            case .export: ExportView()
            case .history: SyncHistoryView()
            case .build: BuildView()
            }
        }
    }
}
