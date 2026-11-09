import SwiftUI
import VRCCore

/// The month grid.
///
/// A stay is drawn once, as a single bar spanning the nights it occupies,
/// rather than as the same label repeated in every day cell. The arithmetic for
/// that — which columns, which stacked lane, where to cap the ends — lives in
/// `CalendarLayout` in the core, where it is tested.
struct MonthBarsView: View {
    @EnvironmentObject var state: AppState

    private let dayNumberHeight: CGFloat = 20
    private let barHeight: CGFloat = 19
    private let barGap: CGFloat = 2
    private let maxLanes = 4

    private var weekStarts: [Date] { CalendarLayout.weekStarts(containing: state.anchorDate) }

    private var monthNumber: Int {
        DayMath.utcCalendar.component(.month, from: state.anchorDate)
    }

    var body: some View {
        VStack(spacing: 0) {
            weekdayHeader
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(weekStarts, id: \.timeIntervalSince1970) { weekStart in
                        WeekBarRow(
                            weekStart: weekStart,
                            monthNumber: monthNumber,
                            dayNumberHeight: dayNumberHeight,
                            barHeight: barHeight,
                            barGap: barGap,
                            maxLanes: maxLanes
                        )
                    }
                }
            }
            LegendBar()
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"],
                    id: \.self) { name in
                Text(name.prefix(3))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct WeekBarRow: View {
    @EnvironmentObject var state: AppState
    let weekStart: Date
    let monthNumber: Int
    let dayNumberHeight: CGFloat
    let barHeight: CGFloat
    let barGap: CGFloat
    let maxLanes: Int

    private var days: [Date] {
        (0..<7).map { DayMath.adding(days: $0, to: weekStart) }
    }

    private var layout: WeekLayout {
        CalendarLayout.layout(
            weekStart: weekStart, events: state.visibleEvents, maxLanes: maxLanes
        )
    }

    private var overflow: Int {
        CalendarLayout.overflowCount(
            weekStart: weekStart, events: state.visibleEvents, maxLanes: maxLanes
        )
    }

    private var rowHeight: CGFloat {
        let lanes = max(1, layout.laneCount)
        return dayNumberHeight + CGFloat(lanes) * (barHeight + barGap) + 10
            + (overflow > 0 ? 14 : 0)
    }

    var body: some View {
        GeometryReader { geometry in
            let columnWidth = geometry.size.width / 7

            ZStack(alignment: .topLeading) {
                // Day cells: backgrounds, borders and numbers only. No event
                // content lives here, which is what lets a bar cross them.
                HStack(spacing: 0) {
                    ForEach(days, id: \.timeIntervalSince1970) { day in
                        DayBackground(
                            day: day,
                            isInMonth: DayMath.utcCalendar.component(.month, from: day) == monthNumber,
                            isSelected: state.isDayInSelection(day),
                            height: rowHeight
                        )
                        .frame(width: columnWidth)
                        .onTapGesture { state.selectDay(day) }
                    }
                }

                // Bars, laid over the cells.
                VStack(alignment: .leading, spacing: barGap) {
                    ForEach(0..<max(1, layout.laneCount), id: \.self) { lane in
                        ZStack(alignment: .topLeading) {
                            // Keeps the lane's height even when it is empty.
                            Color.clear.frame(height: barHeight)
                            ForEach(layout.segments(inLane: lane), id: \.id) { segment in
                                if let item = state.event(for: segment.eventKey) {
                                    EventBar(
                                        item: item,
                                        isStart: segment.isStart,
                                        isEnd: segment.isEnd,
                                        isSelected: state.selectedEventKey == segment.eventKey,
                                        height: barHeight
                                    )
                                    .frame(width: columnWidth * CGFloat(segment.columnSpan) - 3)
                                    .offset(x: columnWidth * CGFloat(segment.startColumn) + 1.5)
                                    .onTapGesture { state.select(eventKey: segment.eventKey) }
                                }
                            }
                        }
                    }
                    if overflow > 0 {
                        Text("+\(overflow) more")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 5)
                    }
                }
                .padding(.top, dayNumberHeight)
            }
        }
        .frame(height: rowHeight)
    }
}

private struct DayBackground: View {
    let day: Date
    let isInMonth: Bool
    var isSelected = false
    let height: CGFloat

    private var isToday: Bool {
        DayMath.utcMidnight(day) == DayMath.utcMidnight(Date())
    }

    private var dayNumber: Int {
        DayMath.utcCalendar.component(.day, from: day)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(dayNumber)")
                    .font(.system(size: 11, weight: isToday ? .bold : .regular))
                    .foregroundStyle(numberColor)
                    .padding(.horizontal, isToday ? 5 : 0)
                    .padding(.vertical, isToday ? 1 : 0)
                    .background(Capsule().fill(isToday ? Color.accentColor : .clear))
                Spacer()
            }
            .padding(.horizontal, 5)
            .padding(.top, 3)
            Spacer(minLength: 0)
        }
        .frame(height: height, alignment: .top)
        .background(isSelected
                    ? Color.accentColor.opacity(0.14)
                    : (isInMonth
                       ? Color(nsColor: .controlBackgroundColor)
                       : Color(nsColor: .windowBackgroundColor)))
        .overlay(Rectangle().strokeBorder(
            isSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.18),
            lineWidth: isSelected ? 1 : 0.5
        ))
        .contentShape(Rectangle())
    }

    private var numberColor: Color {
        if isToday { return .white }
        return isInMonth ? .primary : Color.secondary.opacity(0.45)
    }
}

/// Shown above the calendar when a feed sent nothing that could identify a
/// booking. Says so once per feed rather than on every affected event.
struct FeedWarningBanner: View {
    @EnvironmentObject var state: AppState
    @State private var isExpanded = false

    private var warnings: [FeedDiagnostic] { state.uninformativeFeeds }

    var body: some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(headline)
                            .font(.caption.weight(.medium))
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(warnings) { diagnostic in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    PlatformBadge(platform: diagnostic.platform, style: .compact)
                                    Text(diagnostic.listingLabel)
                                        .font(.caption2.weight(.medium))
                                }
                                Text(diagnostic.warning ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Button("Decide them now") { state.selectedSection = .review }
                            .font(.caption)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.09))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var headline: String {
        let nights = warnings.reduce(0) { $0 + $1.nightsAwaitingDecision }
        let feeds = warnings.map { $0.platform.displayName }.joined(separator: " and ")
        return "\(feeds) sent no detail that identifies a booking — "
            + "\(nights) night\(nights == 1 ? "" : "s") waiting on your decision"
    }
}


/// Appears over the calendar once nights are selected, offering the one thing
/// the owner is likely to want next.
struct RangeSelectionBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.selectedNights > 0, let range = state.selectedRange {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.checkmark")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(state.selectedNights) night"
                        + "\(state.selectedNights == 1 ? "" : "s") selected")
                        .font(.caption.weight(.medium))
                    Text("\(DayMath.mediumString(range.start)) to "
                        + "\(DayMath.mediumString(DayMath.adding(days: -1, to: range.end)))"
                        + " · \(DayMath.mediumString(range.end)) stays free to arrive")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") { state.clearRange() }
                    .controlSize(.small)
                Button("Manage availability") {
                    state.selectedSection = .availability
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

/// Holds the editor and the destination status side by side under one heading.
struct AvailabilityPane: View {
    @EnvironmentObject var state: AppState
    @State private var tab: Tab = .editor

    enum Tab: String, CaseIterable, Identifiable {
        case editor, status
        var id: String { rawValue }
        var title: String { self == .editor ? "Plan changes" : "Destination status" }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .padding(10)
            Divider()
            switch tab {
            case .editor: AvailabilityEditorView()
            case .status: SyncStatusView()
            }
        }
    }
}
