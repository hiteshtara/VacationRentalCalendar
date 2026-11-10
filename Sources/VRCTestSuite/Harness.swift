import Foundation

/// A very small test harness.
///
/// It exists because neither `XCTest` nor `swift-testing` ships with the Xcode
/// Command Line Tools — both live inside Xcode.app — so `swift test` cannot run
/// on a machine that has only the CLT installed. Keeping the assertions in a
/// plain library means they run anywhere Swift does, via `swift run vrc-test`,
/// and the thin XCTest bridge in `Tests/` replays the same registry for anyone
/// who does have Xcode.
public final class Expect {
    public private(set) var failures: [String] = []
    public private(set) var checks = 0
    private let caseName: String

    init(caseName: String) { self.caseName = caseName }

    public func ok(_ condition: Bool,
                   _ message: @autoclosure () -> String = "expected true, got false",
                   file: StaticString = #filePath, line: UInt = #line) {
        checks += 1
        if !condition {
            failures.append("\(message())  [\(shortFile(file)):\(line)]")
        }
    }

    public func equal<T: Equatable>(_ actual: T, _ expected: T,
                                    _ message: @autoclosure () -> String = "",
                                    file: StaticString = #filePath, line: UInt = #line) {
        checks += 1
        if actual != expected {
            let note = message().isEmpty ? "" : "\(message()): "
            failures.append("\(note)expected \(expected), got \(actual)  [\(shortFile(file)):\(line)]")
        }
    }

    public func contains(_ haystack: String, _ needle: String,
                         _ message: @autoclosure () -> String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
        checks += 1
        if !haystack.contains(needle) {
            let note = message().isEmpty ? "" : "\(message()): "
            failures.append("\(note)expected to find \"\(needle)\"  [\(shortFile(file)):\(line)]")
        }
    }

    public func notContains(_ haystack: String, _ needle: String,
                            _ message: @autoclosure () -> String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        checks += 1
        if haystack.contains(needle) {
            let note = message().isEmpty ? "" : "\(message()): "
            failures.append("\(note)did not expect to find \"\(needle)\"  [\(shortFile(file)):\(line)]")
        }
    }

    public func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        checks += 1
        failures.append("\(message)  [\(shortFile(file)):\(line)]")
    }

    private func shortFile(_ file: StaticString) -> String {
        URL(fileURLWithPath: "\(file)").lastPathComponent
    }
}

public struct TestCase: Sendable {
    public let group: String
    public let name: String
    /// Requirement this case covers, when it maps to one in the brief.
    public let requirement: String?
    public let body: @Sendable (Expect) async throws -> Void

    public init(
        group: String,
        name: String,
        requirement: String? = nil,
        body: @escaping @Sendable (Expect) async throws -> Void
    ) {
        self.group = group
        self.name = name
        self.requirement = requirement
        self.body = body
    }

    public var identifier: String { "\(group) / \(name)" }
}

public struct TestOutcome: Sendable {
    public let testCase: TestCase
    public let failures: [String]
    public let checks: Int
    public let duration: TimeInterval
    public var passed: Bool { failures.isEmpty }
}

public enum TestRegistry {
    /// Every test in the suite, in the order they should be read.
    public static var all: [TestCase] {
        MigrationTests.cases
            + ICalParsingTests.cases
            + SemanticHashTests.cases
            + SQLScannerTests.cases
            + DataStoreTests.cases
            + TransactionLifecycleTests.cases
            + DataStoreParityTests.cases
            + DestructiveIsolationTests.cases
            + EmptyCalendarTests.cases
            + CredentialReplacementTests.cases
            + BulkCancellationTests.cases
            + MultiPropertyTests.cases
            + FeedEndpointTests.cases
            + SigningTests.cases
            + PostgresIntegrationTests.cases
            + DecisionRouteTests.cases
            + CloudSyncClientTests.cases
            + CloudConnectionTests.cases
            + CloudIntervalTests.cases
            + CloudStatusPayloadTests.cases
            + LambdaHandlerTests.cases
            + ClassifierTests.cases
            + ImportTests.cases
            + ConflictTests.cases
            + ExportTests.cases
            + PresentationTests.cases
            + AvailabilityTests.cases
            + FeedGenerationTests.cases
            + PublicationSafetyTests.cases
            + ClassificationSafeguardTests.cases
            + ConnectionStateTests.cases
            + ConflictCategoryTests.cases
            + HostingTests.cases
            + ArchitectureReviewTests.cases
            + SecurityTests.cases
            + RequiredScenarioTests.cases
    }

    public static func run(_ testCase: TestCase) async -> TestOutcome {
        let expect = Expect(caseName: testCase.identifier)
        let start = Date()
        do {
            try await testCase.body(expect)
        } catch {
            expect.fail("threw: \(error)")
        }
        return TestOutcome(
            testCase: testCase,
            failures: expect.failures,
            checks: expect.checks,
            duration: Date().timeIntervalSince(start)
        )
    }

    public static func runAll(
        filter: String? = nil,
        onResult: @Sendable (TestOutcome) -> Void = { _ in }
    ) async -> [TestOutcome] {
        var outcomes: [TestOutcome] = []
        for testCase in all {
            if let filter, !testCase.identifier.lowercased().contains(filter.lowercased()) {
                continue
            }
            let outcome = await run(testCase)
            onResult(outcome)
            outcomes.append(outcome)
        }
        return outcomes
    }
}
