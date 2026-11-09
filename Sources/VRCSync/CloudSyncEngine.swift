import Foundation
import VRCCore

public struct SyncSummary: Sendable {
    public var pushed = 0
    public var pulled = 0
    public var merged = 0
    public var escalatedToReview = 0
    public var accountStatus: CloudAccountStatus = .unknown
    public var finishedAt: Date?
    public var error: String?

    public var succeeded: Bool { error == nil }

    public var line: String {
        if let error { return "Sync failed: \(error)" }
        guard accountStatus.canSync else { return accountStatus.explanation }
        var parts: [String] = []
        if pushed > 0 { parts.append("\(pushed) sent") }
        if pulled > 0 { parts.append("\(pulled) received") }
        if escalatedToReview > 0 { parts.append("\(escalatedToReview) need your review") }
        return parts.isEmpty ? "Already up to date" : parts.joined(separator: ", ")
    }
}

/// Keeps two devices holding the same decisions.
///
/// Deliberately *not* a general-purpose replicator. It pushes local state up,
/// pulls remote state down, and merges with `SyncMergePolicy` — whose rules
/// exist so that the safety guarantee (a cancellation or unknown block is never
/// shared) cannot be broken by a stale copy arriving from another device.
public final class CloudSyncEngine: @unchecked Sendable {
    private let store: RentalStore
    private let cloud: CloudDatabase
    private let policy: SyncMergePolicy
    public let deviceID: String

    public init(
        store: RentalStore,
        cloud: CloudDatabase,
        policy: SyncMergePolicy = SyncMergePolicy(),
        deviceID: String = CloudSyncEngine.resolveDeviceID()
    ) {
        self.store = store
        self.cloud = cloud
        self.policy = policy
        self.deviceID = deviceID
    }

    /// Stable per-device identifier, used only to break exact timestamp ties.
    /// Random and local; it identifies nothing about the owner.
    public static func resolveDeviceID() -> String {
        let key = "sync_device_id"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    // MARK: - Entry point

    @discardableResult
    public func synchronise() async -> SyncSummary {
        var summary = SyncSummary()
        summary.accountStatus = await cloud.accountStatus()

        guard summary.accountStatus.canSync else {
            summary.finishedAt = Date()
            recordState(summary)
            return summary
        }

        do {
            summary.pulled = try await pull(into: &summary)
            summary.pushed = try await push()
            summary.finishedAt = Date()
        } catch {
            summary.error = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            summary.finishedAt = Date()
        }
        recordState(summary)
        return summary
    }

    // MARK: - Pull

    private func pull(into summary: inout SyncSummary) async throws -> Int {
        let token = storedToken()
        let changes = try await cloud.fetchChanges(since: token)
        var applied = 0

        for record in changes.changed {
            switch record.type {
            case .property:
                if applyProperty(record) { applied += 1 }
            case .listing:
                if applyListing(record) { applied += 1 }
            case .event:
                if applyEvent(record) { applied += 1 }
            case .classification:
                let outcome = applyClassification(record)
                if outcome.changed { applied += 1 }
                if outcome.escalated { summary.escalatedToReview += 1 }
            }
        }

        if let newToken = changes.newToken { storeToken(newToken) }
        return applied
    }

    private func applyProperty(_ record: CloudRecord) -> Bool {
        guard let (remote, remoteModified) = CloudRecordMapper.property(from: record),
              let id = remote.id else { return false }
        guard let local = try? store.properties.find(id: id) else {
            // A property this device has not seen. Insert with its cloud identity.
            var inserted = remote
            inserted.id = nil
            _ = try? store.properties.insert(inserted)
            return true
        }
        let merged = policy.mergeProperty(
            local: local, remote: remote,
            localModified: local.updatedAt, remoteModified: remoteModified
        )
        guard merged.resolution == .remoteWins else { return false }
        var value = merged.value
        value.id = id
        try? store.properties.update(value)
        return true
    }

    private func applyListing(_ record: CloudRecord) -> Bool {
        guard let (remote, _) = CloudRecordMapper.listing(from: record),
              let id = remote.id else { return false }
        guard var local = try? store.listings.find(id: id) else { return false }
        // Only the descriptive parts travel. The feed URL and its Keychain
        // reference are per-device and are never overwritten from the cloud.
        local.label = remote.label
        local.autoRefreshEnabled = remote.autoRefreshEnabled
        try? store.listings.update(local)
        return true
    }

    private func applyEvent(_ record: CloudRecord) -> Bool {
        guard let remote = CloudRecordMapper.event(from: record) else { return false }
        guard let local = try? store.events.find(eventKey: remote.eventKey) else {
            _ = try? store.events.upsert(remote)
            return true
        }
        let merged = policy.mergeEvent(local: local, remote: remote)
        guard merged.resolution == .remoteWins else { return false }
        var value = merged.value
        value.id = local.id
        _ = try? store.events.upsert(value)
        return true
    }

    private func applyClassification(_ record: CloudRecord) -> (changed: Bool, escalated: Bool) {
        guard let (remote, remoteDevice) = CloudRecordMapper.classification(from: record) else {
            return (false, false)
        }
        guard let existing = (try? store.classifications.find(eventKey: remote.eventKey)) ?? nil else {
            try? store.classifications.save(remote)
            return (true, false)
        }

        let merged = policy.merge(
            local: existing, remote: remote,
            localDeviceID: deviceID, remoteDeviceID: remoteDevice
        )

        switch merged.resolution {
        case .identical, .localWins:
            return (false, false)
        case .remoteWins:
            try? store.classifications.save(merged.value)
            return (true, false)
        case .escalatedToReview:
            try? store.classifications.save(merged.value)
            recordDisagreement(
                eventKey: remote.eventKey,
                local: existing.kind, remote: remote.kind, resolved: merged.value.kind
            )
            return (true, true)
        }
    }

    // MARK: - Push

    private func push() async throws -> Int {
        var records: [CloudRecord] = []

        for property in (try? store.properties.all()) ?? [] {
            if let record = CloudRecordMapper.record(for: property, modifiedAt: property.updatedAt) {
                records.append(record)
            }
        }
        for listing in (try? store.listings.all()) ?? [] {
            if let record = CloudRecordMapper.record(for: listing, modifiedAt: listing.updatedAt) {
                records.append(record)
            }
        }
        for event in (try? store.events.all(includeTombstoned: true)) ?? [] {
            records.append(CloudRecordMapper.record(for: event, listingID: event.listingID))
        }
        for classification in ((try? store.classifications.all()) ?? [:]).values {
            records.append(CloudRecordMapper.record(for: classification, deviceID: deviceID))
        }

        guard !records.isEmpty else { return 0 }

        // Belt and braces: nothing leaves this device without passing the
        // forbidden-field check, even though the mappers never add one.
        for record in records {
            for name in record.fields.keys where CloudRecordMapper.forbiddenFieldNames.contains(name) {
                throw CloudSyncError.underlying(
                    "Refusing to upload: record \(record.id) carries the field \"\(name)\", "
                        + "which must never leave this device."
                )
            }
        }

        // CloudKit caps a single request; send in modest batches.
        var saved = 0
        for batch in stride(from: 0, to: records.count, by: 200).map({
            Array(records[$0..<min($0 + 200, records.count)])
        }) {
            saved += try await cloud.save(batch).count
        }
        return saved
    }

    // MARK: - State

    private func storedToken() -> Data? {
        guard let rows = try? store.database.query(
            "SELECT change_token FROM sync_state WHERE zone_name = ?;", [.text("default")]
        ), let row = rows.first, case .blob(let data)? = row.values["change_token"] else {
            return nil
        }
        return data.isEmpty ? nil : data
    }

    private func storeToken(_ token: Data) {
        _ = try? store.database.run("""
            INSERT INTO sync_state (zone_name, change_token, last_sync_at)
            VALUES (?, ?, ?)
            ON CONFLICT(zone_name) DO UPDATE SET
                change_token = excluded.change_token,
                last_sync_at = excluded.last_sync_at;
            """, [.text("default"), .blob(token), SQLValue(Date())])
    }

    private func recordState(_ summary: SyncSummary) {
        _ = try? store.database.run("""
            INSERT INTO sync_state (zone_name, last_sync_at, last_error)
            VALUES (?, ?, ?)
            ON CONFLICT(zone_name) DO UPDATE SET
                last_sync_at = excluded.last_sync_at,
                last_error = excluded.last_error;
            """, [.text("default"), SQLValue(summary.finishedAt), SQLValue(summary.error)])
    }

    private func recordDisagreement(
        eventKey: String, local: BlockKind, remote: BlockKind, resolved: BlockKind
    ) {
        _ = try? store.database.run("""
            INSERT INTO sync_conflicts
                (event_key, local_kind, remote_kind, resolved_kind, detected_at, resolved)
            VALUES (?, ?, ?, ?, ?, 0)
            ON CONFLICT(event_key) DO UPDATE SET
                local_kind = excluded.local_kind,
                remote_kind = excluded.remote_kind,
                resolved_kind = excluded.resolved_kind,
                detected_at = excluded.detected_at,
                resolved = 0;
            """, [
                .text(eventKey), .text(local.rawValue), .text(remote.rawValue),
                .text(resolved.rawValue), SQLValue(Date()),
            ])
    }

    /// Disagreements between devices that the owner has not yet settled.
    public func openDisagreements() -> [(eventKey: String, local: BlockKind, remote: BlockKind)] {
        guard let rows = try? store.database.query(
            "SELECT * FROM sync_conflicts WHERE resolved = 0 ORDER BY detected_at DESC;"
        ) else { return [] }
        return rows.compactMap { row in
            guard let local = BlockKind(rawValue: row.stringValue("local_kind")),
                  let remote = BlockKind(rawValue: row.stringValue("remote_kind")) else {
                return nil
            }
            return (row.stringValue("event_key"), local, remote)
        }
    }

    public func lastSyncAt() -> Date? {
        try? store.database.queryOne(
            "SELECT last_sync_at FROM sync_state WHERE zone_name = ?;", [.text("default")]
        )?.date("last_sync_at")
    }
}
