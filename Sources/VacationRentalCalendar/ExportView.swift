import SwiftUI
import VRCCore
import AppKit

struct ExportView: View {
    @EnvironmentObject var state: AppState
    @State private var destination: RentalPlatform? = .vrbo
    @State private var showingAudit = false

    private var plan: ExportPlan? { state.exportPlan(destination: destination) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()
            if let plan {
                summary(plan)
                Divider()
                lists(plan)
            } else {
                ContentUnavailableView(
                    "Choose a property",
                    systemImage: "square.and.arrow.up",
                    description: Text("Pick a property in the sidebar to build a filtered feed.")
                )
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("Build a feed for", selection: $destination) {
                Text("Any platform").tag(RentalPlatform?.none)
                ForEach([RentalPlatform.vrbo, .bookingCom, .airbnb]) { platform in
                    Text(platform.displayName).tag(RentalPlatform?.some(platform))
                }
            }
            .frame(width: 280)

            Spacer()

            if let plan {
                Button {
                    save(plan)
                } label: {
                    Label("Save .ics…", systemImage: "arrow.down.document")
                }
                .disabled(plan.included.isEmpty)
                Button("Copy audit") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.auditText(for: plan), forType: .string)
                }
            }
        }
        .padding(12)
    }

    private func summary(_ plan: ExportPlan) -> some View {
        HStack(spacing: 0) {
            stat("Included", "\(plan.included.count)", "\(plan.includedNights) nights", .green)
            Divider().frame(height: 42)
            stat("Held back", "\(plan.excluded.count)", "\(plan.excludedNights) nights", .secondary)
            Divider().frame(height: 42)
            stat(
                "Kept sellable",
                "\(plan.protectedNights)",
                "nights protected",
                Color(red: 0.72, green: 0.29, blue: 0.84)
            )
            Spacer()
            if !OutboundSyncGate.isEnabled {
                Label("Outbound sync off", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 14)
            }
        }
        .padding(.vertical, 10)
    }

    private func stat(_ title: String, _ value: String, _ detail: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).foregroundStyle(tint).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 140, alignment: .leading)
        .padding(.horizontal, 14)
    }

    private func lists(_ plan: ExportPlan) -> some View {
        HSplitView {
            column(
                title: "Will be shared",
                systemImage: "checkmark.circle.fill",
                tint: .green,
                items: plan.included,
                emptyText: "Nothing qualifies yet. Classify a reservation or approve a block."
            )
            column(
                title: "Held back",
                systemImage: "hand.raised.fill",
                tint: Color(red: 0.72, green: 0.29, blue: 0.84),
                items: plan.excluded,
                emptyText: "Nothing is being held back."
            )
        }
    }

    private func column(
        title: String, systemImage: String, tint: Color,
        items: [ExportLineItem], emptyText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .padding(10)
            if items.isEmpty {
                Text(emptyText)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                Spacer()
            } else {
                List(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.color(for: item.event.platform))
                                .frame(width: 7, height: 7)
                            Text("\(DayMath.mediumString(item.event.checkIn)) → "
                                + "\(DayMath.mediumString(item.event.checkOut))")
                                .font(.system(size: 12, weight: .medium))
                            Text("\(item.event.nights)n")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        Text(item.classification.kind.displayName)
                            .font(.caption)
                            .foregroundStyle(Theme.color(for: item.classification.kind))
                        Text(item.decision.reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 320)
    }

    private func save(_ plan: ExportPlan) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "ics")!]
        panel.nameFieldStringValue = "\(plan.propertyName.replacingOccurrences(of: " ", with: "-"))"
            + "-filtered.ics"
        panel.message = "This file contains only the dates listed under \"Will be shared\"."
        if panel.runModal() == .OK, let url = panel.url {
            state.writeExport(plan: plan, to: url)
        }
    }
}
