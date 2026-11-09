import SwiftUI
import VRCCore

struct ConflictsView: View {
    @EnvironmentObject var state: AppState

    private var doubleBookings: [ReservationConflict] {
        state.visibleConflicts.filter { $0.severity == .doubleBooking }
    }
    private var overlaps: [ReservationConflict] {
        state.visibleConflicts.filter { $0.severity == .overlappingBlocks }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if state.visibleConflicts.isEmpty {
                    ContentUnavailableView(
                        "No overlapping dates",
                        systemImage: "checkmark.shield",
                        description: Text("No two reservations claim the same unit at the same time.")
                    )
                    .padding(.top, 60)
                } else {
                    if !doubleBookings.isEmpty {
                        section(
                            title: "Double bookings",
                            subtitle: "Two confirmed reservations on the same unit. Fix these with "
                                + "the platforms directly — this app cannot change availability.",
                            conflicts: doubleBookings,
                            urgent: true
                        )
                    }
                    if !overlaps.isEmpty {
                        section(
                            title: "Overlapping blocks",
                            subtitle: "Ranges that overlap where at least one side is not a "
                                + "confirmed booking. Usually stacked or duplicated blocks, and "
                                + "normally harmless.",
                            conflicts: overlaps,
                            urgent: false
                        )
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(
        title: String, subtitle: String, conflicts: [ReservationConflict], urgent: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: urgent ? "exclamationmark.triangle.fill" : "rectangle.on.rectangle")
                    .foregroundStyle(urgent ? .red : .secondary)
                Text(title).font(.headline)
                Text("\(conflicts.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(urgent ? Color.red.opacity(0.18) : Color.secondary.opacity(0.15)))
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(conflicts) { conflict in
                ConflictCard(conflict: conflict, urgent: urgent)
            }
        }
    }
}

private struct ConflictCard: View {
    @EnvironmentObject var state: AppState
    let conflict: ReservationConflict
    let urgent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(conflict.dateRangeDescription)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(conflict.overlapNights) night\(conflict.overlapNights == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if conflict.acknowledged {
                    Label("Acknowledged", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                side(conflict.sideA)
                Image(systemName: "arrow.left.and.right")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 14)
                side(conflict.sideB)
            }
            HStack {
                Spacer()
                Button(conflict.acknowledged ? "Unacknowledge" : "Acknowledge") {
                    conflict.acknowledged
                        ? state.unacknowledge(conflict: conflict)
                        : state.acknowledge(conflict: conflict)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(urgent && !conflict.acknowledged
                      ? Color.red.opacity(0.06) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(urgent && !conflict.acknowledged
                              ? Color.red.opacity(0.35) : Color.secondary.opacity(0.2))
        )
    }

    private func side(_ side: ConflictSide) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(Theme.color(for: side.platform)).frame(width: 7, height: 7)
                Text(side.platform.displayName).font(.caption.weight(.semibold))
            }
            Text(side.summary).font(.system(size: 12)).lineLimit(1)
            Text("\(DayMath.mediumString(side.checkIn)) → \(DayMath.mediumString(side.checkOut))")
                .font(.caption2).foregroundStyle(.secondary)
            Text(side.listingLabel).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
