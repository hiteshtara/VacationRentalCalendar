import SwiftUI
import VRCCore

/// The portfolio: every active property, with the state of its connections and
/// anything waiting on the owner.
///
/// Read-only by design. Adding, editing and archiving happen in the sheet; the
/// portfolio itself never changes availability, publishes anything, or offers
/// a control that could. Its job is to answer "is anything wrong anywhere?"
/// without opening five properties one at a time.
///
/// Every number shown comes from `RentalStore.portfolio()`, which is computed
/// per property in VRCCore and covered by tests. Nothing is totalled here.
struct PortfolioView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: Property?
    @State private var addingProperty = false
    @State private var showArchived = false
    @State private var archiveCandidate: Property?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if state.portfolioRows.isEmpty && !showArchived {
                ContentUnavailableView(
                    "No properties yet",
                    systemImage: "house",
                    description: Text("Add a property to start unifying its calendars."))
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(state.portfolioRows) { row in
                            PortfolioCard(row: row) { editing = row.property }
                                archiveAction: { archiveCandidate = row.property }
                        }
                        if showArchived { archivedSection }
                    }
                    .padding(12)
                }
            }
        }
        .sheet(item: $editing) { property in
            PropertyEditor(property: property) { state.updateProperty($0) }
        }
        .sheet(isPresented: $addingProperty) {
            PropertyEditor(property: Property(name: "")) { new in
                state.addProperty(name: new.name, address: new.address)
            }
        }
        .confirmationDialog(
            "Archive \(archiveCandidate?.name ?? "this property")?",
            isPresented: Binding(
                get: { archiveCandidate != nil },
                set: { if !$0 { archiveCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button("Archive", role: .destructive) {
                if let id = archiveCandidate?.id { state.archiveProperty(id: id) }
                archiveCandidate = nil
            }
            Button("Keep it", role: .cancel) { archiveCandidate = nil }
        } message: {
            Text("It leaves the portfolio. Nothing is deleted — its reservations, "
                + "classifications and audit history are all kept, and you can restore it.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Portfolio").font(.title3.weight(.semibold))
                Text("\(state.portfolioRows.count) active "
                    + "propert\(state.portfolioRows.count == 1 ? "y" : "ies")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state.properties.contains(where: \.isArchived) {
                Toggle("Show archived", isOn: $showArchived)
                    .toggleStyle(.checkbox).controlSize(.small)
            }
            Button {
                addingProperty = true
            } label: {
                Label("Add property", systemImage: "plus")
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Archived").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(state.properties.filter(\.isArchived)) { property in
                HStack {
                    Image(systemName: "archivebox").foregroundStyle(.secondary)
                    Text(property.name).font(.system(size: 12))
                    Spacer()
                    Button("Restore") {
                        if let id = property.id { state.unarchiveProperty(id: id) }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.06)))
            }
        }
        .padding(.top, 6)
    }
}

private struct PortfolioCard: View {
    let row: PortfolioRow
    var editAction: () -> Void
    var archiveAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.property.name).font(.system(size: 14, weight: .semibold))
                    if !row.property.address.isEmpty {
                        Text(row.property.address).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if row.needsAttention {
                    Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange).labelStyle(.iconOnly)
                }
                Menu {
                    Button("Edit…", action: editAction)
                    Divider()
                    Button("Archive…", role: .destructive, action: archiveAction)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
            }

            HStack(spacing: 14) {
                metric("\(row.connectedCount)/\(row.listingCount)", "connected",
                       tint: row.troubledCount > 0 ? .orange : .green)
                metric("\(row.activeEventCount)", "observations", tint: .secondary)
                metric("\(row.needsReviewCount)", "to review",
                       tint: row.needsReviewCount > 0 ? .orange : .secondary)
                metric("\(row.conflictCount)", "conflicts",
                       tint: row.conflictCount > 0 ? .red : .secondary)
                Spacer()
                if let next = row.nextArrival {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(DayMath.mediumString(next))
                            .font(.caption.weight(.medium).monospacedDigit())
                        Text("next arrival").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.07)))
    }

    private func metric(_ value: String, _ label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

/// Add and edit share one form: the fields are identical, and two
/// near-duplicate sheets is how they drift apart.
struct PropertyEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Property
    private let onSave: (Property) -> Void
    private let isNew: Bool

    init(property: Property, onSave: @escaping (Property) -> Void) {
        _draft = State(initialValue: property)
        self.onSave = onSave
        self.isNew = property.id == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(isNew ? "Add a property" : "Edit property")
                .font(.headline)

            Form {
                TextField("Name", text: $draft.name)
                TextField("Address", text: $draft.address)
                Picker("Time zone", selection: $draft.timeZone) {
                    ForEach(PropertyEditor.zones, id: \.self) { Text($0).tag($0) }
                }
                TextField("Notes", text: $draft.notes, axis: .vertical)
                    .lineLimit(2...4)
            }
            .formStyle(.grouped)

            Text("Nights are counted in the property's own time zone, so "
                + "\"10–15 December\" means the same nights wherever you are.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isNew ? "Add" : "Save") {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 430)
    }

    /// A short list rather than every IANA zone: this is a US short-let tool,
    /// and a 600-entry picker is worse than a short one plus a future request.
    static let zones = [
        "America/New_York", "America/Chicago", "America/Denver",
        "America/Los_Angeles", "America/Anchorage", "Pacific/Honolulu",
        "Europe/London", "Europe/Paris", "UTC",
    ]
}
