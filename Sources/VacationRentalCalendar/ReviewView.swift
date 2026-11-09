import SwiftUI
import VRCCore
import VRCUI

/// The review queue — where the owner turns an ambiguous block into a decision.
///
/// This screen carries the product's core promise, so it says the consequence
/// of each choice in plain words before the choice is made.
struct ReviewView: View {
    @EnvironmentObject var state: AppState

    private var queue: [ClassifiedEvent] { state.reviewQueue }

    private var selected: ClassifiedEvent? {
        if let key = state.selectedEventKey, let found = state.event(for: key) { return found }
        return queue.first
    }

    var body: some View {
        HSplitView {
            queueList
                .frame(minWidth: 280, idealWidth: 330, maxWidth: 420)
            if let selected {
                ReviewDetail(item: selected)
                    .frame(minWidth: 420)
            } else {
                ContentUnavailableView(
                    "Nothing waiting",
                    systemImage: "checkmark.seal",
                    description: Text("Every imported date has a decision recorded.")
                )
                .frame(minWidth: 420)
            }
        }
    }

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(queue.count) awaiting your decision")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(10)

            if queue.isEmpty {
                Spacer()
                Text("Nothing to review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(queue, selection: Binding(
                    get: { state.selectedEventKey ?? queue.first?.event.eventKey },
                    set: { state.selectedEventKey = $0 }
                )) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Theme.color(for: item.event.platform))
                                .frame(width: 7, height: 7)
                            Text(item.event.platform.displayName)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(item.event.nights)n")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text("\(DayMath.mediumString(item.event.checkIn)) → "
                            + "\(DayMath.mediumString(item.event.checkOut))")
                            .font(.system(size: 12))
                        Text(item.event.summary.isEmpty ? "(no title)" : item.event.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(item.event.eventKey)
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct ReviewDetail: View {
    @EnvironmentObject var state: AppState
    let item: ClassifiedEvent
    @State private var note: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                whatTheFeedSaid
                Divider()
                whatTheAppThinks
                Divider()
                decision
                if item.classification.kind.describesGenuineUnavailability {
                    exportApproval
                }
                Spacer(minLength: 20)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { note = item.classification.note }
        .onChange(of: item.event.eventKey) { _, _ in note = item.classification.note }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(item.event.platform.displayName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.color(for: item.event.platform))
                Text("·").foregroundStyle(.secondary)
                Text(item.propertyName).font(.title3)
            }
            Text("\(DayMath.mediumString(item.event.checkIn)) → "
                + "\(DayMath.mediumString(item.event.checkOut))  ·  "
                + "\(item.event.nights) night\(item.event.nights == 1 ? "" : "s")")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(item.listingLabel).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var whatTheFeedSaid: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("What the platform sent", systemImage: "doc.plaintext")
                .font(.subheadline.weight(.semibold))
            LabeledContent("Summary") {
                Text(item.event.summary.isEmpty ? "(empty)" : item.event.summary)
            }
            if !item.event.details.isEmpty {
                LabeledContent("Description") {
                    Text(item.event.details).textSelection(.enabled)
                }
            } else {
                Text("No description was supplied — which is why this cannot be classified "
                    + "automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Feed status") { Text(item.event.feedStatus.rawValue.capitalized) }
            LabeledContent("UID") {
                Text(item.event.uid).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }

    private var whatTheAppThinks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("What this app concluded", systemImage: "brain")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                EventChip(item: item).frame(width: 220)
                Text("\(item.classification.confidence.displayName) confidence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Text(item.classification.source.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(item.classification.rationale)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var decision: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your decision", systemImage: "hand.point.up.left")
                .font(.subheadline.weight(.semibold))
            Text("This is saved permanently. Later imports of the same feed will not change it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(BlockKind.allCases) { kind in
                Button {
                    state.classify(eventKey: item.event.eventKey, as: kind, note: note)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.classification.kind == kind
                              && item.classification.source == .manual
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(Theme.color(for: kind))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.displayName).font(.system(size: 13, weight: .medium))
                            Text(kind.guidance)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.color(for: kind).opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Note (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("Why these dates are blocked", text: $note, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var exportApproval: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Label("Sharing with other platforms", systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
            Toggle(isOn: Binding(
                get: { item.classification.exportApproved },
                set: { state.setExportApproval(eventKey: item.event.eventKey, approved: $0) }
            )) {
                Text("Include these dates in filtered exports")
            }
            .disabled(item.classification.source != .manual
                      && item.classification.kind != .confirmedReservation)
            Text(item.classification.kind == .confirmedReservation
                 ? "Confirmed reservations are included automatically once confirmed."
                 : "Blocks are only shared after you approve them here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
