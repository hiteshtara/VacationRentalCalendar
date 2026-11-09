import SwiftUI
import VRCCore

/// The review queue.
///
/// Built for getting through a batch rather than admiring one item. Three
/// things do most of the work: identical-looking entries from one feed are
/// grouped so a single decision covers the group, the number keys 1–5 apply a
/// decision without reaching for the mouse, and deciding advances to the next
/// item automatically.
struct ReviewView: View {
    @EnvironmentObject var state: AppState

    private var queue: [ClassifiedEvent] { state.reviewQueue }

    private var selected: ClassifiedEvent? {
        if let key = state.selectedEventKey, let found = state.event(for: key),
           found.classification.needsReview {
            return found
        }
        return queue.first
    }

    /// Undecided entries bucketed by feed and wording, because that is how the
    /// platforms actually produce them — four identical Airbnb blocks, three
    /// identical Vrbo ones.
    private var groups: [ReviewGroup] {
        var buckets: [String: [ClassifiedEvent]] = [:]
        for item in queue {
            buckets["\(item.event.platform.rawValue)|\(item.event.summary)", default: []]
                .append(item)
        }
        return buckets
            .map { ReviewGroup(id: $0.key, items: $0.value.sorted {
                $0.event.checkIn < $1.event.checkIn
            }) }
            .sorted { lhs, rhs in
                if lhs.items.count != rhs.items.count { return lhs.items.count > rhs.items.count }
                return lhs.id < rhs.id
            }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                progressHeader
                Divider()
                if queue.isEmpty {
                    emptyState
                } else {
                    queueList
                }
            }
            .frame(minWidth: 340, idealWidth: 400, maxWidth: 520)

            if let selected {
                EventDetailPanel(item: selected)
                    .frame(minWidth: 380)
                    .background(Color(nsColor: .controlBackgroundColor))
            } else {
                NoEventSelectedView().frame(minWidth: 380)
            }
        }
        .background(reviewKeyboardShortcuts)
    }

    // MARK: Header

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(queue.count)")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 0) {
                    Text(queue.count == 1 ? "entry to decide" : "entries to decide")
                        .font(.subheadline.weight(.medium))
                    Text("\(pendingNights) night\(pendingNights == 1 ? "" : "s") staying on sale "
                        + "until you do")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !state.reviewSelection.isEmpty {
                HStack(spacing: 8) {
                    Text("\(state.reviewSelection.count) ticked")
                        .font(.caption.weight(.medium))
                    Menu("Mark all as…") {
                        ForEach(BlockKind.allCases) { kind in
                            Button(kind.displayName) {
                                state.classifyBatch(eventKeys: state.reviewSelection, as: kind)
                            }
                        }
                    }
                    .frame(width: 140)
                    Button("Clear") { state.reviewSelection.removeAll() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else if queue.count > 1 {
                Text("Tick several to decide them together, or press 1–5 to decide the "
                    + "highlighted one.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
    }

    private var pendingNights: Int {
        queue.reduce(0) { $0 + $1.event.nights }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Everything is decided",
            systemImage: "checkmark.seal",
            description: Text("Every imported date has a classification you made or confirmed.")
        )
    }

    // MARK: Queue

    private var queueList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            ReviewRow(
                                item: item,
                                isCurrent: selected?.event.eventKey == item.event.eventKey,
                                isTicked: state.reviewSelection.contains(item.event.eventKey),
                                onTick: { toggle(item) },
                                onSelect: { state.selectedEventKey = item.event.eventKey }
                            )
                        }
                    } header: {
                        GroupHeader(group: group, state: state)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
        }
    }

    private func toggle(_ item: ClassifiedEvent) {
        if state.reviewSelection.contains(item.event.eventKey) {
            state.reviewSelection.remove(item.event.eventKey)
        } else {
            state.reviewSelection.insert(item.event.eventKey)
        }
    }

    // MARK: Keyboard

    /// Number keys apply a decision to whatever is highlighted and move on.
    private var reviewKeyboardShortcuts: some View {
        ZStack {
            ForEach(Array(BlockKind.allCases.enumerated()), id: \.offset) { index, kind in
                Button("") { decideCurrent(as: kind) }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index + 1)")), modifiers: []
                    )
                    .hidden()
            }
        }
    }

    private func decideCurrent(as kind: BlockKind) {
        guard let current = selected else { return }
        let key = current.event.eventKey
        if !state.reviewSelection.isEmpty {
            state.classifyBatch(eventKeys: state.reviewSelection, as: kind)
            return
        }
        state.classify(eventKey: key, as: kind)
        state.advanceToNextReviewItem(after: key)
    }
}

struct ReviewGroup: Identifiable {
    let id: String
    let items: [ClassifiedEvent]

    var platform: RentalPlatform { items.first?.event.platform ?? .other }
    var summary: String { items.first?.event.summary ?? "" }
    var nights: Int { items.reduce(0) { $0 + $1.event.nights } }
}

private struct GroupHeader: View {
    let group: ReviewGroup
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 7) {
            PlatformBadge(platform: group.platform, style: .compact)
            Text(group.summary.isEmpty ? "(no title)" : group.summary)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text("· \(group.items.count) · \(group.nights) nights")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if group.items.count > 1 {
                Menu {
                    ForEach(BlockKind.allCases) { kind in
                        Button("All \(group.items.count) are \(kind.displayName.lowercased())") {
                            state.classifyBatch(
                                eventKeys: Set(group.items.map(\.event.eventKey)), as: kind
                            )
                        }
                    }
                } label: {
                    Text("Decide all \(group.items.count)").font(.caption2)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(.regularMaterial)
    }
}

private struct ReviewRow: View {
    let item: ClassifiedEvent
    let isCurrent: Bool
    let isTicked: Bool
    let onTick: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button(action: onTick) {
                Image(systemName: isTicked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isTicked ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(DayMath.mediumString(item.event.checkIn)) → "
                        + "\(DayMath.mediumString(item.event.checkOut))")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                    Text("\(item.event.nights)n")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text(item.classification.rationale)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isCurrent ? Color.accentColor.opacity(0.5) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
