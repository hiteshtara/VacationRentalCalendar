import Foundation
import VRCCore

/// The guard that stands between the truncating integration setup and a
/// database somebody cares about.
///
/// This exists because the PostgreSQL integration suite was pointed at the
/// shared staging cluster on 2026-11-09 and emptied it. The suite's setup is
/// *supposed* to truncate — that is how it compares a known workflow against a
/// known starting point — so the fix is not to soften the setup but to make it
/// impossible to aim at anything that is not demonstrably disposable.
///
/// Every test below is a refusal, except the three that prove a genuine
/// sandbox is still allowed. A guard that refuses everything would be useless
/// in a way no refusal test could detect, which is what those three are for.
public enum DestructiveIsolationTests {

    /// Full consent, so each test can remove exactly one thing and show that
    /// the removal alone is enough to be refused.
    static var consenting: [String: String] {
        [DestructiveTestIsolation.consentVariable: DestructiveTestIsolation.consentValue]
    }

    static func marked() throws -> String? { "true" }

    /// One row, one column named `value` — the shape the Data API returns for
    /// the marker SELECT.
    static func marker(_ value: String) -> RecordingDataAPITransport.Scripted {
        .init(statusCode: 200, payload: [
            "columnMetadata": [["name": "value"]],
            "records": [[["stringValue": value]]],
            "numberOfRecordsUpdated": 1,
        ])
    }
    static func unmarked() throws -> String? { nil }

    struct Unreachable: Error {}

    /// Asserts that `body` refuses, and refuses with `expected`.
    ///
    /// Which refusal matters: a guard that threw "no consent" when handed a
    /// production cluster would pass a weaker test while leaving the real
    /// danger — a consented production truncation — unguarded.
    static func refuses(
        _ expect: Expect, _ expected: DestructiveTestIsolation.Refusal,
        _ label: String, _ body: () throws -> Void
    ) {
        do {
            try body()
            expect.fail("\(label): must refuse, but it allowed the truncation")
        } catch let refusal as DestructiveTestIsolation.Refusal {
            expect.equal(refusal, expected, label)
        } catch {
            expect.fail("\(label): refused with the wrong error type: \(error)")
        }
    }

    public static var cases: [TestCase] { [

        // --- Operator consent ---

        TestCase(group: "Destructive test isolation",
                 name: "with no consent variable set, nothing is truncated") { expect in
            refuses(expect, .noOperatorConsent, "an empty environment") {
                try DestructiveTestIsolation.assertDisposable(
                    .cluster(identifier: "vrc-scratch-1"),
                    environment: [:], marker: marked)
            }
        },

        TestCase(group: "Destructive test isolation",
                 name: "a near-miss consent value is not consent") { expect in
            // The value is deliberately a sentence rather than "1" or "true",
            // so it cannot be set by muscle memory or by a CI template that
            // turns on every VRC_ variable it finds.
            for wrong in ["1", "true", "yes", "I-UNDERSTAND-THIS-TRUNCATES", ""] {
                refuses(expect, .noOperatorConsent, "consent value \"\(wrong)\"") {
                    try DestructiveTestIsolation.assertDisposable(
                        .cluster(identifier: "vrc-scratch-1"),
                        environment: [DestructiveTestIsolation.consentVariable: wrong],
                        marker: marked)
                }
            }
        },

        // --- The deny-list, which nothing overrides ---

        TestCase(group: "Destructive test isolation",
                 name: "the real staging cluster is refused with full consent and a marker") { expect in
            // The exact mistake of 2026-11-09, now unrepeatable. Consent is
            // given and the database claims to be disposable, and it is still
            // refused, because the identifier is on the deny-list and the
            // deny-list is not negotiable.
            refuses(expect, .protectedTarget("vrc-staging-main"), "vrc-staging-main") {
                try DestructiveTestIsolation.assertDisposable(
                    .cluster(identifier: "vrc-staging-main"),
                    environment: consenting, marker: marked)
            }
        },

        TestCase(group: "Destructive test isolation",
                 name: "a protected name is still protected with a disposable suffix") { expect in
            // Renaming your way past the guard: appending an allow-listed
            // suffix to a protected identifier must not work, or the deny-list
            // is decoration.
            for sneaky in ["vrc-staging-main-scratch", "vrc-staging-main-disposable",
                           "copy-of-vrc-staging-main", "VRC-STAGING-MAIN-throwaway"] {
                refuses(expect, .protectedTarget(sneaky), sneaky) {
                    try DestructiveTestIsolation.assertDisposable(
                        .cluster(identifier: sneaky),
                        environment: consenting, marker: marked)
                }
            }
        },

        TestCase(group: "Destructive test isolation",
                 name: "anything that looks like production is refused") { expect in
            for production in ["vrc-prod-main", "vrc-production", "priyankahomes-bookings",
                              "PriyankaHomes-Calendar", "vrc-live-main"] {
                refuses(expect, .protectedTarget(production), production) {
                    try DestructiveTestIsolation.assertDisposable(
                        .cluster(identifier: production),
                        environment: consenting, marker: marked)
                }
            }
        },

        TestCase(group: "Destructive test isolation",
                 name: "a protected local database is refused too") { expect in
            // The local path is not a safe harbour: a port-forward or an SSH
            // tunnel can put a shared cluster behind 127.0.0.1.
            refuses(expect, .protectedTarget("127.0.0.1:54407/vrc-staging-main"),
                    "a tunnelled staging database") {
                try DestructiveTestIsolation.assertDisposable(
                    .local(label: "127.0.0.1:54407/vrc-staging-main"),
                    environment: consenting, marker: marked)
            }
        },

        // --- A cluster must name itself disposable ---

        TestCase(group: "Destructive test isolation",
                 name: "a cluster not named disposable is refused, even unknown ones") { expect in
            // Allow-list, not deny-list, in the house style: an identifier
            // nobody has thought about is refused by default rather than
            // allowed by default.
            for unknown in ["vrc-experiment", "some-other-cluster", "vrc-staging-2", ""] {
                refuses(expect, .clusterNotNamedDisposable(unknown), "cluster \"\(unknown)\"") {
                    try DestructiveTestIsolation.assertDisposable(
                        .cluster(identifier: unknown),
                        environment: consenting, marker: marked)
                }
            }
        },

        // --- The database's own consent ---

        TestCase(group: "Destructive test isolation",
                 name: "a database carrying no disposable marker is refused") { expect in
            // The marker lives in the target database, so it travels with the
            // database rather than with the invocation. A shared cluster does
            // not have one, and cannot acquire one by accident.
            refuses(expect, .notMarkedDisposable("vrc-scratch-1"), "no marker row") {
                try DestructiveTestIsolation.assertDisposable(
                    .cluster(identifier: "vrc-scratch-1"),
                    environment: consenting, marker: unmarked)
            }
        },

        TestCase(group: "Destructive test isolation",
                 name: "a marker that does not say true is refused") { expect in
            for value in ["false", "maybe", "0", "", "yes"] {
                refuses(expect, .notMarkedDisposable("vrc-scratch-1"), "marker \"\(value)\"") {
                    try DestructiveTestIsolation.assertDisposable(
                        .cluster(identifier: "vrc-scratch-1"),
                        environment: consenting, marker: { value })
                }
            }
        },

        TestCase(group: "Destructive test isolation",
                 name: "an unreadable marker refuses — it never assumes") { expect in
            // Fail closed. If the guard cannot read the marker it must not
            // guess, because the one guess that matters is the wrong one.
            refuses(expect, .markerUnreadable("vrc-scratch-1"), "the marker query threw") {
                try DestructiveTestIsolation.assertDisposable(
                    .cluster(identifier: "vrc-scratch-1"),
                    environment: consenting, marker: { throw Unreachable() })
            }
        },

        // --- And a genuine sandbox is still allowed ---

        TestCase(group: "Destructive test isolation",
                 name: "a disposable cluster with consent and a marker is allowed") { expect in
            for sandbox in ["vrc-scratch-1", "vrc-staging-pitr", "vrc-throwaway",
                            "vrc-disposable-ci"] {
                do {
                    try DestructiveTestIsolation.assertDisposable(
                        .cluster(identifier: sandbox),
                        environment: consenting, marker: marked)
                    expect.ok(true, "\(sandbox) is allowed")
                } catch {
                    expect.fail("\(sandbox) should be allowed, got: \(error)")
                }
            }
        },

        TestCase(group: "Destructive test isolation",
                 name: "a local throwaway database with consent and a marker is allowed") { expect in
            do {
                try DestructiveTestIsolation.assertDisposable(
                    .local(label: "127.0.0.1:54407/vrc"),
                    environment: consenting, marker: marked)
                expect.ok(true, "a local test cluster is allowed")
            } catch {
                expect.fail("a local test cluster should be allowed, got: \(error)")
            }
        },

        TestCase(group: "Destructive test isolation",
                 name: "every refusal explains itself in the error text") { expect in
            // These messages are the only thing a person sees when the suite
            // stops, so they have to say what to do, not just that something
            // was refused.
            let refusals: [DestructiveTestIsolation.Refusal] = [
                .noOperatorConsent,
                .protectedTarget("vrc-staging-main"),
                .clusterNotNamedDisposable("vrc-experiment"),
                .notMarkedDisposable("vrc-scratch-1"),
                .markerUnreadable("vrc-scratch-1"),
            ]
            for refusal in refusals {
                let text = refusal.errorDescription ?? ""
                expect.ok(text.count > 40, "has a real explanation")
                // Interpolation must show the explanation too. The harness
                // prints "threw: \(error)", so without this the operator sees
                // only a case name like "noOperatorConsent" and has to go
                // reading source to find out what to do about it.
                expect.equal("\(refusal)", text,
                             "interpolating a refusal shows the explanation")
                expect.ok(text.lowercased().contains("truncat")
                            || text.lowercased().contains("disposable")
                            || text.lowercased().contains("delete"),
                          "\(refusal) says what is at stake")
            }
        },

        // --- The wiring: the guard must sit BEFORE the deletes ---
        //
        // The tests above prove the guard answers correctly when asked. These
        // prove the truncating setup actually asks, and asks first. That is
        // the distinction that matters: on 2026-11-09 the deletes ran because
        // nothing stood in front of them, not because a check said yes.

        TestCase(group: "Destructive test isolation",
                 name: "the real staging cluster receives no DELETE at all") { expect in
            let transport = RecordingDataAPITransport(responses: [marker("true")])
            let store = DataAPIStore(
                transport: transport,
                configuration: .init(resourceArn: "arn:cluster", secretArn: "arn:secret",
                                     database: "vrc", actor: "owner"),
                sleeper: { _ in })
            do {
                try PostgresIntegrationTests.truncateForTest(
                    store, target: .cluster(identifier: "vrc-staging-main"),
                    environment: consenting)
                expect.fail("must refuse to truncate the shared staging cluster")
            } catch let refusal as DestructiveTestIsolation.Refusal {
                expect.equal(refusal, .protectedTarget("vrc-staging-main"))
            } catch {
                expect.fail("wrong error: \(error)")
            }
            let deletes = transport.executedSQL.filter {
                $0.uppercased().contains("DELETE")
            }
            expect.equal(deletes.count, 0,
                         "not one DELETE may reach a protected cluster, got: \(deletes)")
        },

        TestCase(group: "Destructive test isolation",
                 name: "without consent the setup deletes nothing anywhere") { expect in
            let transport = RecordingDataAPITransport(responses: [marker("true")])
            let store = DataAPIStore(
                transport: transport,
                configuration: .init(resourceArn: "arn:cluster", secretArn: "arn:secret",
                                     database: "vrc", actor: "owner"),
                sleeper: { _ in })
            do {
                try PostgresIntegrationTests.truncateForTest(
                    store, target: .cluster(identifier: "vrc-scratch-1"), environment: [:])
                expect.fail("must refuse without operator consent")
            } catch let refusal as DestructiveTestIsolation.Refusal {
                expect.equal(refusal, .noOperatorConsent)
            } catch {
                expect.fail("wrong error: \(error)")
            }
            expect.equal(transport.executedSQL.filter {
                $0.uppercased().contains("DELETE")
            }.count, 0, "no DELETE without consent")
        },

        TestCase(group: "Destructive test isolation",
                 name: "a genuine sandbox is still truncated — the door opens") { expect in
            // Without this, a guard that refused everything would satisfy
            // every test above while quietly disabling the integration suite.
            let transport = RecordingDataAPITransport(responses: [marker("true")])
            let store = DataAPIStore(
                transport: transport,
                configuration: .init(resourceArn: "arn:cluster", secretArn: "arn:secret",
                                     database: "vrc", actor: "owner"),
                sleeper: { _ in })
            do {
                try PostgresIntegrationTests.truncateForTest(
                    store, target: .cluster(identifier: "vrc-scratch-1"),
                    environment: consenting)
            } catch {
                expect.fail("a marked, consented sandbox must be truncated, got: \(error)")
                return
            }
            let deletes = transport.executedSQL.filter { $0.uppercased().contains("DELETE") }
            expect.equal(deletes.count, PostgresIntegrationTests.truncatedTables.count,
                         "every table in the list is emptied")
            expect.ok(transport.executedSQL.first?.uppercased().contains("SELECT") == true,
                      "and the marker was read before any of them")
        },

        TestCase(group: "Destructive test isolation",
                 name: "a missing cluster ARN is an empty identifier, which is refused") { expect in
            // Fail closed on the plumbing too: if the target cannot be
            // identified, it cannot be shown to be disposable.
            expect.equal(PostgresIntegrationTests.clusterIdentifier([:]), "")
            expect.equal(
                PostgresIntegrationTests.clusterIdentifier(
                    ["VRC_CLUSTER_ARN": "arn:aws:rds:us-east-1:589744711110:cluster:vrc-scratch-1"]),
                "vrc-scratch-1")
            refuses(expect, .clusterNotNamedDisposable(""), "an unidentifiable cluster") {
                try DestructiveTestIsolation.assertDisposable(
                    .cluster(identifier: PostgresIntegrationTests.clusterIdentifier([:])),
                    environment: consenting, marker: marked)
            }
        },
    ] }
}
