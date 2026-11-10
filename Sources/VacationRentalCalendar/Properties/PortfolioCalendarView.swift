import SwiftUI
import VRCCore

/// Every property's month on one screen, one strip per property.
///
/// Read-only, deliberately and completely: no selection that changes state, no
/// range dragging, no controls that could alter availability. It answers "what
/// is happening across everything this month?" — the question the per-property
/// calendar cannot answer without opening each one in turn.
///
/// A strip rather than a week grid, because the comparison that matters in a
/// portfolio is *between properties on the same date*, and a 7-column grid
/// repeated per property makes that comparison impossible.
///
/// All bar geometry comes from `CalendarLayout`, the same engine the
/// per-property month view uses, so continuity and checkout-exclusive spans
/// behave identically here and are covered by the same tests.
struct PortfolioCalendarView: View {
    @EnvironmentObject var state: AppState

    private var monthStart: Date {
        let calendar = DayMath.utcCalendar
        return calendar.date(from: calendar.dateComponents([.year, .month], from: state.anchorDate))
            ?? state.anchorDate
    }

    private var days: [Date] {
        let calendar = DayMath.utcCalendar
        let count = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        return (0..<count).map { DayMath.adding(days: $0, to: monthStart) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if state.portfolioRows.isEmpty {
                ContentUnavailableView(
                    "No properties", systemImage: "square.grid.2x2",
                    description: Text("Add a property to see it here."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        dayScale
                        ForEach(state.portfolioRows) { row in
                            PropertyStrip(
                                row: row,
                                days: days,
                                events: state.events.filter {
                                    $0.propertyID == row.property.id && $0.event.isActive
                                })
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(monthTitle).font(.title3.weight(.semibold))
                Text("\(state.portfolioRows.count) properties · read-only")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
            Button("Today") { state.anchorDate = DayMath.utcMidnight(Date()) }
                .controlSize(.small)
            Button { step(1) } label: { Image(systemName: "chevron.right") }
        }
        .padding(12)
    }

    private var dayScale: some View {
        GeometryReader { geometry in
            let width = geometry.size.width / CGFloat(max(1, days.count))
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    Text("\(DayMath.utcCalendar.component(.day, from: day))")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: width)
                }
            }
        }
        .frame(height: 12)
        .padding(.leading, PropertyStrip.labelWidth)
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: monthStart)
    }

    private func step(_ months: Int) {
        let calendar = DayMath.utcCalendar
        if let moved = calendar.date(byAdding: .month, value: months, to: monthStart) {
            state.anchorDate = moved
        }
    }
}

private struct PropertyStrip: View {
    static let labelWidth: CGFloat = 132
    let row: PortfolioRow
    let days: [Date]
    let events: [ClassifiedEvent]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.property.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1).truncationMode(.tail)
                Text("\(row.connectedCount)/\(row.listingCount) connected")
                    .font(.system(size: 8))
                    .foregroundStyle(row.troubledCount > 0 ? .orange : .secondary)
            }
            .frame(width: Self.labelWidth, alignment: .leading)

            GeometryReader { geometry in
                let width = geometry.size.width / CGFloat(max(1, days.count))
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.07))
                    ForEach(bars) { bar in
                        if let item = events.first(where: { $0.event.eventKey == bar.eventKey }) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.color(for: item.event.platform).opacity(
                                    item.classification.kind == .confirmedReservation ? 0.85 : 0.45))
                                .frame(width: max(2, width * CGFloat(bar.columnSpan) - 2),
                                       height: 14)
                                .offset(x: width * CGFloat(bar.startColumn) + 1,
                                        y: CGFloat(bar.lane) * 16 + 3)
                                .help(barDescription(item))
                        }
                    }
                }
            }
            .frame(height: CGFloat(max(1, laneCount)) * 16 + 6)
        }
    }

    /// Geometry comes from `CalendarLayout.monthStrip`, the same core engine
    /// the week grid uses. Nothing about lanes or clipping is decided here.
    private var bars: [MonthStripBar] {
        CalendarLayout.monthStrip(
            monthStart: days.first ?? Date(), dayCount: days.count, events: events)
    }

    private var laneCount: Int { (bars.map(\.lane).max() ?? 0) + 1 }

    private func barDescription(_ event: ClassifiedEvent) -> String {
        "\(event.event.platform.displayName) · \(event.classification.kind.displayName)\n"
            + "\(DayMath.mediumString(event.event.checkIn)) → "
            + "\(DayMath.mediumString(event.event.checkOut)) (checkout exclusive)"
    }
}
