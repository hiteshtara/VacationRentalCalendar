import Foundation

/// Small key/value store for app preferences that belong with the data rather
/// than in UserDefaults (refresh interval, export window, the outbound gate).
public struct SettingsRepository: Sendable {
    let database: Database
    public init(database: Database) { self.database = database }

    public func set(_ key: String, _ value: String) throws {
        try database.run("""
            INSERT INTO app_settings (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """, [.text(key), .text(value)])
    }

    public func set(_ key: String, _ value: Int) throws { try set(key, String(value)) }
    public func set(_ key: String, _ value: Bool) throws { try set(key, value ? "1" : "0") }

    public func string(_ key: String) throws -> String? {
        try database.queryOne("SELECT value FROM app_settings WHERE key = ?;", [.text(key)])?
            .string("value")
    }

    public func int(_ key: String, default fallback: Int) throws -> Int {
        guard let raw = try string(key), let value = Int(raw) else { return fallback }
        return value
    }

    public func bool(_ key: String, default fallback: Bool) throws -> Bool {
        guard let raw = try string(key) else { return fallback }
        return raw == "1" || raw.lowercased() == "true"
    }
}

/// Setting keys, in one place so a typo cannot silently create a second setting.
public enum SettingKey {
    public static let autoRefreshMinutes = "auto_refresh_minutes"
    public static let autoRefreshEnabled = "auto_refresh_enabled"
    public static let exportHorizonDays = "export_horizon_days"
    public static let notifyOnConflict = "notify_on_conflict"
    public static let notifyOnNeedsReview = "notify_on_needs_review"
    /// The outbound kill switch. See `OutboundSyncGate` — flipping this alone
    /// does not enable anything, because no outbound code path exists yet.
    public static let outboundSyncRequested = "outbound_sync_requested"
}
