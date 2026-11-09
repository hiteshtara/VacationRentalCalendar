import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

public enum CloudSyncError: Error, LocalizedError {
    case notSignedIn
    case networkUnavailable
    case notConfigured(String)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to iCloud in System Settings to sync between your Mac and iPhone."
        case .networkUnavailable:
            return "No network connection, so nothing was synced. Your local data is unaffected."
        case .notConfigured(let detail):
            return "iCloud sync is not set up for this build: \(detail)"
        case .underlying(let message):
            return message
        }
    }
}

public enum CloudAccountStatus: String, Sendable {
    case available
    case noAccount
    case restricted
    case unavailable
    case unknown

    public var canSync: Bool { self == .available }

    public var explanation: String {
        switch self {
        case .available: return "Signed in to iCloud."
        case .noAccount: return "Not signed in to iCloud. Sync is off; everything still works locally."
        case .restricted: return "iCloud is restricted on this device."
        case .unavailable: return "iCloud is unavailable right now."
        case .unknown: return "iCloud status could not be determined."
        }
    }
}

/// The transport. Abstracted so the engine and its merge rules are testable
/// without an iCloud account, a network, or a provisioning profile.
public protocol CloudDatabase: Sendable {
    func accountStatus() async -> CloudAccountStatus
    func save(_ records: [CloudRecord]) async throws -> [CloudRecord]
    func fetchChanges(since token: Data?) async throws -> CloudChangeSet
    func delete(ids: [String]) async throws
}

// MARK: - In-memory, for tests and for a dry run

public actor InMemoryCloudDatabase: CloudDatabase {
    private var storage: [String: CloudRecord] = [:]
    private var log: [(record: CloudRecord?, deletedID: String?)] = []
    public var simulatedAccountStatus: CloudAccountStatus = .available
    public var failNextSave: CloudSyncError?

    public init() {}

    public var allRecords: [CloudRecord] { Array(storage.values) }

    public func setAccountStatus(_ status: CloudAccountStatus) {
        simulatedAccountStatus = status
    }

    public func setFailNextSave(_ error: CloudSyncError?) {
        failNextSave = error
    }

    public func seed(_ records: [CloudRecord]) {
        for record in records {
            storage[record.id] = record
            log.append((record, nil))
        }
    }

    public func accountStatus() async -> CloudAccountStatus { simulatedAccountStatus }

    public func save(_ records: [CloudRecord]) async throws -> [CloudRecord] {
        if let failure = failNextSave { failNextSave = nil; throw failure }
        var saved: [CloudRecord] = []
        for var record in records {
            record.changeTag = UUID().uuidString
            storage[record.id] = record
            log.append((record, nil))
            saved.append(record)
        }
        return saved
    }

    public func fetchChanges(since token: Data?) async throws -> CloudChangeSet {
        let start = token.flatMap { Int(String(data: $0, encoding: .utf8) ?? "") } ?? 0
        let slice = log.count > start ? Array(log[start...]) : []
        let newToken = Data(String(log.count).utf8)
        return CloudChangeSet(
            changed: slice.compactMap(\.record),
            deletedIDs: slice.compactMap(\.deletedID),
            newToken: newToken
        )
    }

    public func delete(ids: [String]) async throws {
        for id in ids {
            storage.removeValue(forKey: id)
            log.append((nil, id))
        }
    }
}

// MARK: - Real CloudKit

#if canImport(CloudKit)
/// The private CloudKit database, in a custom zone so that change tokens work.
///
/// Uses the **private** database only — this data never touches a public or
/// shared scope. Nothing here is reachable without the owner's Apple Account.
public struct CloudKitDatabase: CloudDatabase {
    public static let defaultContainerID = "iCloud.com.vacationrentalcalendar.app"
    public static let zoneName = "VacationRentalCalendar"

    private let container: CKContainer
    private let zoneID: CKRecordZone.ID

    public init(containerIdentifier: String = CloudKitDatabase.defaultContainerID) {
        self.container = CKContainer(identifier: containerIdentifier)
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    private var database: CKDatabase { container.privateCloudDatabase }

    public func accountStatus() async -> CloudAccountStatus {
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .couldNotDetermine: return .unknown
            case .temporarilyUnavailable: return .unavailable
            @unknown default: return .unknown
            }
        } catch {
            return .unknown
        }
    }

    /// Creates the custom zone if it is not there yet. Safe to call repeatedly.
    public func prepareZone() async throws {
        do {
            _ = try await database.recordZone(for: zoneID)
        } catch {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
        }
    }

    public func save(_ records: [CloudRecord]) async throws -> [CloudRecord] {
        guard !records.isEmpty else { return [] }
        try await prepareZone()
        let ckRecords = records.map { make($0) }
        do {
            let (saveResults, _) = try await database.modifyRecords(
                saving: ckRecords, deleting: [], savePolicy: .changedKeys
            )
            var saved: [CloudRecord] = []
            for (_, result) in saveResults {
                if case .success(let record) = result, let mapped = convert(record) {
                    saved.append(mapped)
                }
            }
            return saved
        } catch {
            throw translate(error)
        }
    }

    public func fetchChanges(since token: Data?) async throws -> CloudChangeSet {
        try await prepareZone()
        let serverToken = token.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        do {
            let result = try await database.recordZoneChanges(
                inZoneWith: zoneID, since: serverToken
            )
            var changed: [CloudRecord] = []
            for modification in result.modificationResultsByID.values {
                if case .success(let value) = modification, let mapped = convert(value.record) {
                    changed.append(mapped)
                }
            }
            let deleted = result.deletions.map { $0.recordID.recordName }
            let newToken = try? NSKeyedArchiver.archivedData(
                withRootObject: result.changeToken, requiringSecureCoding: true
            )
            return CloudChangeSet(
                changed: changed, deletedIDs: deleted,
                newToken: newToken, moreComing: result.moreComing
            )
        } catch {
            throw translate(error)
        }
    }

    public func delete(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let recordIDs = ids.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        do {
            _ = try await database.modifyRecords(saving: [], deleting: recordIDs)
        } catch {
            throw translate(error)
        }
    }

    // MARK: Conversion

    private func make(_ record: CloudRecord) -> CKRecord {
        let id = CKRecord.ID(recordName: record.id, zoneID: zoneID)
        let ckRecord = CKRecord(recordType: record.type.rawValue, recordID: id)
        for (key, value) in record.fields {
            switch value {
            case .string(let v): ckRecord[key] = v as CKRecordValue
            case .number(let v): ckRecord[key] = v as CKRecordValue
            case .boolean(let v): ckRecord[key] = (v ? 1 : 0) as CKRecordValue
            case .date(let v): ckRecord[key] = v as CKRecordValue
            }
        }
        return ckRecord
    }

    private func convert(_ ckRecord: CKRecord) -> CloudRecord? {
        guard let type = CloudRecordType(rawValue: ckRecord.recordType) else { return nil }
        var fields: [String: CloudValue] = [:]
        for key in ckRecord.allKeys() {
            switch ckRecord[key] {
            case let value as String: fields[key] = .string(value)
            case let value as Date: fields[key] = .date(value)
            case let value as NSNumber: fields[key] = .number(value.doubleValue)
            default: break
            }
        }
        return CloudRecord(
            id: ckRecord.recordID.recordName, type: type,
            changeTag: ckRecord.recordChangeTag, fields: fields
        )
    }

    private func translate(_ error: Error) -> CloudSyncError {
        guard let ckError = error as? CKError else {
            return .underlying(error.localizedDescription)
        }
        switch ckError.code {
        case .notAuthenticated: return .notSignedIn
        case .networkUnavailable, .networkFailure: return .networkUnavailable
        case .badContainer, .missingEntitlement:
            return .notConfigured(
                "the iCloud container entitlement is missing. See docs/IOS-CLOUDKIT.md."
            )
        default: return .underlying(ckError.localizedDescription)
        }
    }
}
#endif
