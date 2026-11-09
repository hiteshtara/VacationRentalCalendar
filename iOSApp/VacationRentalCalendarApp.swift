import SwiftUI
import VacationRentalCalendarIOS

// The iPhone app's entry point.
//
// Everything of substance lives in the VacationRentalCalendarIOS library, which
// is shared with the Mac build and is type-checked by `swift build` on macOS.
// This file exists only because an Xcode app target needs to own its own @main.

@main
struct VacationRentalCalendarApp: App {
    var body: some Scene {
        WindowGroup {
            PhoneRootView()
        }
    }
}
