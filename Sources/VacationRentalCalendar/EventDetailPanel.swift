import SwiftUI
import VRCCore

/// Everything known about one event, and the place to decide what it is.
///
/// Shown as an inspector beside the calendar, so choosing a bar does not take
/// you away from the month you were reading.
struct EventDetailPanel: View {
    @EnvironmentObject var state: AppState
    let item: ClassifiedEvent

    @State private var note: String = ""
    @State private var showAllFeedFields = false

    private var status: EventDisplayStatus { item.displayStatus }
    private var similar: [ClassifiedEvent] { state.similarPendingEvents(to: item) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statusBlock
                if state.feedLacksDetail(for: item) { insufficientDetailWarning }
                datesBlock
                feedBlock
                Divider()
                decisionBlock
                if status != .needsReview && item.classification.kind.describesGenuineUnavailability {
                    sharingBlock
                }
                Spacer(minLength: 12)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { note = item.classification.note }
        .onChange(of: item.event.eventKey) { _, _ in note = item.classification.note }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                PlatformBadge(platform: item.event.platform)
                Spacer()
                Button {
                    state.clearSelection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            Text(item.propertyName).font(.title3.weight(.semibold))
            Text(item.listingLabel).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Status

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusBadge(status: status)
            Text(status.consequence)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Text(item.classification.source.displayName)
                if item.classification.source == .automatic {
                    Text("·")
                    Text("\(item.classification.confidence.displayName) confidence")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: The warning that matters

    private var insufficientDetailWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("This feed cannot tell you whether these dates are booked")
                    .font(.caption.weight(.semibold))
                Text(lackingDetailExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: 7).strokeBorder(Color.orange.opacity(0.35))
        )
    }

    private var lackingDetailExplanation: String {
        switch item.event.platform {
        case .airbnb:
            return "Airbnb sent no description with this entry. A confirmed booking, a block you "
                + "made, and dates Airbnb took back after a cancellation all look exactly like "
                + "this. Only you can tell them apart."
        case .vrbo:
            return "Vrbo labelled this only \"\(item.event.summary)\", with nothing to separate a "
                + "booking from dates you are holding."
        case .bookingCom:
            return "Booking.com labels bookings and owner blocks identically in its export, so "
                + "this entry proves nothing either way."
        case .other:
            return "This feed sent nothing that identifies a booking."
        }
    }

    // MARK: Dates

    private var datesBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Dates", systemImage: "calendar")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                dateColumn("Check-in", DayMath.mediumString(item.event.checkIn))
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                dateColumn("Check-out", DayMath.mediumString(item.event.checkOut))
            }
            Text("\(item.event.nights) night\(item.event.nights == 1 ? "" : "s") "
                + "· check-out day is free for the next guest")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func dateColumn(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
    }

    // MARK: What the platform sent

    private var feedBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("What \(item.event.platform.displayName) sent", systemImage: "doc.plaintext")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            field("Summary", item.event.summary.isEmpty ? "(empty)" : item.event.summary)
            if item.event.details.isEmpty {
                field("Description", "(none)")
            } else {
                field("Description", item.event.details)
            }

            DisclosureGroup(isExpanded: $showAllFeedFields) {
                VStack(alignment: .leading, spacing: 4) {
                    field("Status in feed", item.event.feedStatus.rawValue.capitalized)
                    field("UID", item.event.uid, monospaced: true)
                    if !item.event.location.isEmpty { field("Location", item.event.location) }
                    if let modified = item.event.lastModified {
                        field("Last modified", DayMath.mediumString(modified))
                    }
                    field("First seen", DayMath.mediumString(item.event.firstSeenAt))
                    field("Last seen", DayMath.mediumString(item.event.lastSeenAt))
                    if item.event.hasUnsupportedRecurrence {
                        Text("This event repeats using a rule the app does not expand.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("All feed data").font(.caption)
            }
        }
    }

    private func field(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Decide

    private var decisionBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("What is this?", systemImage: "hand.point.up.left")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(BlockKind.allCases) { kind in
                Button {
                    state.classify(eventKey: item.event.eventKey, as: kind, note: note)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: isChosen(kind) ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(Theme.color(for: kind))
                            .font(.system(size: 13))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kind.displayName).font(.system(size: 12, weight: .medium))
                            Text(kind.guidance)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isChosen(kind)
                                  ? Theme.color(for: kind).opacity(0.12)
                                  : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !similar.isEmpty {
                Divider().padding(.vertical, 2)
                Text("\(similar.count) other undecided "
                    + "\(item.event.platform.displayName) "
                    + "entr\(similar.count == 1 ? "y looks" : "ies look") identical to this one.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Menu("Apply a decision to all \(similar.count + 1)") {
                    ForEach(BlockKind.allCases) { kind in
                        Button(kind.displayName) {
                            var keys = Set(similar.map(\.event.eventKey))
                            keys.insert(item.event.eventKey)
                            state.classifyBatch(eventKeys: keys, as: kind, note: note)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .font(.caption)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Note").font(.caption2).foregroundStyle(.tertiary)
                TextField("Why these dates are blocked", text: $note, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }

            Text("Saved permanently. Later imports never overwrite it.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func isChosen(_ kind: BlockKind) -> Bool {
        item.classification.source == .manual && item.classification.kind == kind
    }

    // MARK: Sharing

    private var sharingBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            Label("Share with other platforms", systemImage: "square.and.arrow.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if item.classification.kind == .confirmedReservation {
                Text("Confirmed reservations are shared automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle(isOn: Binding(
                    get: { item.classification.exportApproved },
                    set: { state.setExportApproval(eventKey: item.event.eventKey, approved: $0) }
                )) {
                    Text("Include these nights in filtered exports").font(.caption)
                }
                .disabled(item.classification.source != .manual)
            }

            Toggle(isOn: Binding(
                get: { item.classification.exportSuppressed },
                set: { state.setExportSuppressed(eventKey: item.event.eventKey, suppressed: $0) }
            )) {
                Text("Never share these nights").font(.caption)
            }
        }
    }
}

/// Shown in the inspector when nothing is selected.
struct NoEventSelectedView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.tap")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Select a date range")
                .font(.subheadline.weight(.medium))
            Text("Choose any bar in the calendar to see where it came from and decide what it is.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
