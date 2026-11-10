import Foundation
import VRCCore

// Prints the authoritative SQLite schema, so
// Scripts/generate-postgres-schema.sh can derive the PostgreSQL tables from it
// rather than anyone maintaining a second copy by hand.
let path = "\(NSTemporaryDirectory())/vrc-schema-\(UUID().uuidString).sqlite"
let database = try Database(path: path)
_ = try Migrator.migrate(database)
for row in try database.query(
    "SELECT sql FROM sqlite_master WHERE type='table' AND sql IS NOT NULL ORDER BY name") {
    print(row.stringValue("sql") + ";")
}
database.close()
try? FileManager.default.removeItem(atPath: path)
