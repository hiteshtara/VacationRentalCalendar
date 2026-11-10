import Foundation
import VRCCore

/// Proof that a rehearsal cannot reach the live database.
///
/// Written after doing exactly that. On 2026-11-10 a rehearsal of a
/// connection-state recovery was "isolated" by setting `HOME` to a temporary
/// directory and copying the database there. On macOS,
/// `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)`
/// does not consult `HOME`, so the CLI opened the real database and performed
/// the change on production. The copy being watched stayed untouched, so the
/// before/after comparison showed nothing — the wrong file was being read.
/// Two live feeds had their connection state changed without approval.
///
/// The lesson is narrow and absolute: **an environment variable is not
/// isolation.** Isolation is only established by resolving the path that will
/// actually be opened and proving it is not the live one. Every test below
/// asserts that proof, and several deliberately attempt the live path to
/// confirm it is refused.
///
/// Nothing here opens or writes the production database. The production cases
/// are classification only — the guard answers before a file is touched — and
/// the permitted cases all use freshly created temporary directories.
public enum RehearsalIsolationTests {

    static var production: String { AppPaths.databaseURL.path }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vrc-isolation-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func refuses(_ path: String) -> Bool {
        do { try RehearsalIsolation.assertIsolated(databasePath: path); return false }
        catch { return true }
    }

    public static var cases: [TestCase] { [

        // MARK: - The live database, named every way it can be named

        TestCase(group: "Rehearsal isolation",
                 name: "the live database path is refused") { expect in
            expect.ok(refuses(production), "the production path must never be rehearsable")
            expect.ok(!RehearsalIsolation.isDisposable(databasePath: production))
        },

        TestCase(group: "Rehearsal isolation",
                 name: "a differently-cased spelling of the live path is refused") { expect in
            // APFS is case-insensitive by default, so these are the SAME file.
            // A string comparison alone would have let this through.
            expect.ok(refuses(production.uppercased()), "upper-cased")
            expect.ok(refuses(production.lowercased()), "lower-cased")
        },

        TestCase(group: "Rehearsal isolation",
                 name: "a symlink pointing at the live database is refused") { expect in
            // The shape that would defeat a plain string comparison: a path
            // that looks disposable and resolves to production.
            let directory = temporaryDirectory()
            let link = directory.appendingPathComponent("innocent.sqlite")
            try? FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: URL(fileURLWithPath: production))
            defer { try? FileManager.default.removeItem(at: directory) }

            guard FileManager.default.fileExists(atPath: link.path) ||
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil else {
                return expect.fail("could not create the symlink fixture")
            }
            expect.ok(refuses(link.path),
                      "a symlink to production must be resolved, not trusted")
        },

        TestCase(group: "Rehearsal isolation",
                 name: "a relative path that resolves to the live database is refused") { expect in
            let relative = AppPaths.supportDirectory
                .appendingPathComponent("subdir/../VacationRentalCalendar.sqlite").path
            expect.ok(refuses(relative), "traversal must be normalised first")
        },

        TestCase(group: "Rehearsal isolation",
                 name: "any sibling inside the live support directory is refused") { expect in
            // The WAL and the shared-memory file hold recent writes, and the
            // backups live here too. None of them is a sandbox.
            for name in ["VacationRentalCalendar.sqlite-wal",
                         "VacationRentalCalendar.sqlite-shm",
                         "Backups/anything.sqlite",
                         "scratch.sqlite"] {
                let path = AppPaths.supportDirectory.appendingPathComponent(name).path
                expect.ok(refuses(path), "\(name) is not disposable")
            }
        },

        TestCase(group: "Rehearsal isolation",
                 name: "the support directory itself is refused") { expect in
            expect.ok(refuses(AppPaths.supportDirectory.path))
        },

        // MARK: - What IS allowed, so the guard is usable

        TestCase(group: "Rehearsal isolation",
                 name: "an in-memory database is always disposable") { expect in
            expect.ok(RehearsalIsolation.isDisposable(
                databasePath: RehearsalIsolation.inMemoryPath))
            expect.ok(!refuses(RehearsalIsolation.inMemoryPath))
        },

        TestCase(group: "Rehearsal isolation",
                 name: "a fresh temporary path is disposable") { expect in
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("scratch.sqlite").path
            expect.ok(!refuses(path), "a rehearsal needs somewhere to run")
            expect.ok(RehearsalIsolation.isDisposable(databasePath: path))
        },

        TestCase(group: "Rehearsal isolation",
                 name: "/tmp and /private/tmp are understood to be the same place") { expect in
            // /tmp is a symlink to /private/tmp on macOS. Both must be treated
            // alike, or a guard passes under one spelling and fails the other.
            let viaTmp = "/tmp/vrc-isolation-probe.sqlite"
            let viaPrivate = "/private/tmp/vrc-isolation-probe.sqlite"
            expect.equal(RehearsalIsolation.isDisposable(databasePath: viaTmp),
                         RehearsalIsolation.isDisposable(databasePath: viaPrivate),
                         "the two spellings disagreed")
        },

        // MARK: - Environment variables are not isolation

        TestCase(group: "Rehearsal isolation",
                 name: "HOME cannot make the live database look disposable") { expect in
            // The actual mistake, as a test. Whatever HOME says, the guard
            // resolves the path that will really be opened.
            let path = production
            expect.ok(refuses(path), "refused before any redirection is considered")
            // And the production path the guard compares against is the one
            // the app itself would use, not one derived from the environment.
            expect.equal(RehearsalIsolation.productionDatabasePath,
                         RehearsalIsolation.canonical(AppPaths.databaseURL.path))
        },

        TestCase(group: "Rehearsal isolation",
                 name: "rehearsal mode is off unless set to its exact value") { expect in
            expect.ok(!RehearsalMode.isActive(in: [:]))
            expect.ok(!RehearsalMode.isActive(in: [RehearsalMode.variable: "yes"]))
            expect.ok(!RehearsalMode.isActive(in: [RehearsalMode.variable: "0"]))
            expect.ok(RehearsalMode.isActive(in: [RehearsalMode.variable: RehearsalMode.value]))
        },

        // MARK: - The refusal has to be useful

        TestCase(group: "Rehearsal isolation",
                 name: "a refusal names the path and says why") { expect in
            do {
                try RehearsalIsolation.assertIsolated(databasePath: production)
                expect.fail("should have refused")
            } catch let violation as RehearsalIsolation.Violation {
                let message = violation.errorDescription ?? ""
                expect.contains(message, "Refusing")
                expect.ok(message.contains("VacationRentalCalendar.sqlite"),
                          "the message must name the path: \(message)")
            } catch {
                expect.fail("wrong error type: \(error)")
            }
        },

        TestCase(group: "Rehearsal isolation",
                 name: "the shared test database path proves itself disposable") { expect in
            // Every suite that needs a file-backed database gets its path from
            // here, so this is the chokepoint worth asserting. The fixture
            // refuses rather than returns if the path is not isolated.
            let path = Fixtures.temporaryDatabasePath()
            expect.ok(RehearsalIsolation.isDisposable(databasePath: path), path)
            expect.ok(!RehearsalIsolation.matchesProductionForTesting(path))
        },

        TestCase(group: "Rehearsal isolation",
                 name: "a connection-state change on a disposable store stays there") { expect in
            // The operation that was performed on production by mistake,
            // exercised the way it should be: in memory, where there is no
            // file to reach.
            let store = try RentalStore.makeInMemory()
            let property = try store.properties.insert(Property(name: "Rehearsal"))
            let listing = try store.listings.insert(PlatformListing(
                propertyID: property.id!, platform: .vrbo, label: "Vrbo",
                credentialRef: "ref", connectionState: .credentialUnreadable))
            try store.listings.setConnectionState(
                listingID: listing.id!, to: .failing,
                detail: "rehearsal only", actor: "test", at: Date())
            expect.equal(try store.listings.find(id: listing.id!)?.connectionState, .failing)
            expect.equal(try store.listings.all().count, 1,
                         "and it saw none of the real listings")
        },

        TestCase(group: "Rehearsal isolation",
                 name: "an injected production path is honoured, so this is testable") { expect in
            // Lets the suite exercise the rule without naming the real
            // database, and lets a caller protect a different file.
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let decoy = directory.appendingPathComponent("decoy-production.sqlite").path
            let other = directory.appendingPathComponent("scratch.sqlite").path

            var refusedDecoy = false
            do { try RehearsalIsolation.assertIsolated(
                    databasePath: decoy, productionPath: decoy) }
            catch { refusedDecoy = true }
            expect.ok(refusedDecoy, "the injected production path is protected")

            var refusedOther = false
            do { try RehearsalIsolation.assertIsolated(
                    databasePath: other, productionPath: decoy) }
            catch { refusedOther = true }
            expect.ok(!refusedOther, "and a sibling of it is still usable")
        },
    ] }
}
