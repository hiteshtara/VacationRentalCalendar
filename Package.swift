// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VacationRentalCalendar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VacationRentalCalendar", targets: ["VacationRentalCalendar"]),
        .executable(name: "vrc-test", targets: ["vrc-test"]),
        .executable(name: "vrc", targets: ["vrc"]),
        .library(name: "VRCCore", targets: ["VRCCore"]),
    ],
    targets: [
        // Everything testable. No UI, no third-party dependencies.
        .target(
            name: "VRCCore",
            path: "Sources/VRCCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The canonical test suite. Plain Swift so it runs without Xcode.
        .target(
            name: "VRCTestSuite",
            dependencies: ["VRCCore"],
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
        // The SwiftUI application.
        .executableTarget(
            name: "VacationRentalCalendar",
            dependencies: ["VRCCore"],
            path: "Sources/VacationRentalCalendar"
        ),
    ]
)
