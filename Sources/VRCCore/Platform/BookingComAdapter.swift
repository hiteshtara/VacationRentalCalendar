import Foundation

/// Booking.com.
///
/// The awkward one. Its export labels **bookings and owner blocks identically**
/// as "CLOSED - Not available", so an imported Booking.com entry proves nothing
/// either way, and verification by re-import is correspondingly weak: seeing
/// nights closed there does not prove it was our feed that closed them.
public struct BookingComAdapter: PlatformSyncAdapter {
    public init() {}

    public var platform: RentalPlatform { .bookingCom }

    public var capability: PlatformCapability {
        PlatformCapability(
            platform: .bookingCom,
            providesCalendarExport: true,
            // Available for most property types, though not for every
            // contract — the owner must confirm it on their own account.
            acceptsImportedCalendar: true,
            supportsRemovingImportedBlocks: true,
            providesWriteAPI: false,
            providesVerificationSignal: false,
            typicalRefreshInterval: 2 * 3_600,
            worstCaseRefreshInterval: 12 * 3_600
        )
    }

    public var importInstructions: [String] {
        [
            "Open the Booking.com extranet and go to Rates & Availability.",
            "Choose \"Sync calendars\", then \"Import calendar\".",
            "Paste the published feed URL.",
            "Check your property type supports calendar import — not every contract does.",
            "Booking.com re-reads imported calendars roughly every two hours.",
        ]
    }

    public func verificationStrategy() -> SyncVerificationStrategy {
        .weakReimport(
            note: "Booking.com labels bookings and blocks identically in its export, so seeing "
                + "nights closed there does not prove our feed caused it. Treat confirmation "
                + "from Booking.com as suggestive rather than conclusive."
        )
    }

    public func reviewGeneratedSummary(_ summary: String) -> String? {
        summary.count > 60
            ? "Booking.com truncates long summaries; keep generated titles short."
            : nil
    }
}
