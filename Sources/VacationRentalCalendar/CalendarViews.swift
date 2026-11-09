import SwiftUI
import VRCCore

// MARK: - Month

struct MonthGridView: View {
    @EnvironmentObject var state: AppState

    private var monthStart: Date {
        let calendar = DayMath.utcCalendar
        let components = calendar.dateComponents([.year, .month], from: state.anchorDate)
        return calendar.date(from: components) ?? state.anchorDate
    }

    /// Six weeks starting on the Sunday on or before the first of the month, so
    /// the grid never reflows as the user pages through months.
    private var days: [Date] {
        let calendar = DayMath.utcCalendar
        let weekday = calendar.component(.weekday, from: monthStart)
        let start = DayMath.adding(days: -(weekday - 1), to: monthStart)
        return (0..<42).map { DayMath.adding(days: $0, to: start) }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 7)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) { name in
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 1) {
                    ForEach(days, id: \.timeIntervalSince1970) { day in
                        DayCell(day: day, isInMonth: isInMonth(day))
                    }
                }
                .padding(1)
            }
            LegendBar()
        }
    }

    private func isInMonth(_ day: Date) -> Bool {
        let calendar = DayMath.utcCalendar
        return calendar.component(.month, from: day) == calendar.component(.month, from: monthStart)
    }
}

private struct DayCell: View {
    @EnvironmentObject var state: AppState
    let day: Date
    let isInMonth: Bool

    private var items: [ClassifiedEvent] { state.events(on: day) }

    private var isToday: Bool {
        DayMath.utcMidnight(day) == DayMath.utcMidnight(Date())
    }

    private var dayNumberColor: Color {
        if isToday { return .white }
        return isInMonth ? .primary : Color.secondary.opacity(0.5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(DayMath.utcCalendar.component(.day, from: day))")
                    .font(.system(size: 11, weight: isToday ? .bold : .regular))
                    .foregroundStyle(dayNumberColor)
                    .padding(.horizontal, isToday ? 5 : 0)
                    .padding(.vertical, isToday ? 1 : 0)
                    .background(Capsule().fill(isToday ? Color.accentColor : .clear))
                Spacer()
                if items.contains(where: { $0.classification.needsReview }) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                }
            }

            ForEach(items.prefix(3)) { item in
                EventChip(item: item, compact: true)
                    .onTapGesture {
                        state.selectedEventKey = item.event.eventKey
                        state.selectedSection = .review
                    }
            }
            if items.count > 3 {
                Text("+\(items.count - 3) more")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(minHeight: 76, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .background(isInMonth ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
        .overlay(Rectangle().strokeBorder(.quaternary, lineWidth: 0.5))
    }
}

// MARK: - Week

struct WeekStripView: View {
    @EnvironmentObject var state: AppState

    private var weekDays: [Date] {
        let calendar = DayMath.utcCalendar
        let weekday = calendar.component(.weekday, from: state.anchorDate)
        let start = DayMath.adding(days: -(weekday - 1), to: state.anchorDate)
        return (0..<7).map { DayMath.adding(days: $0, to: start) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(weekDays, id: \.timeIntervalSince1970) { day in
                        WeekRow(day: day)
                    }
                }
                .padding(1)
            }
            LegendBar()
        }
    }
}

private struct WeekRow: View {
    @EnvironmentObject var state: AppState
    let day: Date

    private var items: [ClassifiedEvent] { state.events(on: day) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(weekdayName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(DayMath.mediumString(day)).font(.system(size: 13, weight: .medium))
            }
            .frame(width: 140, alignment: .leading)

            if items.isEmpty {
                Text("Open")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items) { item in
                        HStack(spacing: 8) {
                            EventChip(item: item)
                                .frame(width: 210)
                            Text(item.event.summary.isEmpty ? "(no title)" : item.event.summary)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.selectedEventKey = item.event.eventKey
                            state.selectedSection = .review
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(Rectangle().strokeBorder(.quaternary, lineWidth: 0.5))
    }

    private var weekdayName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = DayMath.utc
        formatter.dateFormat = "EEEE"
        return formatter.string(from: day)
    }
}

// MARK: - List

struct EventListView: View {
    @EnvironmentObject var state: AppState

    private var sorted: [ClassifiedEvent] {
        state.visibleEvents.sorted { $0.event.checkIn < $1.event.checkIn }
    }

    var body: some View {
        VStack(spacing: 0) {
            if sorted.isEmpty {
                ContentUnavailableView(
                    "No imported dates yet",
                    systemImage: "calendar.badge.plus",
                    description: Text("Add a calendar URL under Feeds, then choose Refresh.")
                )
            } else {
                Table(sorted) {
                    TableColumn("Check-in") { item in
                        Text(DayMath.mediumString(item.event.checkIn)).monospacedDigit()
                    }
                    .width(110)
                    TableColumn("Check-out") { item in
                        Text(DayMath.mediumString(item.event.checkOut)).monospacedDigit()
                    }
                    .width(110)
                    TableColumn("Nights") { item in
                        Text("\(item.event.nights)").monospacedDigit()
                    }
                    .width(55)
                    TableColumn("Platform") { item in
                        Text(item.event.platform.displayName)
                            .foregroundStyle(Theme.color(for: item.event.platform))
                    }
                    .width(90)
                    TableColumn("Classification") { item in
                        HStack(spacing: 6) {
                            EventChip(item: item).frame(width: 190)
                            if item.classification.needsReview {
                                Text("review").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                    .width(250)
                    TableColumn("Feed says") { item in
                        Text(item.event.summary.isEmpty ? "(no title)" : item.event.summary)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            LegendBar()
        }
    }
}
