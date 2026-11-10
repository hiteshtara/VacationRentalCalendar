import Foundation

public struct ImportReport: Sendable {
    public var run: SyncRun
    public var warnings: [String]
    /// Keys whose classification the import left alone because the owner had
    /// already decided them.
    public var preservedDecisions: Int
    /// Decisions kept, but sent back for review because the event changed.
    public var reReviewed: Int
    public var productID: String

    public init(
        run: SyncRun,
        warnings: [String] = [],
        preservedDecisions: Int = 0,
        reReviewed: Int = 0,
        productID: String = ""
    ) {
        self.run = run
        self.warnings = warnings
        self.preservedDecisions = preservedDecisions
        self.reReviewed = reReviewed
        self.productID = productID
    }
}

/// Fetches a feed and reconciles it into the database.
///
/// Reconciliation is by stable key, which gives three properties the brief asks
/// for: re-importing an unchanged feed changes nothing, an edited event updates
/// its existing row, and an event that disappears is tombstoned rather than
/// deleted so the owner's decision about it survives.
public struct ImportService: Sendable {
    let events: EventRepository
    let classifications: ClassificationRepository
    let listings: ListingRepository
    let syncRuns: SyncRunRepository
    let fetcher: FeedFetching
    let classifier: BlockClassifier

    public init(
        events: EventRepository,
        classifications: ClassificationRepository,
        listings: ListingRepository,
        syncRuns: SyncRunRepository,
        fetcher: FeedFetching,
        classifier: BlockClassifier = BlockClassifier()
    ) {
        self.events = events
        self.classifications = classifications
        self.listings = listings
        self.syncRuns = syncRuns
        self.fetcher = fetcher
        self.classifier = classifier
    }

    @discardableResult
    public func importFeed(for listing: PlatformListing, now: Date = Date()) async -> ImportReport {
        guard let listingID = listing.id else {
            return ImportReport(run: SyncRun(
                listingID: 0, startedAt: now, finishedAt: now,
                outcome: .failure, errorMessage: "The listing has not been saved yet."
            ))
        }

        var run = SyncRun(listingID: listingID, startedAt: now)

        // A revoked credential is never retried. The platform has already
        // given its answer, and repeating the request only fills the history
        // with failures that look like trouble rather than a settled fact.
        guard listing.connectionState.shouldAttemptImport else {
            run.outcome = .disconnected
            run.finishedAt = Date()
            run.errorMessage = listing.connectionState.explanation
            try? syncRuns.record(run)
            try? listings.recordSync(
                listingID: listingID, at: now,
                summary: "Not imported — \(listing.connectionState.displayName.lowercased())"
            )
            return ImportReport(run: run)
        }

        // Resolved here, at the one moment it is needed, rather than on every
        // listing read. A Keychain prompt is tolerable when the owner just asked
        // for a refresh; it is not tolerable while drawing a calendar.
        var feedURL = ""
        var resolveError: String?
        // A TIMEOUT is not a broken credential. It says the Keychain was slow
        // at this moment and nothing at all about the stored value, so it must
        // stay retryable. Treating the two alike meant any busy machine could
        // permanently disconnect every calendar: on 2026-11-10 it silenced
        // three working feeds for an hour and a real Airbnb reservation went
        // unimported, while `vrc doctor` read all three credentials fine.
        var resolveTimedOut = false
        do {
            feedURL = try listings.resolveURL(for: listing)
        } catch let error as FeedCredentialError {
            if case .timedOut = error { resolveTimedOut = true }
            resolveError = error.errorDescription ?? "\(error)"
        } catch {
            resolveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        guard !feedURL.isEmpty else {
            run.finishedAt = Date()
            if let resolveError {
                // The read did not merely fail, it blocked — which means the
                // item's access list names an earlier build. Recorded so no
                // further attempt is made, because each one holds the keychain
                // for the rest of the process.
                run.outcome = resolveTimedOut ? .failure : .disconnected
                run.errorMessage = resolveError
                try? listings.setConnectionState(
                    listingID: listingID,
                    to: resolveTimedOut ? .failing : .credentialUnreadable,
                    detail: resolveError, actor: "import", at: now
                )
                try? listings.recordSync(
                    listingID: listingID, at: now,
                    summary: resolveTimedOut
                        ? "The Keychain did not answer in time — will try again"
                        : "Enter this listing's URL again — the saved one cannot be read"
                )
            } else {
                run.outcome = .skipped
                run.errorMessage = "No calendar URL configured."
                try? listings.recordSync(
                    listingID: listingID, at: now, summary: run.summaryLine
                )
            }
            try? syncRuns.record(run)
            return ImportReport(run: run)
        }

        let response: FeedResponse
        do {
            response = try await fetcher.fetch(urlString: feedURL)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            if let fetchError = error as? FeedFetchError,
               fetchError.indicatesRevokedCredential {
                // Settled, not transient. Stop retrying and say so plainly.
                var status: Int?
                if case .credentialRejected(let code, _) = fetchError { status = code }
                run.outcome = .disconnected
                run.finishedAt = Date()
                run.errorMessage = message
                try? syncRuns.record(run)
                try? listings.setConnectionState(
                    listingID: listingID, to: .revoked, detail: message,
                    httpStatus: status, actor: "import", at: now
                )
                try? listings.recordSync(
                    listingID: listingID, at: now,
                    summary: "Disconnected by the platform — a new export URL is needed"
                )
                return ImportReport(run: run)
            }

            run.outcome = .failure
            run.finishedAt = Date()
            run.errorMessage = message
            try? syncRuns.record(run)
            try? listings.setConnectionState(
                listingID: listingID, to: .failing, detail: message, actor: "import", at: now
            )
            try? listings.recordSync(listingID: listingID, at: now, summary: run.summaryLine)
            return ImportReport(run: run)
        }

        run.httpStatus = response.httpStatus

        let parsed: ICalParseResult
        do {
            parsed = try ICalParser.parse(response.text)
        } catch {
            run.outcome = .failure
            run.finishedAt = Date()
            run.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            try? syncRuns.record(run)
            try? listings.recordSync(listingID: listingID, at: now, summary: run.summaryLine)
            return ImportReport(run: run)
        }

        var report = ImportReport(run: run, warnings: parsed.warnings, productID: parsed.productID)
        var keysSeen: Set<String> = []

        for icalEvent in parsed.events {
            guard let checkIn = icalEvent.resolvedCheckIn,
                  let checkOut = icalEvent.resolvedCheckOut else { continue }

            let key = EventKey.make(
                listingID: listingID,
                uid: icalEvent.uid,
                recurrenceID: icalEvent.recurrenceID
            )
            // A feed repeating the same UID twice is one event, not two.
            if keysSeen.contains(key) { continue }
            keysSeen.insert(key)

            let feedStatus = FeedEventStatus.parse(icalEvent.status)
            let event = CalendarEvent(
                listingID: listingID,
                eventKey: key,
                uid: icalEvent.uid,
                recurrenceID: icalEvent.recurrenceID,
                platform: listing.platform,
                summary: icalEvent.summary,
                details: icalEvent.description,
                location: icalEvent.location,
                checkIn: checkIn,
                checkOut: checkOut,
                isAllDay: icalEvent.isAllDay,
                feedStatus: feedStatus,
                sequence: icalEvent.sequence,
                lastModified: icalEvent.lastModified ?? icalEvent.dtStamp,
                contentHash: icalEvent.contentHash(),
                firstSeenAt: now,
                lastSeenAt: now,
                // An event the feed itself marks cancelled is withdrawn, not a block.
                isTombstoned: feedStatus == .cancelled,
                hasUnsupportedRecurrence: icalEvent.hasRecurrenceRule
            )

            do {
                // Captured before the upsert so a material change can be seen.
                let previous = try events.find(eventKey: key)
                let result = try events.upsert(event, seenAt: now)
                switch result {
                case .inserted: report.run.eventsInserted += 1
                case .updated: report.run.eventsUpdated += 1
                case .unchanged: break
                }
                report.run.eventsSeen += 1

                // Classification. A decision the owner already made is never
                // recomputed — that is the guarantee behind "previously
                // reviewed classifications survive".
                let existing = try classifications.find(eventKey: key)
                if let existing, existing.isLocked {
                    report.preservedDecisions += 1

                    // R5: the decision stands, but if the platform changed the
                    // event materially it may no longer describe it, so it goes
                    // back to the queue rather than silently continuing to apply.
                    var kept = existing
                    if let previous, result == .updated {
                        let assessment = MaterialChange.assess(
                            previous: previous, updated: event, platform: listing.platform
                        )
                        if assessment.isMaterial, !existing.needsReview {
                            kept = MaterialChange.flagForReReview(
                                existing, assessment: assessment, at: now
                            )
                            try classifications.save(kept)
                            report.reReviewed += 1
                            report.warnings.append(
                                "\(listing.platform.displayName): "
                                    + "\(assessment.explanation) Sent back for review."
                            )
                        }
                    }
                    if kept.needsReview { report.run.eventsNeedingReview += 1 }
                } else {
                    let proposal = classifier.classify(
                        event: icalEvent,
                        platform: listing.platform,
                        nights: event.nights
                    )
                    let stored = try classifications.saveAutomaticIfNotDecided(
                        eventKey: key, proposal: proposal
                    )
                    if stored.needsReview { report.run.eventsNeedingReview += 1 }
                }
            } catch {
                report.warnings.append("Could not store an event: \(error)")
            }
        }

        // An empty calendar that parsed cleanly is NOT evidence that every
        // booking vanished. It is equally consistent with a truncated
        // response, a platform outage serving a stub, or a feed URL that now
        // points at an empty listing — and CLAUDE.md is explicit that a
        // failed, empty or truncated feed withdraws nothing.
        //
        // Getting this wrong is the dangerous direction for an IMPORT:
        // tombstoning a reservation makes those nights look free here, which
        // is how a double booking happens. Keeping a stale block only
        // withholds inventory, which is visible and recoverable.
        //
        // So a feed that yields zero events for a listing that currently has
        // some is refused, loudly, rather than believed.
        let previouslyActive = (try? events.activeCount(listingID: listingID)) ?? 0
        if keysSeen.isEmpty && previouslyActive > 0 {
            report.warnings.append(
                "The feed parsed but contained no events, while \(previouslyActive) "
                    + "are currently held. Nothing was withdrawn — an empty feed is not "
                    + "proof that bookings were cancelled. Check the listing on the platform."
            )
            report.run.eventsTombstoned = 0
        } else {
            do {
                report.run.eventsTombstoned = try events.tombstoneMissing(
                    listingID: listingID, keysStillPresent: keysSeen, at: now
                )
            } catch {
                report.warnings.append("Could not tombstone removed events: \(error)")
            }
        }

        report.run.outcome = .success
        report.run.finishedAt = Date()
        try? listings.setConnectionState(
            listingID: listingID, to: .connected, detail: "", actor: "import", at: now
        )
        if let recorded = try? syncRuns.record(report.run) { report.run = recorded }
        try? listings.recordSync(
            listingID: listingID, at: now, summary: report.run.summaryLine
        )
        return report
    }

    /// Imports every listing that has a URL. Returns one report per listing.
    public func importAll(
        listings listingsToImport: [PlatformListing],
        autoRefreshOnly: Bool = false,
        now: Date = Date()
    ) async -> [ImportReport] {
        var reports: [ImportReport] = []
        for listing in listingsToImport {
            if autoRefreshOnly && !listing.autoRefreshEnabled { continue }
            // Revoked feeds are skipped even on an explicit refresh-all, so a
            // dead connection cannot flood the history with failures.
            if !listing.connectionState.shouldAttemptImport, listing.hasURL == false,
               listing.connectionState == .notConfigured { continue }
            reports.append(await importFeed(for: listing, now: now))
        }
        return reports
    }
}
