import Foundation

/// Airbnb.
///
/// Worth stating plainly, because it is the reason this project exists: Airbnb's
/// export gives a confirmed booking, a host's own block, and a block Airbnb
/// imposed after a host cancellation **identical wording and no description**.
/// This app therefore never treats an Airbnb block as information about
/// anything, and never sends another platform's blocks back to Airbnb without
/// the owner saying so.
public struct AirbnbAdapter: PlatformSyncAdapter {
    public init() {}

    public var platform: RentalPlatform { .airbnb }

    public var capability: PlatformCapability {
        PlatformCapability(
            platform: .airbnb,
            providesCalendarExport: true,
            acceptsImportedCalendar: true,
            supportsRemovingImportedBlocks: true,
            // No public availability write API for individual hosts. The
            // partner API is gated behind a commercial channel-manager
            // agreement.
            providesWriteAPI: false,
            providesVerificationSignal: false,
            typicalRefreshInterval: 3 * 3_600,
            worstCaseRefreshInterval: 12 * 3_600
        )
    }

    public var importInstructions: [String] {
        [
            "Open your Airbnb listing and go to Calendar.",
            "Choose Availability, then \"Connect to another website\".",
            "Choose \"Import calendar\" and paste the published feed URL.",
            "Give it a name you will recognise, such as \"Vacation Rental Calendar\".",
            "Airbnb re-reads it roughly every three hours.",
        ]
    }

    public func verificationStrategy() -> SyncVerificationStrategy {
        // The only evidence available is Airbnb's own export changing to show
        // the nights as unavailable.
        .reimportSourceFeed(
            expectedWithin: capability.worstCaseRefreshInterval,
            note: "Airbnb does not say when it last imported a calendar, so the only confirmation "
                + "is its own export showing those nights as unavailable on a later refresh."
        )
    }
}
