import Foundation
import VRCCore

public enum CloudRecordType: String, Sendable, CaseIterable {
    case property = "VRCProperty"
    case listing = "VRCListing"
    case event = "VRCEvent"
    case classification = "VRCClassification"
}

public enum CloudValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case date(Date)

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
    public var doubleValue: Double? {
        switch self {
        case .number(let v): return v
        case .date(let v): return v.timeIntervalSince1970
        case .boolean(let v): return v ? 1 : 0
        default: return nil
        }
    }
    public var boolValue: Bool? {
        switch self {
        case .boolean(let v): return v
        case .number(let v): return v != 0
        default: return nil
        }
    }
    public var dateValue: Date? {
        switch self {
        case .date(let v): return v
        case .number(let v): return Date(timeIntervalSince1970: v)
        default: return nil
        }
    }
}

/// A transport-neutral record. Keeps the mapping testable without CloudKit, and
/// keeps one explicit list of what is allowed to leave the device.
public struct CloudRecord: Sendable, Equatable {
    public var id: String
    public var type: CloudRecordType
    /// CloudKit's change tag for the copy this was built from, when known.
    public var changeTag: String?
    public var fields: [String: CloudValue]

    public init(
        id: String, type: CloudRecordType, changeTag: String? = nil,
        fields: [String: CloudValue]
    ) {
        self.id = id
        self.type = type
        self.changeTag = changeTag
        self.fields = fields
    }
}

public struct CloudChangeSet: Sendable {
    public var changed: [CloudRecord]
    public var deletedIDs: [String]
    public var newToken: Data?
    public var moreComing: Bool

    public init(
        changed: [CloudRecord] = [], deletedIDs: [String] = [],
        newToken: Data? = nil, moreComing: Bool = false
    ) {
        self.changed = changed
        self.deletedIDs = deletedIDs
        self.newToken = newToken
        self.moreComing = moreComing
    }
}

/// Translates between the local model and cloud records.
///
/// This type is the single place that decides what leaves the device. Feed
/// URLs, Keychain references and guest-identifying free text are deliberately
/// absent from every mapping, and a test asserts they stay absent.
public enum CloudRecordMapper {

    // MARK: Property

    public static func record(for property: Property, modifiedAt: Date) -> CloudRecord? {
        guard let id = property.id else { return nil }
        return CloudRecord(id: "property-\(id)", type: .property, fields: [
            "localID": .number(Double(id)),
            "name": .string(property.name),
            "address": .string(property.address),
            "notes": .string(property.notes),
            "modifiedAt": .date(modifiedAt),
        ])
    }

    public static func property(from record: CloudRecord) -> (Property, Date)? {
        guard record.type == .property,
              let name = record.fields["name"]?.stringValue else { return nil }
        let localID = record.fields["localID"]?.doubleValue.map { Int64($0) }
        let modified = record.fields["modifiedAt"]?.dateValue ?? Date(timeIntervalSince1970: 0)
        return (
            Property(
                id: localID,
                name: name,
                address: record.fields["address"]?.stringValue ?? "",
                notes: record.fields["notes"]?.stringValue ?? ""
            ),
            modified
        )
    }

    // MARK: Listing

    /// Note what is **not** here: `icalURL` and `credentialRef`.
    ///
    /// A feed URL is a bearer credential for the owner's whole booking
    /// calendar. It stays in each device's Keychain and is set up per device.
    /// The cloud record carries only enough to show the listing on the phone.
    public static func record(for listing: PlatformListing, modifiedAt: Date) -> CloudRecord? {
        guard let id = listing.id else { return nil }
        return CloudRecord(id: "listing-\(id)", type: .listing, fields: [
            "localID": .number(Double(id)),
            "propertyID": .number(Double(listing.propertyID)),
            "platform": .string(listing.platform.rawValue),
            "label": .string(listing.label),
            "autoRefreshEnabled": .boolean(listing.autoRefreshEnabled),
            "lastSyncAt": .date(listing.lastSyncAt ?? Date(timeIntervalSince1970: 0)),
            "lastSyncSummary": .string(listing.lastSyncSummary),
            "modifiedAt": .date(modifiedAt),
        ])
    }

    public static func listing(from record: CloudRecord) -> (PlatformListing, Date)? {
        guard record.type == .listing,
              let propertyID = record.fields["propertyID"]?.doubleValue,
              let platformRaw = record.fields["platform"]?.stringValue,
              let platform = RentalPlatform(rawValue: platformRaw) else { return nil }
        let modified = record.fields["modifiedAt"]?.dateValue ?? Date(timeIntervalSince1970: 0)
        let lastSync = record.fields["lastSyncAt"]?.dateValue
        return (
            PlatformListing(
                id: record.fields["localID"]?.doubleValue.map { Int64($0) },
                propertyID: Int64(propertyID),
                platform: platform,
                label: record.fields["label"]?.stringValue ?? platform.displayName,
                icalURL: "",
                urlStorage: .keychain,
                credentialRef: "",
                autoRefreshEnabled: record.fields["autoRefreshEnabled"]?.boolValue ?? true,
                lastSyncAt: (lastSync?.timeIntervalSince1970 ?? 0) > 0 ? lastSync : nil,
                lastSyncSummary: record.fields["lastSyncSummary"]?.stringValue ?? ""
            ),
            modified
        )
    }

    // MARK: Event

    /// `details` is omitted on purpose: for a confirmed booking it holds the
    /// guest's phone digits and reservation link, and the phone does not need
    /// them to draw a calendar.
    public static func record(for event: CalendarEvent, listingID: Int64) -> CloudRecord {
        CloudRecord(id: "event-\(event.eventKey)", type: .event, fields: [
            "eventKey": .string(event.eventKey),
            "listingID": .number(Double(listingID)),
            "uid": .string(event.uid),
            "platform": .string(event.platform.rawValue),
            "summary": .string(event.summary),
            "checkIn": .date(event.checkIn),
            "checkOut": .date(event.checkOut),
            "isAllDay": .boolean(event.isAllDay),
            "feedStatus": .string(event.feedStatus.rawValue),
            "contentHash": .string(event.contentHash),
            "isTombstoned": .boolean(event.isTombstoned),
            "lastSeenAt": .date(event.lastSeenAt),
        ])
    }

    public static func event(from record: CloudRecord) -> CalendarEvent? {
        guard record.type == .event,
              let eventKey = record.fields["eventKey"]?.stringValue,
              let listingID = record.fields["listingID"]?.doubleValue,
              let checkIn = record.fields["checkIn"]?.dateValue,
              let checkOut = record.fields["checkOut"]?.dateValue,
              let platformRaw = record.fields["platform"]?.stringValue,
              let platform = RentalPlatform(rawValue: platformRaw) else { return nil }
        return CalendarEvent(
            listingID: Int64(listingID),
            eventKey: eventKey,
            uid: record.fields["uid"]?.stringValue ?? eventKey,
            platform: platform,
            summary: record.fields["summary"]?.stringValue ?? "",
            details: "",
            checkIn: checkIn,
            checkOut: checkOut,
            isAllDay: record.fields["isAllDay"]?.boolValue ?? true,
            feedStatus: FeedEventStatus(
                rawValue: record.fields["feedStatus"]?.stringValue ?? "confirmed"
            ) ?? .confirmed,
            contentHash: record.fields["contentHash"]?.stringValue ?? "",
            lastSeenAt: record.fields["lastSeenAt"]?.dateValue ?? Date(timeIntervalSince1970: 0),
            isTombstoned: record.fields["isTombstoned"]?.boolValue ?? false
        )
    }

    // MARK: Classification — the one that matters

    public static func record(
        for classification: EventClassification, deviceID: String
    ) -> CloudRecord {
        CloudRecord(id: "classification-\(classification.eventKey)", type: .classification, fields: [
            "eventKey": .string(classification.eventKey),
            "kind": .string(classification.kind.rawValue),
            "confidence": .string(classification.confidence.rawValue),
            "source": .string(classification.source.rawValue),
            "needsReview": .boolean(classification.needsReview),
            "rationale": .string(classification.rationale),
            "note": .string(classification.note),
            "exportApproved": .boolean(classification.exportApproved),
            "exportSuppressed": .boolean(classification.exportSuppressed),
            "decidedAt": .date(classification.decidedAt),
            "deviceID": .string(deviceID),
        ])
    }

    public static func classification(
        from record: CloudRecord
    ) -> (EventClassification, deviceID: String)? {
        guard record.type == .classification,
              let eventKey = record.fields["eventKey"]?.stringValue,
              let kindRaw = record.fields["kind"]?.stringValue,
              let kind = BlockKind(rawValue: kindRaw) else { return nil }
        let classification = EventClassification(
            eventKey: eventKey,
            kind: kind,
            confidence: ClassificationConfidence(
                rawValue: record.fields["confidence"]?.stringValue ?? "low"
            ) ?? .low,
            source: ClassificationSource(
                rawValue: record.fields["source"]?.stringValue ?? "automatic"
            ) ?? .automatic,
            needsReview: record.fields["needsReview"]?.boolValue ?? true,
            rationale: record.fields["rationale"]?.stringValue ?? "",
            note: record.fields["note"]?.stringValue ?? "",
            exportApproved: record.fields["exportApproved"]?.boolValue ?? false,
            exportSuppressed: record.fields["exportSuppressed"]?.boolValue ?? false,
            decidedAt: record.fields["decidedAt"]?.dateValue ?? Date(timeIntervalSince1970: 0)
        )
        return (classification, record.fields["deviceID"]?.stringValue ?? "")
    }

    /// Field names that must never appear in any cloud record. Asserted by a test.
    public static let forbiddenFieldNames: Set<String> = [
        "icalURL", "ical_url", "credentialRef", "credential_ref", "url", "feedURL",
        "details", "description", "guestName", "phone", "email",
    ]
}
