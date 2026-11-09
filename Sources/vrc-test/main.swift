import Foundation
import VRCTestSuite

// Runs the whole suite without Xcode. See VRCTestSuite/Harness.swift for why
// this exists rather than a plain `swift test`.

let arguments = Array(CommandLine.arguments.dropFirst())
let verbose = arguments.contains("--verbose") || arguments.contains("-v")
let listOnly = arguments.contains("--list")
let filter = arguments.first { !$0.hasPrefix("-") }

if listOnly {
    for testCase in TestRegistry.all {
        let tag = testCase.requirement.map { " [\($0)]" } ?? ""
        print("\(testCase.identifier)\(tag)")
    }
    exit(0)
}

let bold = "\u{1B}[1m", dim = "\u{1B}[2m", reset = "\u{1B}[0m"
let green = "\u{1B}[32m", red = "\u{1B}[31m"

print("\(bold)Vacation Rental Calendar — test suite\(reset)")
if let filter { print("\(dim)filter: \(filter)\(reset)") }
print("")

var currentGroup = ""
let outcomes = await TestRegistry.runAll(filter: filter) { outcome in
    if outcome.testCase.group != currentGroup {
        currentGroup = outcome.testCase.group
        print("\(bold)\(currentGroup)\(reset)")
    }
    let mark = outcome.passed ? "\(green)✓\(reset)" : "\(red)✗\(reset)"
    let milliseconds = Int(outcome.duration * 1000)
    print("  \(mark) \(outcome.testCase.name) \(dim)(\(outcome.checks) checks, \(milliseconds)ms)\(reset)")
    for failure in outcome.failures {
        print("      \(red)\(failure)\(reset)")
    }
}

let passed = outcomes.filter(\.passed).count
let failed = outcomes.count - passed
let checks = outcomes.reduce(0) { $0 + $1.checks }

print("")
if failed == 0 {
    print("\(green)\(bold)All \(passed) tests passed\(reset) (\(checks) assertions)")
} else {
    print("\(red)\(bold)\(failed) of \(outcomes.count) tests failed\(reset) (\(checks) assertions)")
    print("")
    for outcome in outcomes where !outcome.passed {
        print("\(red)FAILED\(reset) \(outcome.testCase.identifier)")
        for failure in outcome.failures { print("   \(failure)") }
    }
}

// Requirement coverage, so the brief's nine scenarios cannot silently vanish.
let covered = outcomes.compactMap { $0.passed ? $0.testCase.requirement : nil }.sorted()
if !covered.isEmpty && filter == nil {
    print("")
    print("\(dim)Brief requirements covered: \(covered.joined(separator: ", "))\(reset)")
}

exit(failed == 0 ? 0 : 1)
