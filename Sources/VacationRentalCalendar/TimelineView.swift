import SwiftUI
import VRCCore

/// A horizontal multi-property calendar: properties down the left, nights
/// across the top, one continuous bar per stay.
///
/// Replaces a month grid that drew nothing for an unclassified unavailable
/// night. On a calendar, blank reads as free — so here **every night is
/// marked affirmatively**: an unoccupied night gets its own light cell, and
/// anything a platform reports as unavailable gets a bar. There is no state
/// that renders as empty space.
struct TimelineView: View {
    let layout: TimelineLayout
    /// How current each feed is. An unoccupied night is only drawn as
    /// available when the feed that would have reported a booking is current —
    /// otherwise it is drawn as unknown. No observation is not evidence of
    /// availability.
    var freshness: [FeedFreshness] = []
    var now: Date = Date()
    var onSelect: (ClassifiedEvent) -> Void = { _ in }

    /// The worst state across the feeds: if any is stale, an empty night
    /// cannot be called available, because that is the feed that would have
    /// carried the booking.
    private var anyFeedStale: Bool {
        freshness.isEmpty || freshness.contains { $0.isStale(now: now) }
    }

    private let labelWidth: CGFloat = 148
    private let nightWidth: CGFloat = 34
    private let barHeight: CGFloat = 22
    private let laneGap: CGFloat = 3

    var body: some View {
        ScrollView([.horizontal, .vertical]) { content }
    }

    /// The grid itself, without a scroll container.
    ///
    /// Split out because `ImageRenderer` lays out a `ScrollView` as empty —
    /// the offscreen preview rendered a blank page until this was separated.
    /// It is also the honest unit: scrolling is chrome, this is the calendar.
    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(layout.rows.enumerated()), id: \.element.id) { index, row in
                Divider()
                rowView(row, index: index)
            }
            Divider()
            legend.padding(.top, 10).padding(.leading, labelWidth + 4)
            freshnessStrip.padding(.top, 6).padding(.leading, labelWidth + 4)
        }
        .padding(12)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            Text("Property")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            ForEach(Array(layout.nights.enumerated()), id: \.offset) { _, night in
                VStack(spacing: 1) {
                    Text(Self.weekday(night))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(Self.dayNumber(night))
                        .font(.system(size: 11, weight: isFirstOfMonth(night) ? .bold : .regular))
                        .foregroundStyle(isFirstOfMonth(night) ? .primary : .secondary)
                }
                .frame(width: nightWidth)
            }
        }
        .padding(.bottom, 6)
    }

    /// Feed ages, stated on the face of the calendar. A stale feed is the
    /// reason an empty night cannot be trusted, so it belongs here rather
    /// than behind a click.
    var freshnessStrip: some View {
        HStack(spacing: 12) {
            ForEach(freshness, id: \.platform.rawValue) { feed in
                HStack(spacing: 4) {
                    ChannelBadge(platform: feed.platform)
                    Text(feed.describe(now: now))
                        .font(.system(size: 10))
                        .foregroundStyle(feed.isStale(now: now) ? .orange : .secondary)
                    if feed.isStale(now: now) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    // MARK: - One property

    private func rowView(_ row: TimelineLayout.Row, index: Int) -> some View {
        let height = CGFloat(row.laneCount) * (barHeight + laneGap) + laneGap

        return HStack(spacing: 0) {
            Text(row.propertyName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .frame(width: labelWidth, height: height, alignment: .leading)
                .padding(.trailing, 6)

            ZStack(alignment: .topLeading) {
                // Every night gets a cell. An unoccupied one is drawn as
                // AVAILABLE rather than left blank — the whole point.
                HStack(spacing: 0) {
                    ForEach(Array(layout.nights.enumerated()), id: \.offset) { column, night in
                        let state: NightState = layout.isOccupied(row: index, column: column)
                            ? .occupied
                            : (anyFeedStale ? .unknownStaleFeed : .available)
                        ZStack {
                            Rectangle().fill(Self.nightFill(state))
                            if state == .unknownStaleFeed {
                                Hatch(spacing: 7)
                                    .fill(Color.secondary.opacity(0.28))
                            }
                        }
                            .frame(width: nightWidth, height: height)
                            .overlay(alignment: .leading) {
                                if isFirstOfMonth(night) {
                                    Rectangle().fill(Color.secondary.opacity(0.35))
                                        .frame(width: 1)
                                }
                            }
                    }
                }
                ForEach(row.bars) { bar in
                    barView(bar)
                        .offset(
                            x: CGFloat(bar.startColumn) * nightWidth + 1,
                            y: laneGap + CGFloat(bar.lane) * (barHeight + laneGap))
                }
            }
            .frame(height: height)
        }
    }

    // MARK: - One stay

    private func barView(_ bar: TimelineLayout.Bar) -> some View {
        let style = Self.style(for: bar.emphasis)
        let width = CGFloat(bar.columnCount) * nightWidth - 2

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(style.fill)
            if style.hatched {
                Hatch()
                    .fill(style.stroke.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(style.stroke, lineWidth: 1)

            HStack(spacing: 4) {
                if bar.continuesBefore {
                    Image(systemName: "chevron.compact.left").font(.system(size: 9))
                }
                ChannelBadge(platform: bar.item.event.platform)
                Text(bar.emphasis == .reservation
                     ? bar.item.event.summary : bar.emphasis.label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if bar.continuesAfter {
                    Image(systemName: "chevron.compact.right").font(.system(size: 9))
                }
            }
            .padding(.horizontal, 5)
            .foregroundStyle(style.text)
        }
        .frame(width: max(width, nightWidth - 2), height: barHeight)
        .help(CalendarVisibility.badge(for: bar.item))
        .onTapGesture { onSelect(bar.item) }
    }

    // MARK: - Palette

    struct BarStyle {
        let fill: Color
        let stroke: Color
        let text: Color
        var hatched: Bool = false
    }

    /// Restrained on purpose: one hue per meaning, no badges competing for
    /// attention. The only loud treatment is the one that means "nobody has
    /// decided whether these nights are safe to sell".
    static func style(for emphasis: CalendarEmphasis) -> BarStyle {
        switch emphasis {
        case .reservation:
            return BarStyle(fill: Color.accentColor.opacity(0.18),
                            stroke: Color.accentColor.opacity(0.75), text: .primary)
        case .block:
            return BarStyle(fill: Color.gray.opacity(0.20),
                            stroke: Color.gray.opacity(0.65), text: .primary)
        case .undecided:
            return BarStyle(fill: Color.orange.opacity(0.16),
                            stroke: Color.orange.opacity(0.85), text: .primary,
                            hatched: true)
        case .cancellationPenalty:
            return BarStyle(fill: Color.purple.opacity(0.12),
                            stroke: Color.purple.opacity(0.60), text: .secondary)
        case .bookingWindow:
            return BarStyle(fill: Color.secondary.opacity(0.07),
                            stroke: Color.secondary.opacity(0.30), text: .secondary)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(CalendarEmphasis.allCases, id: \.rawValue) { emphasis in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Self.style(for: emphasis).fill)
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Self.style(for: emphasis).stroke, lineWidth: 1))
                        .frame(width: 18, height: 11)
                    Text(emphasis.label).font(.system(size: 10))
                }
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(Self.nightFill(.available))
                    .frame(width: 18, height: 11)
                Text("Available (feed current)").font(.system(size: 10))
            }
            HStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(Self.nightFill(.unknownStaleFeed))
                    Hatch(spacing: 5).fill(Color.secondary.opacity(0.28))
                }
                .frame(width: 18, height: 11)
                Text("Unknown — feed stale").font(.system(size: 10))
            }
        }
        .foregroundStyle(.secondary)
    }

    /// A verified-free night is the ONLY one allowed to look reassuring.
    static func nightFill(_ state: NightState) -> Color {
        switch state {
        case .occupied: return .clear
        case .available: return Color.green.opacity(0.10)
        case .unknownStaleFeed: return Color.secondary.opacity(0.10)
        }
    }

    // MARK: - Dates

    private static func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return c
    }
    static func dayNumber(_ d: Date) -> String { "\(utcCalendar().component(.day, from: d))" }
    static func weekday(_ d: Date) -> String {
        ["", "S", "M", "T", "W", "T", "F", "S"][utcCalendar().component(.weekday, from: d)]
    }
    private func isFirstOfMonth(_ d: Date) -> Bool {
        Self.utcCalendar().component(.day, from: d) == 1
    }
}

/// A small channel mark, the way a channel manager shows which platform a
/// booking came from. Letter rather than logo: no borrowed branding.
struct ChannelBadge: View {
    let platform: RentalPlatform
    var body: some View {
        Text(Self.letter(platform))
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 13, height: 13)
            .background(Circle().fill(Theme.color(for: platform)))
    }
    static func letter(_ p: RentalPlatform) -> String {
        switch p {
        case .airbnb: return "A"
        case .vrbo: return "V"
        case .bookingCom: return "B"
        @unknown default: return "?"
        }
    }
}

/// Diagonal hatching for undecided nights — the treatment that must never be
/// confused with an ordinary booking or with empty space.
struct Hatch: Shape {
    var spacing: CGFloat = 5
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = -rect.height
        while x < rect.width {
            path.move(to: CGPoint(x: x, y: rect.height))
            path.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += spacing
        }
        return path.strokedPath(.init(lineWidth: 1))
    }
}
