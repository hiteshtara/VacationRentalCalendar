import Foundation

/// What a destination platform is actually able to do, as opposed to what one
/// might wish it did.
///
/// The short version for all three: they will **import** an iCal URL and
/// re-read it on their own schedule. None of them offers an individual host a
/// write API. So "block these nights on Vrbo" means "publish a feed Vrbo will
/// read", and nothing in this app can make that happen faster than Vrbo's own
/// polling interval.
public struct PlatformCapability: Sendable, Hashable {
    public var platform: RentalPlatform
    /// Exports its own calendar as iCal, for import here.
    public var providesCalendarExport: Bool
    /// Will import a third-party iCal URL — the only supported way to affect it.
    public var acceptsImportedCalendar: Bool
    /// Removing an event from the published feed eventually reopens the dates.
    public var supportsRemovingImportedBlocks: Bool
    /// A write API an individual host can use. False everywhere, for now.
    public var providesWriteAPI: Bool
    /// Any way to confirm the platform actually applied a change.
    public var providesVerificationSignal: Bool
    /// Typical gap between the platform re-reading an imported calendar.
    public var typicalRefreshInterval: TimeInterval
    /// Worst observed gap, used when telling the owner how long to expect.
    public var worstCaseRefreshInterval: TimeInterval

    public var latencyNote: String {
        let typical = Int(typicalRefreshInterval / 3_600)
        let worst = Int(worstCaseRefreshInterval / 3_600)
        return "\(platform.displayName) re-reads imported calendars roughly every "
            + "\(typical) hour\(typical == 1 ? "" : "s"), and has been seen to take up to "
            + "\(worst). Nothing here makes that faster."
    }

    public var verificationNote: String {
        providesVerificationSignal
            ? "\(platform.displayName) reports when it last imported a calendar."
            : "\(platform.displayName) gives no signal that it imported a feed, so a change can "
                + "only be confirmed by re-importing its own export and seeing the nights appear."
    }
}

/// One destination platform's behaviour.
///
/// Adapters describe and verify. They deliberately have **no method that
/// changes anything on a platform**, because no supported mechanism to do so
/// exists — and because an adapter with a `write` method is an adapter someone
/// will eventually call.
public protocol PlatformSyncAdapter: Sendable {
    var platform: RentalPlatform { get }
    var capability: PlatformCapability { get }

    /// Where the owner pastes the published feed URL, in that platform's words.
    var importInstructions: [String] { get }

    /// How a published change could be confirmed, given what the platform offers.
    func verificationStrategy() -> SyncVerificationStrategy

    /// Platform-specific wording checks applied to a generated entry before it
    /// is published, e.g. summaries a platform is known to mis-handle.
    func reviewGeneratedSummary(_ summary: String) -> String?
}

public extension PlatformSyncAdapter {
    func reviewGeneratedSummary(_ summary: String) -> String? { nil }
}

public enum PlatformAdapters {
    public static func adapter(for platform: RentalPlatform) -> PlatformSyncAdapter {
        switch platform {
        case .airbnb: return AirbnbAdapter()
        case .vrbo: return VrboAdapter()
        case .bookingCom: return BookingComAdapter()
        case .other: return GenericAdapter()
        }
    }

    public static var all: [PlatformSyncAdapter] {
        [AirbnbAdapter(), VrboAdapter(), BookingComAdapter()]
    }

    public static func capability(for platform: RentalPlatform) -> PlatformCapability {
        adapter(for: platform).capability
    }
}

/// Fallback for a platform this app knows nothing specific about.
public struct GenericAdapter: PlatformSyncAdapter {
    public init() {}
    public var platform: RentalPlatform { .other }
    public var capability: PlatformCapability {
        PlatformCapability(
            platform: .other,
            providesCalendarExport: true,
            acceptsImportedCalendar: false,
            supportsRemovingImportedBlocks: false,
            providesWriteAPI: false,
            providesVerificationSignal: false,
            typicalRefreshInterval: 6 * 3_600,
            worstCaseRefreshInterval: 24 * 3_600
        )
    }
    public var importInstructions: [String] {
        ["This app does not know how to publish a calendar to this platform."]
    }
    public func verificationStrategy() -> SyncVerificationStrategy { .unsupported }
}
