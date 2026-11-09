import Foundation

/// Vrbo (HomeAway).
///
/// Its export labels blocks only "Blocked", with no description, so an imported
/// Vrbo block is no more informative than an Airbnb one. It does import
/// third-party calendars, and documents a 30-minute refresh — observed delays
/// run considerably longer.
public struct VrboAdapter: PlatformSyncAdapter {
    public init() {}

    public var platform: RentalPlatform { .vrbo }

    public var capability: PlatformCapability {
        PlatformCapability(
            platform: .vrbo,
            providesCalendarExport: true,
            acceptsImportedCalendar: true,
            supportsRemovingImportedBlocks: true,
            providesWriteAPI: false,
            // Vrbo shows a "last imported" timestamp against each subscribed
            // calendar, but it is not machine-readable from here.
            providesVerificationSignal: false,
            typicalRefreshInterval: 2 * 3_600,
            worstCaseRefreshInterval: 12 * 3_600
        )
    }

    public var importInstructions: [String] {
        [
            "Open the Vrbo owner dashboard and go to Calendar.",
            "Choose Import/Export, then \"Import calendar\".",
            "Paste the published feed URL and give it a name.",
            "Vrbo documents a 30-minute refresh, but several hours is common.",
        ]
    }

    public func verificationStrategy() -> SyncVerificationStrategy {
        .reimportSourceFeed(
            expectedWithin: capability.worstCaseRefreshInterval,
            note: "Vrbo shows when it last imported a calendar in its own interface, but does not "
                + "expose that here, so confirmation comes from its export showing the nights "
                + "blocked."
        )
    }
}
