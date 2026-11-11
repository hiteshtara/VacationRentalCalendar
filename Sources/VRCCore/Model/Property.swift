import Foundation

/// One physical rental unit. Conflicts are detected per property, because two
/// listings on two platforms can describe the same bed.
public struct Property: Identifiable, Hashable, Sendable {
    public var id: Int64?
    public var name: String
    public var address: String
    public var notes: String
    /// The zone this property's nights are counted in, so "10–15 December"
    /// means the same nights wherever the owner happens to be. The column has
    /// existed since migration 10; it was not in this model until migration 13,
    /// which meant it could never actually be set.
    public var timeZone: String
    /// Set when the property leaves the active portfolio. Never deletion — the
    /// history has to stay explicable.
    public var archivedAt: Date?

    public var isArchived: Bool { archivedAt != nil }
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        name: String,
        address: String = "",
        notes: String = "",
        timeZone: String = "UTC",
        archivedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.notes = notes
        self.timeZone = timeZone
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
