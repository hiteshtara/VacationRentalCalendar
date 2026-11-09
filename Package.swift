// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VacationRentalCalendar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VacationRentalCalendar", targets: ["VacationRentalCalendar"]),
        .executable(name: "vrc-test", targets: ["vrc-test"]),
        .executable(name: "vrc", targets: ["vrc"]),
        .executable(name: "vrc-parity", targets: ["vrc-parity"]),
        .executable(name: "vrc-schema-dump", targets: ["vrc-schema-dump"]),
        .library(name: "VRCLambda", targets: ["VRCLambda"]),
        .executable(name: "vrc-lambda-fetch", targets: ["vrc-lambda-fetch"]),
        .executable(name: "vrc-lambda-process", targets: ["vrc-lambda-process"]),
        .executable(name: "vrc-lambda-publish", targets: ["vrc-lambda-publish"]),
        .executable(name: "vrc-lambda-api", targets: ["vrc-lambda-api"]),
        .executable(name: "vrc-lambda-sweeper", targets: ["vrc-lambda-sweeper"]),
        .library(name: "VRCCore", targets: ["VRCCore"]),
    ],
    dependencies: [
        // Used only on platforms without CryptoKit. The API is
        // source-compatible, so the signing and hashing code is identical on
        // both: an AWS SigV4 signature that differs by one byte is rejected,
        // and the iCal event keys are persisted, so "equivalent" is not good
        // enough -- it has to be the same algorithm, same encoding.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        // Everything testable. No UI, no third-party dependencies.
        // Surfaces the system SQLite to Linux, which has no SQLite3 Swift
        // module. Not built on Apple platforms.
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        // Everything testable. No UI.
        .target(
            name: "VRCCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto",
                         condition: .when(platforms: [.linux])),
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ],
            path: "Sources/VRCCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The canonical test suite. Plain Swift so it runs without Xcode.
        .target(
            name: "VRCTestSuite",
            dependencies: ["VRCCore", "VRCLambda"],
            path: "Sources/VRCTestSuite"
        ),
        // Front-end that runs the suite from the command line.
        .executableTarget(
            name: "vrc-test",
            dependencies: ["VRCTestSuite"],
            path: "Sources/vrc-test"
        ),
        // Headless control surface: seed, import, status, export, audit.
        .executableTarget(
            name: "vrc",
            dependencies: ["VRCCore"],
            path: "Sources/vrc"
        ),
        // The AWS handlers. Linux-only in practice, but builds on macOS so the
        // tests run here too.
        .target(
            name: "VRCLambda",
            dependencies: ["VRCCore"],
            path: "Sources/VRCLambda"
        ),
        // The five handlers, each a thin entry point over VRCLambda.
        .executableTarget(
            name: "vrc-lambda-fetch",
            dependencies: ["VRCCore", "VRCLambda"],
            path: "Sources/vrc-lambda-fetch"
        ),
        .executableTarget(
            name: "vrc-lambda-process",
            dependencies: ["VRCCore", "VRCLambda"],
            path: "Sources/vrc-lambda-process"
        ),
        .executableTarget(
            name: "vrc-lambda-publish",
            dependencies: ["VRCCore", "VRCLambda"],
            path: "Sources/vrc-lambda-publish"
        ),
        .executableTarget(
            name: "vrc-lambda-api",
            dependencies: ["VRCCore", "VRCLambda"],
            path: "Sources/vrc-lambda-api"
        ),
        .executableTarget(
            name: "vrc-lambda-sweeper",
            dependencies: ["VRCCore", "VRCLambda"],
            path: "Sources/vrc-lambda-sweeper"
        ),
        .executableTarget(name: "vrc-schema-dump", dependencies: ["VRCCore"], path: "Sources/vrc-schema-dump"),
        // Cross-platform parity harness. Builds on Linux as well as macOS,
        // which is the whole point: it proves the business rules agree.
        .executableTarget(
            name: "vrc-parity",
            dependencies: ["VRCCore"],
            path: "Sources/vrc-parity"
        ),
        // The SwiftUI application.
        .executableTarget(
            name: "VacationRentalCalendar",
            dependencies: ["VRCCore"],
            path: "Sources/VacationRentalCalendar"
        ),
    ]
)
