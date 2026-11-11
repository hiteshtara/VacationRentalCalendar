import Foundation
import VRCCore

// Applies a migration file to a private Aurora cluster over the RDS Data API.
//
//   vrc-migrate --dry-run Migrations/postgres/010_repository_schema.sql
//   vrc-migrate --apply   Migrations/postgres/010_repository_schema.sql
//   vrc-migrate --status
//
// WHY THIS EXISTS
//
// The cluster has no public access, sits in private subnets with no internet
// route, and its security group has no ingress rule. There is deliberately no
// way to reach it over the network — so psql cannot, and neither can a
// bastion, a VPN or an SSH tunnel, because none of those exist.
//
// The Data API is not a network path into the VPC: it is a regional AWS
// service endpoint that executes SQL on your behalf, authorised by IAM and
// SigV4. That is how migrations run here. Nothing is exposed, nothing is
// tunnelled, and the database password is never handled by this tool — the
// Data API reads it from Secrets Manager by ARN.
//
// Statements are sent one at a time, which is the Data API's only mode, so the
// file is split by SQLScanner. That splitter understands dollar-quoted
// function bodies; one that did not would shred every CREATE FUNCTION into
// fragments and leave a half-built schema.

let arguments = Array(CommandLine.arguments.dropFirst())
let dryRun = arguments.contains("--dry-run")
let apply = arguments.contains("--apply")
let statusOnly = arguments.contains("--status")
let files = arguments.filter { !$0.hasPrefix("--") }

func bail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard dryRun || apply || statusOnly else {
    bail("pass --dry-run, --apply or --status")
}

let environment = ProcessInfo.processInfo.environment
let configuration: DataAPIStore.Configuration
do {
    var c = try DataAPIStore.Configuration.fromEnvironment(environment)
    // Migrations are DDL. They run as the cluster's own administrative
    // identity, not as the restricted runtime role, which has no DDL rights by
    // design. Set VRC_DB_SECRET_ARN to the master secret for a migration and
    // back to the runtime secret afterwards.
    c.actor = "admin"
    configuration = c
} catch {
    bail("""
        not configured: \(error)

          export VRC_CLUSTER_ARN=arn:aws:rds:us-east-1:…:cluster:vrc-staging-main
          export VRC_DB_SECRET_ARN=…:secret:vrc-staging/database/master
          export VRC_DB_NAME=vrc

        Credentials come from the usual AWS chain; the database password is
        never read by this tool.
        """)
}

let transport: URLSessionDataAPITransport
do {
    transport = try URLSessionDataAPITransport.fromEnvironment(environment)
} catch {
    bail("no AWS credentials available: \(error)")
}
let store = DataAPIStore(transport: transport, configuration: configuration)

func appliedVersions() -> [Int] {
    (try? store.query("SELECT version FROM schema_migrations ORDER BY version"))?
        .compactMap { $0.int("version").map(Int.init) } ?? []
}

if statusOnly {
    let versions = appliedVersions()
    print("cluster:    \(configuration.resourceArn.split(separator: ":").last ?? "?")")
    print("database:   \(configuration.database)")
    print("migrations: \(versions.isEmpty ? "none applied" : versions.map(String.init).joined(separator: ", "))")
    exit(0)
}

guard !files.isEmpty else { bail("name at least one .sql file") }

for file in files {
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
        bail("cannot read \(file)")
    }
    let name = (file as NSString).lastPathComponent
    let statements = SQLScanner.splitStatements(text)

    // Every statement must have balanced dollar-quote markers. An unbalanced
    // one means the splitter cut a function body in half, and applying that
    // would leave a partial schema.
    let malformed = statements.enumerated().filter {
        $0.element.components(separatedBy: "$$").count % 2 == 0
    }
    guard malformed.isEmpty else {
        bail("""
            refusing to run \(name): \(malformed.count) statement(s) have unbalanced $$,
            which means a function body was split. Nothing was applied.
            """)
    }

    print("── \(name): \(statements.count) statement(s)")

    if dryRun {
        for (index, statement) in statements.enumerated() {
            let firstLine = statement
                .split(separator: "\n")
                .first { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
                .map(String.init) ?? statement
            print(String(format: "   %3d  %@", index + 1,
                         String(firstLine.trimmingCharacters(in: .whitespaces).prefix(76))))
        }
        continue
    }

    // BEGIN/COMMIT inside the file would fight the Data API's own transaction,
    // which is managed here instead.
    let executable = statements.filter {
        let head = $0.uppercased()
        return head != "BEGIN" && head != "COMMIT" && head != "END"
    }

    var completed = 0
    do {
        try store.transaction {
            for statement in executable {
                _ = try store.run(statement)
                completed += 1
            }
        }
        print("   applied \(completed) statement(s)")
    } catch let error as DataAPIError {
        if case .indeterminate(let detail) = error {
            // The one outcome that must not be guessed at.
            bail("""
                the migration's outcome is UNKNOWN after \(completed) statement(s): \(detail)

                Do not re-run blindly. Check what landed first:
                  vrc-migrate --status
                PostgreSQL DDL is transactional, so an aborted transaction
                applied nothing — but an unconfirmed COMMIT may have applied
                everything.
                """)
        }
        bail("""
            failed at statement \(completed + 1) of \(executable.count): \
            \(error.errorDescription ?? "\(error)")

            PostgreSQL DDL is transactional and this ran inside one
            transaction, so nothing was applied.
            """)
    } catch {
        bail("failed at statement \(completed + 1): \(error)")
    }
}

if apply {
    print("")
    print("migrations now applied: \(appliedVersions().map(String.init).joined(separator: ", "))")
}
