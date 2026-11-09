import SwiftUI
import VRCCore

/// Choose a date range, decide what each platform should do, see what would
/// happen, then submit it for your own approval.
struct AvailabilityEditorView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DeliveryWarningBanner()
                    gateBanner
                    rangeSection
                    if state.selectedNights > 0 { platformSection }
                    if let preview = state.previewPlan() {
                        Divider()
                        AvailabilityPreviewView(preview: preview)
                        actions(preview)
                    }
                    Spacer(minLength: 20)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 380, idealWidth: 460)

            PendingDecisionsView()
                .frame(minWidth: 380)
        }
    }

    // MARK: Gate

    private var gateBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing here reaches a booking platform")
                    .font(.caption.weight(.semibold))
                Text("Decisions are recorded on this Mac and feeds are generated locally for you "
                    + "to inspect. Publishing is switched off in this build, so no platform sees "
                    + "any of it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.09)))
    }

    // MARK: Dates

    private var rangeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Which nights", systemImage: "calendar")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                DatePicker(
                    "First night",
                    selection: Binding(
                        get: { state.rangeStart ?? DayMath.utcMidnight(Date()) },
                        set: { state.rangeStart = DayMath.utcMidnight($0) }
                    ),
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)

                DatePicker(
                    "Last night",
                    selection: Binding(
                        get: { state.rangeEnd ?? state.rangeStart ?? DayMath.utcMidnight(Date()) },
                        set: { state.rangeEnd = DayMath.utcMidnight($0) }
                    ),
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
            }
            .font(.caption)

            if state.selectedNights > 0, let range = state.selectedRange {
                Text("\(state.selectedNights) night"
                    + "\(state.selectedNights == 1 ? "" : "s"). "
                    + "\(DayMath.mediumString(range.end)) stays free for an arrival.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Pick the first and last night, or click two days in the calendar.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !state.planReason.isEmpty || state.selectedNights > 0 {
                TextField("Why (optional)", text: $state.planReason)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
        }
    }

    // MARK: Platforms

    private var platformSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("What each platform should do", systemImage: "square.grid.3x1.below.line.grid.1x2")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Each one is independent. A choice for Vrbo does nothing to Airbnb.")
                .font(.caption2).foregroundStyle(.tertiary)

            ForEach([RentalPlatform.airbnb, .vrbo, .bookingCom]) { platform in
                PlatformSelector(
                    platform: platform,
                    capability: PlatformAdapters.capability(for: platform),
                    currentState: currentState(for: platform),
                    action: Binding(
                        get: { state.plannedActions[platform] },
                        set: { newValue in
                            if let newValue {
                                state.plannedActions[platform] = newValue
                            } else {
                                state.plannedActions.removeValue(forKey: platform)
                            }
                        }
                    )
                )
            }
        }
    }

    /// What that platform's own calendar currently says about these nights.
    private func currentState(for platform: RentalPlatform) -> String {
        guard let range = state.selectedRange else { return "—" }
        let overlapping = state.visibleEvents.filter {
            $0.event.platform == platform
                && $0.event.checkIn < range.end && range.start < $0.event.checkOut
        }
        guard !overlapping.isEmpty else { return "Open on \(platform.displayName)" }
        if overlapping.contains(where: { $0.classification.kind == .confirmedReservation }) {
            return "Booked on \(platform.displayName)"
        }
        if overlapping.contains(where: { $0.classification.needsReview }) {
            return "Unavailable, reason undecided"
        }
        return "Unavailable on \(platform.displayName)"
    }

    // MARK: Actions

    private func actions(_ preview: VRCCore.AvailabilityPreview) -> some View {
        HStack {
            Button("Cancel") { state.clearRange() }
            Spacer()
            Button("Save for approval") { state.submitPlan() }
                .keyboardShortcut(.defaultAction)
                .disabled(preview.actionable.isEmpty && !preview.isRefusedAnywhere)
        }
        .padding(.top, 4)
    }
}

/// Everything waiting on the owner, plus the permanent history.
struct PendingDecisionsView: View {
    @EnvironmentObject var state: AppState
    @State private var expandedDecision: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Waiting for you").font(.subheadline.weight(.semibold))
                Spacer()
                if !state.pendingDecisions.isEmpty {
                    Button("Cancel all") { state.cancelAllPending() }
                        .controlSize(.small)
                }
            }
            .padding(12)
            Divider()

            if state.pendingDecisions.isEmpty {
                ContentUnavailableView(
                    "Nothing pending",
                    systemImage: "tray",
                    description: Text("Changes you save appear here for approval.")
                )
            } else {
                ScrollView {
                    VStack(spacing: 9) {
                        ForEach(state.pendingDecisions) { decision in
                            decisionCard(decision)
                        }
                    }
                    .padding(11)
                }
            }
        }
    }

    private func decisionCard(_ decision: AvailabilityDecision) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                PlatformBadge(platform: decision.destination, style: .compact)
                Text(decision.action.displayName).font(.caption.weight(.semibold))
                Spacer()
                Text(decision.status.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(statusTint(decision.status).opacity(0.15)))
                    .foregroundStyle(statusTint(decision.status))
            }

            Text(decision.nightsDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let failure = decision.failureReason {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if decision.status == .awaitingApproval {
                HStack {
                    Button("Approve") {
                        if let id = decision.id { state.approve(decisionID: id) }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    Button("Cancel") {
                        if let id = decision.id { state.cancel(decisionID: id) }
                    }
                    .controlSize(.small)
                    Spacer()
                }
            } else if decision.status == .approved {
                Text("Approved. It will be included the next time a feed is published — which "
                    + "cannot happen while publishing is switched off.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Cancel") {
                    if let id = decision.id { state.cancel(decisionID: id) }
                }
                .controlSize(.small)
            }

            if let id = decision.id {
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedDecision == id },
                    set: { expandedDecision = $0 ? id : nil }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(state.auditEntries(forDecision: id)) { entry in
                            Text(entry.line)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 3)
                } label: {
                    Text("History").font(.caption2)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    private func statusTint(_ status: AvailabilityStatus) -> Color {
        switch status {
        case .approved, .verified: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .published, .awaitingPlatformRefresh: return .blue
        default: return .orange
        }
    }
}
