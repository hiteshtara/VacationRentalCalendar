import SwiftUI
import VRCCore

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
                            EventBar(item: item).frame(width: 210)
                            PlatformBadge(platform: item.event.platform, style: .compact)
                            Text(item.event.summary.isEmpty ? "(no title)" : item.event.summary)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { state.select(eventKey: item.event.eventKey) }
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
                Table(sorted, selection: Binding(
                    get: { state.selectedEventKey },
                    set: { key in if let key { state.select(eventKey: key) } }
                )) {
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
                        PlatformBadge(platform: item.event.platform)
                    }
                    .width(110)
                    TableColumn("Classification") { item in
                        StatusBadge(status: item.displayStatus)
                    }
                    .width(180)
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
