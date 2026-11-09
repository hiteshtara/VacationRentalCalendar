// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VacationRentalCalendar",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "VacationRentalCalendar", targets: ["VacationRentalCalendar"]),
        .executable(name: "vrc-test", targets: ["vrc-test"]),
        .executable(name: "vrc", targets: ["vrc"]),
        .library(name: "VRCCore", targets: ["VRCCore"]),
        .library(name: "VRCSync", targets: ["VRCSync"]),
        .library(name: "VRCUI", targets: ["VRCUI"]),
        // The iOS app's sources. Built by Xcode for iOS; on macOS the files
        // compile to nothing, so `swift build` stays green either way.
        .library(name: "VacationRentalCalendarIOS", targets: ["VacationRentalCalendarIOS"]),
    ],
    targets: [
        // Everything testable. No UI, no third-party dependencies.
        .target(
            name: "VRCCore",
            path: "Sources/VRCCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // SwiftUI pieces shared by the Mac and iPhone apps.
        .target(
            name: "VRCUI",
            dependencies: ["VRCCore"],
            path: "Sources/VRCUI"
        ),
        // CloudKit synchronisation. Cross-platform, and abstracted behind a
        // protocol so the merge rules are testable without touching iCloud.
        .target(
            name: "VRCSync",
            dependencies: ["VRCCore"],
            path: "Sources/VRCSync"
        ),
        .target(
            name: "VacationRentalCalendarIOS",
            dependencies: ["VRCCore", "VRCSync", "VRCUI"],
            path: "Sources/VacationRentalCalendarIOS"
        ),
        // The canonical test suite. Plain Swift so it runs without Xcode.
        .target(
            name: "VRCTestSuite",
            dependencies: ["VRCCore", "VRCSync"],
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
            dependencies: ["VRCCore", "VRCSync", "VRCUI"],
            path: "Sources/VacationRentalCalendar"
        ),
    ]
)
