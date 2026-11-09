import Foundation

/// One physical rental unit. Conflicts are detected per property, because two
/// listings on two platforms can describe the same bed.
public struct Property: Identifiable, Hashable, Sendable {
    public var id: Int64?
    public var name: String
    public var address: String
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        name: String,
        address: String = "",
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
