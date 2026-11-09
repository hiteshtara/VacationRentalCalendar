import Foundation

/// How current the published feed actually is, and what that means.
///
/// This type exists because of one uncomfortable fact: **a published feed
/// cannot update itself.** Regenerating it requires importing the source
/// calendars and uploading the result, and both need this Mac to be awake.
/// While the Mac is off, the hosted file keeps serving whatever was published
/// last — which is fine if nothing changed, and dangerous if a booking arrived.
///
/// The staleness is asymmetric. A feed missing a *block* is harmless: the dates
/// were already on sale. A feed missing a *reservation* is not: the destination
/// may accept a booking for a night that is already taken.
public struct PublicationFreshness: Sendable {
    public var destination: RentalPlatform
    /// Most recent successful import from any source calendar.
    public var lastImportAt: Date?
    /// Most recent feed actually served to the destination.
    public var lastPublishedAt: Date?
    /// How often the app is configured to import while running.
    public var importInterval: TimeInterval
    public var now: Date

    public init(
        destination: RentalPlatform,
        lastImportAt: Date?,
        lastPublishedAt: Date?,
        importInterval: TimeInterval = 3_600,
        now: Date = Date()
    ) {
        self.destination = destination
        self.lastImportAt = lastImportAt
        self.lastPublishedAt = lastPublishedAt
        self.importInterval = importInterval
        self.now = now
    }

    /// Nothing in this system is real time. Stated as a constant so no screen
    /// can drift into implying otherwise.
    public var isRealTime: Bool { false }

    public var importAge: TimeInterval? {
        lastImportAt.map { now.timeIntervalSince($0) }
    }

    public var publicationAge: TimeInterval? {
        lastPublishedAt.map { now.timeIntervalSince($0) }
    }

    /// True once the published feed is older than one import cycle plus the
    /// destination's own polling interval — the point past which a booking
    /// taken now would already be overdue at the destination.
    public var isStale: Bool {
        guard let age = publicationAge else { return lastPublishedAt == nil }
        return age > importInterval + destinationPollInterval
    }

    public var destinationPollInterval: TimeInterval {
        PlatformAdapters.capability(for: destination).typicalRefreshInterval
    }

    public var destinationWorstCasePoll: TimeInterval {
        PlatformAdapters.capability(for: destination).worstCaseRefreshInterval
    }

    /// The window during which a new reservation exists but the destination
    /// does not know about it — **assuming this Mac stays awake**.
    public var exposureWindowAwake: TimeInterval {
        importInterval + destinationWorstCasePoll
    }

    public func describeExposureAwake() -> String {
        let hours = Int((exposureWindowAwake / 3_600).rounded())
        return "With this Mac awake, a booking taken now could take up to about "
            + "\(hours) hours to appear on \(destination.displayName): up to "
            + "\(Int(importInterval / 3_600))h for this app to notice it, then up to "
            + "\(Int(destinationWorstCasePoll / 3_600))h for "
            + "\(destination.displayName) to re-read the feed."
    }

    /// The sentence the interface must never soften.
    public var offlineWarning: String {
        "While this Mac is asleep or shut down, nothing updates the published feed. "
            + "\(destination.displayName) keeps serving the last version it read. A booking "
            + "taken on another platform during that time will not reach "
            + "\(destination.displayName) until this Mac wakes, imports it and publishes again."
    }

    public var headline: String {
        guard let age = publicationAge else {
            return "Never published."
        }
        let hours = Int(age / 3_600)
        if isStale {
            return "Published feed is \(hours)h old — older than one refresh cycle. "
                + "Treat \(destination.displayName)'s availability as possibly behind."
        }
        return "Published feed is \(hours)h old."
    }
}

/// The claim this project refuses to make.
///
/// Kept as a constant, referenced by the interface and asserted by a test, so
/// that no future wording can quietly upgrade "delayed" into "real time".
public enum SynchronisationHonesty {
    public static let headline = "Delayed calendar synchronisation — not real-time channel management"

    public static let explanation = """
    This app reads your platform calendars and can publish a filtered feed for \
    another platform to read. Every step of that is on somebody's polling \
    schedule, and one step needs this Mac to be awake.

    A booking taken on Airbnb reaches Vrbo like this: Airbnb publishes it to its \
    export, this Mac imports it, this Mac republishes the filtered feed, and Vrbo \
    re-reads that feed. The two middle steps happen only while this Mac is \
    running. The last one happens on Vrbo's schedule, not ours.

    So there is always a window in which a night is booked on one platform and \
    still on sale on another. Nothing in this design removes that window; it \
    only makes it visible. Real-time protection needs a direct API integration, \
    which none of the three platforms offers to individual hosts.
    """

    /// Why this is not merely a limitation of this app.
    public static let comparison = """
    A paid channel manager that synchronises over iCal has the same window. The \
    difference is that it runs on a server that never sleeps, so its half of the \
    delay is bounded. This app's half is bounded by how often you leave your Mac on.
    """
}
