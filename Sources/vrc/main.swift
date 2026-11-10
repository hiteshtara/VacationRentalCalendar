import Foundation
import VRCCore

// Headless control surface for the same core the SwiftUI app uses. Useful for
// verifying an import without opening the window, and for scripting.

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"
let flags = Set(arguments.dropFirst().filter { $0.hasPrefix("--") })

func value(for flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func bail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func makeStore() -> RentalStore {
    do {
        if flags.contains("--memory") { return try RentalStore.makeInMemory() }
        return try RentalStore.makeDefault()
    } catch {
        bail("could not open the database: \(error)")
    }
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

// MARK: - Commands

func runHelp() {
    print("""
    vrc — Vacation Rental Calendar, headless

    USAGE
      vrc seed                     Insert the configured properties and listings
      vrc set-url --listing <id>   Store a feed URL (read from stdin, never argv)
                                   --stdin for authorized migration (no prompt)
      vrc status                   Show properties, listings, events, review queue
      vrc import [--listing <id>]  Fetch feeds read-only and reconcile
      vrc review                   List everything awaiting your decision
      vrc classify --key <k> --kind <kind> [--approve]
                                   Record a manual decision
      vrc conflicts                Show overlapping ranges
      vrc export --property <id> [--to airbnb|vrbo|booking_com] [--write <path>]
                                   Build a filtered feed and show what was excluded
      vrc feed --property <id> --to <platform> [--raw]
                                   Show the feed a destination would receive
      vrc availability             List availability decisions and audit history
      vrc preview --property <id> --from YYYY-MM-DD --to YYYY-MM-DD
                  --actions vrbo=block,airbnb=block,booking_com=block
                                   Dry run an availability plan; writes nothing
      vrc draft --property <id> --platform <p> --action block
                --ranges YYYY-MM-DD:YYYY-MM-DD[,...] [--reason "..."]
                                   Record DRAFT decisions only; never advances
      vrc approve --decision <id>[,<id>…]
                                   Draft -> validated -> awaiting -> approved
      vrc rehearse --property <id> [--to vrbo]
                                   Run the publication pipeline in a sandbox
      vrc connection [--listing <id>] [--state <state>] [--detail "..."]
                                   Show or change a feed's connection state
      vrc cloud [status|check]     Show or test the AWS staging connection
      vrc cloud set-endpoint <url> [--region us-east-1]
      vrc cloud set-credentials    Store an AWS access key (read without echo)
      vrc keychain                 Report which stored items this build can read
      vrc doctor                   Check the database, Keychain and outbound gate

    KINDS
      \(BlockKind.allCases.map(\.rawValue).joined(separator: ", "))

    GLOBAL FLAGS
      --memory                     Throwaway in-memory database

    Feed URLs live in the macOS Keychain. There is no plaintext fallback.

    Database: \(AppPaths.databaseURL.path)
    """)
}

/// Reads a feed URL from stdin so the secret never appears in a command line,
/// a shell history or a process list.
/// Replaces a listing's calendar feed URL.
///
/// The URL is read with echo suppressed and is **verified before it is
/// stored**: a credential that is saved and only then discovered to be broken
/// leaves the app in the state this command exists to repair. So the order is
/// paste, fetch, parse, show what was found, confirm, and only then save.
///
/// Nothing prints the URL. Not on success, not on failure, not truncated.
func runSetURL() async {
    let store = makeStore()
    let dryRun = flags.contains("--dry-run")
    // Non-interactive mode, for Scripts/migrate-cloud-credential.sh only. The
    // terminal requirement below exists to stop a URL being echoed as it is
    // typed; a pipe echoes nothing, so the protection is not weakened. Every
    // other check — https, fetch, parse — still applies, and the URL is still
    // never in argv.
    let fromStdin = flags.contains("--stdin")

    guard let listingID = value(for: "--listing").flatMap(Int64.init) else {
        bail("--listing <id> is required (see `vrc status`)")
    }
    guard let listing = try? store.listings.find(id: listingID), listing.id != nil else {
        bail("no listing with id \(listingID)")
    }

    print("Replacing the calendar feed URL for \(listing.label)")
    print("")
    print("  Where to find it:")
    switch listing.platform {
    case .airbnb:
        print("    Airbnb → Calendar → Availability → Connect to another website")
        print("            → Export calendar")
    case .vrbo:
        print("    Vrbo → Calendar → Import/Export → Export calendar")
    case .bookingCom:
        // The control is "Skip to export", not "Skip this step". The older
        // label is still repeated by third-party guides, and looking for it
        // is why this step appears impossible: the import form seems to
        // demand another calendar's URL with no way past it.
        print("    Booking.com → Rates & Availability → Sync calendars")
        print("            → Add calendar connection, or \"Complete setup\" on a")
        print("              connection already showing \"Activating\"")
        print("            → in the import form, click \"Skip to export\"")
        print("            → copy the export link, then \"Done\"")
        print("      The connection should then read \"Export only\".")
    case .other:
        print("    Use the platform's calendar export (not import) URL.")
    }
    print("")
    print("  Your typing will not be shown. The URL is never printed, never")
    print("  written to the database, and never stored in this project.")
    if !SecureInput.standardInputIsTerminal && !fromStdin {
        print("")
        print("  NOTE: standard input is not a terminal, so echo cannot be")
        print("        suppressed. Saving is refused in this mode — run this")
        print("        command directly in Terminal.")
    }
    print("")

    let pastedOrNil = fromStdin
        ? readLine(strippingNewline: true)
        : SecureInput.readLine(prompt: "  Paste the iCal export URL, then press Return: ")
    guard let pasted = pastedOrNil else {
        bail("no URL supplied")
    }
    let url = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !url.isEmpty else { bail("no URL supplied") }

    let lowered = url.lowercased()
    let allowFile = flags.contains("--allow-file")
    guard lowered.hasPrefix("https://") || lowered.hasPrefix("webcal://")
            || (allowFile && lowered.hasPrefix("file://")) else {
        bail("the URL must use https (or webcal) — a plain http feed would leak "
            + "your calendar token to anyone on the network")
    }

    print("  Received: \(SecureInput.redact(url))")
    print("")
    print("── Verifying before saving")

    let fetcher = URLSessionFeedFetcher(allowFileURLs: flags.contains("--allow-file"))
    let parsed: ICalParseResult
    do {
        let response = try await fetcher.fetch(urlString: url)
        let status = response.httpStatus.map(String.init) ?? "(no status)"
        print("   HTTP \(status)")
        parsed = try ICalParser.parse(response.text)
        print("   parsed \(parsed.events.count) event(s), producer "
            + (parsed.productID.isEmpty ? "(unstated)" : parsed.productID))
        for warning in parsed.warnings.prefix(3) { print("   note: \(warning)") }
    } catch {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        print("   FAILED: \(detail)")
        print("")
        bail("not saved — the URL was not stored, and your existing entry is untouched")
    }

    if dryRun {
        print("")
        print("   --dry-run: verified but NOT saved. Nothing was written.")
        return
    }

    guard SecureInput.standardInputIsTerminal || fromStdin else {
        bail("refusing to save a credential read without echo suppression — "
            + "run this in Terminal")
    }

    if !fromStdin {
        print("")
        FileHandle.standardError.write(Data("  Save this URL to the Keychain? [y/N] ".utf8))
        let answer = (readLine(strippingNewline: true) ?? "").lowercased()
        guard answer.hasPrefix("y") else {
            print("  Not saved. Your existing entry is untouched.")
            return
        }
    }

    var updated = listing
    updated.icalURL = url
    updated.urlStorage = .keychain
    if updated.credentialRef.isEmpty {
        updated.credentialRef = ListingRepository.credentialReference(
            platform: listing.platform, listingLabel: listing.label,
            propertyID: listing.propertyID
        )
    }
    let previousRef = listing.credentialRef

    // After a rebuild the existing entry's access list names binaries that no
    // longer exist, so a re-home must create a new entry rather than update in
    // place. The old entry is left untouched.
    let rehome = flags.contains("--rehome")
    do {
        try store.listings.update(updated, rehomeCredential: rehome)
        let saved = try store.listings.find(id: listingID)
        print("")
        print("  Stored in \(store.credentials.storageDescription).")
        if let saved, saved.credentialRef != previousRef {
            print("  New Keychain reference: \(saved.credentialRef)")
            print("  The previous entry (\(previousRef)) was left in place and not deleted.")
        } else {
            print("  Keychain reference: \(previousRef)")
        }
        print("  The URL is not written to the database or to any file in the project.")

        // Clear the unreadable state only after a verified, saved credential.
        if listing.connectionState == .credentialUnreadable {
            try store.listings.setConnectionState(
                listingID: listingID, to: .connected,
                detail: "URL re-entered and verified", actor: "owner", at: Date()
            )
            print("  Connection state: credential_unreadable → connected")
        }
    } catch {
        bail("could not store the URL: \(error)")
    }
}

func runSeed() {
    let store = makeStore()
    do {
        let created = try SeedData.apply(to: store)
        if created.isEmpty {
            print("Nothing to do — the configured properties already exist.")
        } else {
            print("Created:")
            for line in created { print("  \(line)") }
        }
    } catch {
        bail("seeding failed: \(error)")
    }
}

func runStatus() {
    let store = makeStore()
    do {
        let properties = try store.properties.all()
        let listings = try store.listings.all()
        let classified = try store.classifiedEvents()
        let review = try store.needsReview()
        let conflicts = try store.conflicts()

        print("Schema version: \(try Migrator.currentVersion(store.database)) "
            + "of \(Migrator.latestVersion)")
        // The CLI only ever runs against the local SQLite file; the cloud
        // store is reached by the Lambdas, not from here.
        print("Database:       \((store.database as? Database)?.path ?? "(not a local file)")")
        print("Feed URLs:      \(store.credentials.storageDescription)")
        print("Outbound sync:  \(OutboundSyncGate.isEnabled ? "ENABLED" : "disabled (hard-coded)")")
        print("")

        for property in properties {
            guard let propertyID = property.id else { continue }
            print("\(property.name)  —  \(property.address)")
            for listing in listings where listing.propertyID == propertyID {
                let events = try store.events.countForListing(listing.id ?? 0)
                let urlState = store.listings.hasCredential(for: listing)
                    ? "URL in Keychain" : "no URL"
                print("  \(pad(listing.platform.displayName, 12)) "
                    + "\(pad(urlState, 18)) "
                    + "\(events) events  "
                    + "\(listing.lastSyncSummary.isEmpty ? "never synced" : listing.lastSyncSummary)")
            }
        }

        print("")
        print("Events:        \(classified.count) active")
        var byKind: [BlockKind: Int] = [:]
        for item in classified { byKind[item.classification.kind, default: 0] += 1 }
        for kind in BlockKind.allCases where (byKind[kind] ?? 0) > 0 {
            let nights = classified
                .filter { $0.classification.kind == kind }
                .reduce(0) { $0 + $1.event.nights }
            print("  \(pad(kind.displayName, 24)) \(byKind[kind] ?? 0) events, \(nights) nights")
        }
        print("Needs review:  \(review.count)")
        print("Double bookings: \(conflicts.filter { $0.severity == .doubleBooking }.count)")
        print("Other overlaps:  \(conflicts.filter { $0.severity == .overlappingBlocks }.count)")
    } catch {
        bail("status failed: \(error)")
    }
}

func runImport() async {
    let store = makeStore()
    do {
        var listings = try store.listings.all()
        if let wanted = value(for: "--listing").flatMap(Int64.init) {
            listings = listings.filter { $0.id == wanted }
        }
        guard !listings.isEmpty else { bail("no listings configured — run `vrc seed` first") }

        let service = store.makeImportService(
            fetcher: URLSessionFeedFetcher(allowFileURLs: flags.contains("--allow-file"))
        )

        for listing in listings {
            print("── \(listing.label)")
            let report = await service.importFeed(for: listing)
            print("   outcome:   \(report.run.outcome.rawValue)"
                + (report.run.httpStatus.map { " (HTTP \($0))" } ?? ""))
            if let error = report.run.errorMessage { print("   error:     \(error)") }
            if !report.productID.isEmpty { print("   producer:  \(report.productID)") }
            print("   in feed:   \(report.run.eventsSeen)")
            print("   new:       \(report.run.eventsInserted)")
            print("   changed:   \(report.run.eventsUpdated)")
            print("   removed:   \(report.run.eventsTombstoned)")
            print("   to review: \(report.run.eventsNeedingReview)")
            if report.preservedDecisions > 0 {
                print("   your prior decisions kept: \(report.preservedDecisions)")
            }
            for warning in report.warnings.prefix(5) { print("   note:      \(warning)") }
        }
    } catch {
        bail("import failed: \(error)")
    }
}

func runReview() {
    let store = makeStore()
    do {
        let review = try store.needsReview()
        guard !review.isEmpty else { print("Nothing is waiting for review."); return }
        print("\(review.count) item(s) awaiting your decision:\n")
        for item in review {
            print("\(item.event.platform.displayName) · \(item.propertyName)")
            print("  \(DayMath.mediumString(item.event.checkIn)) → "
                + "\(DayMath.mediumString(item.event.checkOut))  (\(item.event.nights) nights)")
            print("  feed says:  \"\(item.event.summary)\"")
            print("  app thinks: \(item.classification.kind.displayName) "
                + "(\(item.classification.confidence.displayName) confidence)")
            print("  why:        \(item.classification.rationale)")
            print("  key:        \(item.event.eventKey)")
            print("")
        }
    } catch {
        bail("review failed: \(error)")
    }
}

func runClassify() {
    let store = makeStore()
    guard let key = value(for: "--key") else { bail("--key is required") }
    guard let kindRaw = value(for: "--kind"), let kind = BlockKind(rawValue: kindRaw) else {
        bail("--kind must be one of: \(BlockKind.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    do {
        try store.classifyManually(
            eventKey: key,
            kind: kind,
            note: value(for: "--note") ?? "",
            approveForExport: flags.contains("--approve") ? true : nil
        )
        print("Recorded: \(kind.displayName)"
            + (flags.contains("--approve") ? ", approved for export" : ""))
        if !kind.describesGenuineUnavailability {
            print("These dates will never be exported, which keeps them sellable elsewhere.")
        }
    } catch {
        bail("classify failed: \(error)")
    }
}

func runConflicts() {
    let store = makeStore()
    do {
        let conflicts = try store.conflicts()
        guard !conflicts.isEmpty else { print("No overlapping ranges found."); return }
        for conflict in conflicts {
            let marker = conflict.severity.isUrgent ? "!! " : "   "
            print("\(marker)\(conflict.severity.displayName) · \(conflict.propertyName)")
            print("   \(conflict.dateRangeDescription)  (\(conflict.overlapNights) nights)")
            print("   A: \(conflict.sideA.platform.displayName) \"\(conflict.sideA.summary)\" "
                + "\(DayMath.mediumString(conflict.sideA.checkIn))→"
                + "\(DayMath.mediumString(conflict.sideA.checkOut))")
            print("   B: \(conflict.sideB.platform.displayName) \"\(conflict.sideB.summary)\" "
                + "\(DayMath.mediumString(conflict.sideB.checkIn))→"
                + "\(DayMath.mediumString(conflict.sideB.checkOut))")
            print("")
        }
    } catch {
        bail("conflict check failed: \(error)")
    }
}

func runExport() {
    let store = makeStore()
    guard let propertyID = value(for: "--property").flatMap(Int64.init) else {
        bail("--property <id> is required")
    }
    let destination = value(for: "--to").flatMap { RentalPlatform(rawValue: $0) }
    do {
        let plan = try store.exportPlan(propertyID: propertyID, destination: destination)
        print(store.exporter.auditText(for: plan))
        if let path = value(for: "--write") {
            let url = URL(fileURLWithPath: path)
            try store.exporter.write(plan: plan, to: url)
            print("\nWrote \(plan.included.count) event(s) to \(url.path)")
        }
    } catch {
        bail("export failed: \(error)")
    }
}

/// Shows the feed a destination would receive, entry by entry, with reasons.
func runFeed() {
    let store = makeStore()
    guard let propertyID = value(for: "--property").flatMap(Int64.init) else {
        bail("--property <id> is required")
    }
    guard let raw = value(for: "--to"), let destination = RentalPlatform(rawValue: raw) else {
        bail("--to must be one of: airbnb, vrbo, booking_com")
    }
    do {
        let feed = try store.outbound.generateFeed(propertyID: propertyID, destination: destination)
        print(CalendarFeedGenerator().auditText(feed))

        if flags.contains("--if-approved") {
            // Hypothetical only: shows what the feed WOULD contain if every
            // pending decision were approved. Nothing is saved or sent.
            let hypothetical = try store.availability.forProperty(propertyID).map {
                decision -> AvailabilityDecision in
                var copy = decision
                if copy.status.isPending { copy.status = .approved; copy.approvedAt = Date() }
                return copy
            }
            let projected = CalendarFeedGenerator().generate(
                destination: destination, propertyID: propertyID,
                propertyName: try store.properties.find(id: propertyID)?.name ?? "",
                sourceEvents: try store.classifiedEvents(), decisions: hypothetical
            )
            print("")
            print("=== IF APPROVED (hypothetical — nothing saved or sent) ===")
            print(CalendarFeedGenerator().auditText(projected))
            print("")
            print("--- the .ics that would be served ---")
            print(CalendarFeedGenerator().makeICS(projected))
        }
        print("")
        print("Outbound publishing: \(OutboundSyncGate.isEnabled ? "ENABLED" : "disabled (hard-coded)")")
        if flags.contains("--raw") {
            print("")
            print(CalendarFeedGenerator().makeICS(feed))
        }
    } catch {
        bail("feed generation failed: \(error)")
    }
}

func runAvailability() {
    let store = makeStore()
    do {
        let decisions = try store.availability.all()
        if decisions.isEmpty {
            print("No availability decisions recorded.")
        } else {
            for decision in decisions {
                print("[\(decision.id ?? 0)] \(decision.summaryLine)")
                print("     status: \(decision.status.rawValue) — \(decision.status.explanation)")
                if let reason = decision.failureReason { print("     refused: \(reason)") }
            }
        }
        print("")
        let audit = try store.auditLog.recent(limit: 20)
        if !audit.isEmpty {
            print("Recent audit entries:")
            for entry in audit.reversed() { print("  \(entry.line)") }
        }
    } catch {
        bail("availability listing failed: \(error)")
    }
}

/// Shows or changes a feed's connection state, with history.
func runConnection() {
    let store = makeStore()
    guard let listingID = value(for: "--listing").flatMap(Int64.init) else {
        // No listing given: summarise them all.
        do {
            for listing in try store.listings.all() {
                print("[\(listing.id ?? 0)] \(pad(listing.platform.displayName, 12)) "
                    + "\(pad(listing.connectionState.displayName, 28)) \(listing.label)")
                if !listing.connectionDetail.isEmpty {
                    print("      \(listing.connectionDetail)")
                }
                if let next = listing.connectionState.nextStep {
                    print("      next: \(next)")
                }
            }
        } catch {
            bail("could not list connections: \(error)")
        }
        return
    }

    do {
        guard let listing = try store.listings.find(id: listingID) else {
            bail("no listing with id \(listingID)")
        }
        if let raw = value(for: "--state") {
            guard let state = FeedConnectionState(rawValue: raw) else {
                bail("--state must be one of: "
                    + FeedConnectionState.allCases.map(\.rawValue).joined(separator: ", "))
            }
            try store.listings.setConnectionState(
                listingID: listingID, to: state,
                detail: value(for: "--detail") ?? "",
                httpStatus: value(for: "--http").flatMap(Int.init),
                actor: value(for: "--actor") ?? "owner"
            )
            print("\(listing.label) → \(state.displayName)")
            if !state.shouldAttemptImport {
                print("This feed will no longer be fetched.")
            }
        }

        let updated = try store.listings.find(id: listingID)!
        print("")
        print("State:  \(updated.connectionState.displayName)")
        print("        \(updated.connectionState.explanation)")
        if let next = updated.connectionState.nextStep { print("Next:   \(next)") }
        print("")
        print("History:")
        for entry in try store.listings.connectionHistory(listingID: listingID) {
            print("  \(entry.line)")
        }
    } catch {
        bail("connection command failed: \(error)")
    }
}

/// Dry run of an availability plan. Writes nothing and contacts nobody.
func runPreview() {
    let store = makeStore()
    guard let propertyID = value(for: "--property").flatMap(Int64.init) else {
        bail("--property <id> is required")
    }
    func parseDay(_ flag: String) -> Date? {
        guard let raw = value(for: flag) else { return nil }
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return DayMath.day(parts[0], parts[1], parts[2])
    }
    guard let start = parseDay("--from"), let end = parseDay("--to") else {
        bail("--from and --to are required as YYYY-MM-DD (check-out exclusive)")
    }

    var actions: [RentalPlatform: AvailabilityAction] = [:]
    for pair in (value(for: "--actions") ?? "").split(separator: ",") {
        let bits = pair.split(separator: "=")
        guard bits.count == 2,
              let platform = RentalPlatform(rawValue: String(bits[0])),
              let action = AvailabilityAction(rawValue: String(bits[1])) else {
            bail("--actions must look like vrbo=block,airbnb=block,booking_com=block")
        }
        actions[platform] = action
    }
    guard !actions.isEmpty else { bail("--actions is required") }

    do {
        let plan = AvailabilityPlan(
            propertyID: propertyID, startDay: start, endDay: end,
            reason: value(for: "--reason") ?? "", actions: actions
        )
        let preview = try store.availabilityManager.preview(plan)

        print("PREVIEW — nothing is saved, nothing is sent")
        print("Property: \(preview.propertyName)")
        print(preview.nightsDescription)
        print("")

        // What already occupies these nights, per the brief's pre-checks.
        let overlapping = try store.classifiedEvents().filter {
            $0.propertyID == propertyID && $0.event.isActive
                && $0.event.checkIn < plan.endDay && plan.startDay < $0.event.checkOut
        }
        print("EXISTING EVENTS OVERLAPPING THIS RANGE (\(overlapping.count))")
        if overlapping.isEmpty { print("  none") }
        for item in overlapping {
            print("  \(item.event.platform.shortTag)  "
                + "\(DayMath.icalDateString(item.event.checkIn))–"
                + "\(DayMath.icalDateString(item.event.checkOut))  "
                + "\(item.classification.kind.displayName)"
                + (item.classification.needsReview ? "  [needs review]" : ""))
        }
        let confirmed = overlapping.filter {
            $0.classification.kind == .confirmedReservation && !$0.classification.needsReview
        }
        let unknown = overlapping.filter {
            $0.classification.needsReview || $0.classification.kind == .unknownUnavailable
        }
        let restrictions = overlapping.filter {
            $0.classification.kind == .platformRestriction
        }
        print("")
        print("  confirmed reservations: \(confirmed.count)")
        print("  unknown / unreviewed:   \(unknown.count)")
        print("  platform restrictions:  \(restrictions.count)")
        print("")

        for line in preview.lines {
            print("── \(line.destination.displayName): \(line.action.displayName)")
            print("   verdict: \(line.canProceed ? "may proceed" : "REFUSED")"
                + (line.validation.needsReview ? " (check first)" : ""))
            for violation in line.validation.violations {
                print("   [\(violation.severity.rawValue)] \(violation.rule.rawValue) "
                    + "\(violation.message)")
            }
            for note in line.validation.notes { print("   note: \(note)") }
        }
        print("")
        print("Outbound publishing: \(OutboundSyncGate.isEnabled ? "ENABLED" : "disabled (hard-coded)")")
    } catch {
        bail("preview failed: \(error)")
    }
}

/// Records DRAFT availability decisions. Validates and reports, but never
/// advances past draft, and never contacts anything.
func runDraft() {
    let store = makeStore()
    guard let propertyID = value(for: "--property").flatMap(Int64.init) else {
        bail("--property <id> is required")
    }
    func parseDay(_ raw: Substring) -> Date? {
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return DayMath.day(parts[0], parts[1], parts[2])
    }
    guard let raw = value(for: "--platform"),
          let destination = RentalPlatform(rawValue: raw) else {
        bail("--platform must be airbnb, vrbo or booking_com")
    }
    guard let actionRaw = value(for: "--action"),
          let action = AvailabilityAction(rawValue: actionRaw) else {
        bail("--action must be block, unblock or leaveUnchanged")
    }
    // One or more ranges: --ranges 2026-12-10:2026-12-17,2026-12-19:2026-12-20
    guard let rangesRaw = value(for: "--ranges") else {
        bail("--ranges is required, e.g. 2026-12-10:2026-12-17,2026-12-19:2026-12-20")
    }
    var ranges: [(Date, Date)] = []
    for piece in rangesRaw.split(separator: ",") {
        let bits = piece.split(separator: ":")
        guard bits.count == 2, let from = parseDay(bits[0]), let to = parseDay(bits[1]),
              to > from else {
            bail("bad range \"\(piece)\" — use YYYY-MM-DD:YYYY-MM-DD, check-out exclusive")
        }
        ranges.append((from, to))
    }

    do {
        let reason = value(for: "--reason") ?? ""
        var created: [AvailabilityDecision] = []

        for (from, to) in ranges {
            let candidate = AvailabilityDecision(
                propertyID: propertyID, destination: destination, action: action,
                startDay: from, endDay: to, status: .draft, reason: reason,
                createdBy: "owner"
            )
            // Validate for reporting only; the status stays draft.
            let validation = store.availabilityManager.detector.validate(
                candidate,
                in: try store.availabilityManager.context(
                    propertyID: propertyID, destination: destination
                )
            )
            let stored = try store.availability.insert(candidate)
            try store.auditLog.record(AuditEntry(
                decisionID: stored.id, actor: "owner", toStatus: .draft,
                event: "created-draft",
                detail: stored.summaryLine
                    + (validation.isRefused ? " — REFUSED: \(validation.headline)" : "")
            ))
            created.append(stored)

            print("DRAFT #\(stored.id ?? 0)  \(destination.displayName)  \(action.displayName)")
            print("  \(stored.nightsDescription)")
            print("  status: draft — not validated, not approved, not published")
            print("  checks: \(validation.isRefused ? "REFUSED" : (validation.needsReview ? "review first" : "no conflicts"))")
            for violation in validation.violations {
                print("    [\(violation.severity.rawValue)] \(violation.rule.rawValue) \(violation.message)")
            }
            print("")
        }

        let nights = created.reduce(0) { $0 + $1.nights }
        print("Created \(created.count) draft decision(s), \(nights) nights total.")
        print("Nothing is validated, approved, published or sent. Outbound publishing: "
            + "\(OutboundSyncGate.isEnabled ? "ENABLED" : "disabled (hard-coded)")")
    } catch {
        bail("draft failed: \(error)")
    }
}

/// Walks a decision from draft to approved, re-validating on the way.
/// Approval is not publication: see OutboundSyncGate.
func runApprove() {
    let store = makeStore()
    guard let raw = value(for: "--decision") else {
        bail("--decision <id>[,<id>…] is required")
    }
    let ids = raw.split(separator: ",").compactMap { Int64($0) }
    guard !ids.isEmpty else { bail("no usable decision ids in \"\(raw)\"") }
    let actor = value(for: "--actor") ?? "owner"

    for id in ids {
        do {
            let (afterValidation, validation) =
                try store.availabilityManager.validateDraft(decisionID: id, actor: actor)
            print("DECISION #\(id)  \(afterValidation.summaryLine)")
            print("  checks: \(validation.isRefused ? "REFUSED" : (validation.needsReview ? "review advised" : "no conflicts"))")
            for violation in validation.violations {
                print("    [\(violation.severity.rawValue)] \(violation.rule.rawValue) \(violation.message)")
            }
            guard !validation.isRefused else {
                print("  not approved — \(afterValidation.status.displayName)")
                print("")
                continue
            }

            let approved = try store.availabilityManager.approve(decisionID: id, actor: actor)
            let stamp = approved.approvedAt.map {
                ISO8601DateFormatter().string(from: $0)
            } ?? "—"
            print("  status:      \(approved.status.rawValue)")
            print("  approved at: \(stamp)")
            print("  approved by: \(approved.approvedBy ?? "—")")
            print("  published:   \(approved.publishedAt == nil ? "no — publication is a separate act" : "yes")")
            print("")
        } catch {
            print("DECISION #\(id): \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            print("")
        }
    }
    print("Outbound publishing: \(OutboundSyncGate.isEnabled ? "ENABLED" : "disabled (hard-coded)")")
}

/// Rehearses the whole publication pipeline against an isolated directory.
///
/// Uses the real decisions and the real feed generator, but a local hosting
/// client — so nothing reaches the internet, no platform is contacted, and the
/// outbound gate is untouched. Deliberate failures are injected so the
/// recovery path is exercised rather than assumed.
func runRehearsal() async {
    let store = makeStore()
    guard let propertyID = value(for: "--property").flatMap(Int64.init) else {
        bail("--property <id> is required")
    }
    let destination = value(for: "--to").flatMap { RentalPlatform(rawValue: $0) } ?? .vrbo

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vrc-rehearsal-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    // The rehearsal runs against a throwaway copy of the database.
    //
    // It writes publication rows and a last-known-good snapshot, and those
    // describe publications that never happened. Left in the real database
    // they would corrupt the next genuine publish: the safety diff compares
    // against the last known good feed, and a rehearsal snapshot is not one.
    let sandboxDatabasePath = root.appendingPathComponent("rehearsal.sqlite").path
    let rehearsalStore: RentalStore
    do {
        // Structural guard, not a convention: refuses outright if the path is
        // the production database or anywhere near it.
        try RehearsalIsolation.assertIsolated(databasePath: sandboxDatabasePath)
        try store.database.run("VACUUM INTO ?;", [.text(sandboxDatabasePath)])
        rehearsalStore = try RentalStore(
            database: try Database(path: sandboxDatabasePath),
            credentials: InMemoryFeedCredentialStore()
        )
    } catch {
        try? FileManager.default.removeItem(at: root)
        bail("could not create the rehearsal sandbox: \(error)")
    }
    let token = FeedTokenRepository.generateKey()
    let configuration = R2HostingConfiguration(
        accountID: "<account>", bucket: "vrc-feeds",
        customDomain: "feeds.example.invalid", zoneID: "<zone>"
    )
    let slug = "39-g-street"
    let key = configuration.key(propertySlug: slug, destination: destination, token: token)

    do {
        let hosting = try LocalDirectoryHostingClient(root: root)
        print("REHEARSAL — isolated, nothing leaves this Mac")
        print("  sandbox: \(root.path)")
        print("  key:     \(key.replacingOccurrences(of: token, with: "<token>"))")
        print("  url:     \(configuration.redactedURL(propertySlug: slug, destination: destination))")
        print("")

        // 1. Without approval of the change, nothing may be served.
        let held = try await rehearsalStore.outbound.runPipeline(
            propertyID: propertyID, destination: destination,
            hosting: hosting, key: key, changeApproved: false
        )
        print("1. publish without approving the change")
        print("   stage: \(held.stage.rawValue) — \(held.stage.displayName)")
        print("   served to a platform now: \(await hosting.servedBody(key: key) == nil ? "nothing" : "SOMETHING")")
        print("")

        // 2. Approved: the full path.
        let ok = try await rehearsalStore.outbound.runPipeline(
            propertyID: propertyID, destination: destination,
            hosting: hosting, key: key, changeApproved: true
        )
        let served = await hosting.servedBody(key: key) ?? ""
        let parsed = try? ICalParser.parse(served)
        print("2. publish with the change approved")
        print("   stage:   \(ok.stage.rawValue) — \(ok.stage.displayName)")
        print("   verdict: \(ok.safety.verdict.rawValue)")
        print("   diff:    \(ok.safety.diff.summary)")
        print("   served:  \(parsed?.events.count ?? 0) events, "
            + "\(parsed?.events.reduce(0) { $0 + max(1, DayMath.daysBetween($1.resolvedCheckIn ?? Date(), $1.resolvedCheckOut ?? Date())) } ?? 0) nights")
        print("   remote synchronised? \(ok.isRemoteSynchronised) "
            + "(only VERIFIED ever means yes)")
        print("")

        // 3. A failed upload must leave the previous feed serving.
        await hosting.setFailUpload("simulated network failure")
        let uploadFailed = try await rehearsalStore.outbound.runPipeline(
            propertyID: propertyID, destination: destination,
            hosting: hosting, key: key, changeApproved: true
        )
        let afterUploadFailure = await hosting.servedBody(key: key) ?? ""
        print("3. upload fails")
        print("   stage: \(uploadFailed.stage.rawValue)")
        print("   detail: \(uploadFailed.detail)")
        print("   still served: \((try? ICalParser.parse(afterUploadFailure))?.events.count ?? 0) events "
            + "(the previous feed is intact)")
        await hosting.setFailUpload(nil)
        print("")

        // 4. A failed cache purge must not be reported as success.
        await hosting.setFailInvalidation("simulated purge API 500")
        let purgeFailed = try await rehearsalStore.outbound.runPipeline(
            propertyID: propertyID, destination: destination,
            hosting: hosting, key: key, changeApproved: true
        )
        print("4. cache purge fails")
        print("   stage: \(purgeFailed.stage.rawValue) — \(purgeFailed.stage.displayName)")
        print("   counts as published? \(purgeFailed.succeeded)")
        print("   \(purgeFailed.detail)")
        await hosting.setFailInvalidation(nil)
        print("")

        // 5. Recovery to the last feed known good.
        let restored = try await rehearsalStore.outbound.rollback(
            propertyID: propertyID, destination: destination, hosting: hosting, key: key
        )
        let afterRollback = await hosting.servedBody(key: key) ?? ""
        print("5. roll back to the last known good feed")
        print("   restored revision: \(restored?.revision ?? -1)")
        print("   entries restored:  \(restored?.entryCount ?? -1)")
        print("   now served:        \((try? ICalParser.parse(afterRollback))?.events.count ?? 0) events")
        print("")

        print("publication history")
        for row in try rehearsalStore.outbound.publicationHistory(
            propertyID: propertyID, destination: destination, limit: 8
        ) {
            print("   rev \(row.revision)  \(pad(row.stage, 26)) \(pad(row.verdict, 26)) \(row.detail)")
        }
        print("")
        // What still stands between this and a live feed.
        let unmet = try store.outbound.unmetPreconditions(
            propertyID: propertyID, destination: destination
        )
        print("preconditions still unmet for live publication (\(unmet.count))")
        for item in unmet { print("   \(item.rawValue): \(item.requirement)") }
        print("")
        let freshness = try store.outbound.freshness(
            propertyID: propertyID, destination: destination
        )
        print("delivery expectations")
        print("   \(SynchronisationHonesty.headline)")
        print("   \(freshness.describeExposureAwake())")
        print("   \(freshness.offlineWarning)")
        print("")
        print("Outbound gate: \(OutboundSyncGate.isEnabled ? "ENABLED" : "disabled (hard-coded)")")
        print("Nothing was uploaded to the internet and no platform was contacted.")
        print("The real database was copied, not used: publication rows and snapshots")
        print("stayed in the sandbox and are discarded with it.")

        try? FileManager.default.removeItem(at: root)
    } catch {
        try? FileManager.default.removeItem(at: root)
        bail("rehearsal failed: \(error)")
    }
}

func runDoctor() {
    let store = makeStore()
    var problems = 0
    func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        if !ok { problems += 1 }
    }
    do {
        let version = try Migrator.currentVersion(store.database)
        check("schema at latest version", version == Migrator.latestVersion,
              "at \(version), latest \(Migrator.latestVersion)")
        check("outbound sync disabled", !OutboundSyncGate.isEnabled)
        check("no feed URL stored in the database",
              !(try store.listings.databaseLeaksAnyKeychainURL()))

        // Reported per listing, with "never set up" kept apart from "broken".
        // Test Cottage's three empty listings are expected, not failures.
        let credentialHealth = (try? store.credentialHealth()) ?? []
        for report in credentialHealth {
            switch report.status {
            case .notConfigured:
                print("  --   \(report.listing.label) — not configured (no calendar URL yet)")
            case .readable:
                check("feed URL readable for \(report.listing.label)", true,
                      "Keychain: \(report.listing.credentialRef)")
            case .unreadable:
                check("feed URL readable for \(report.listing.label)", false,
                      "stored under \(report.listing.credentialRef) but this build cannot read it")
            }
        }
        print("")
        let signature = CodeSignatureInfo.current()
        check("code identity is stable across rebuilds", signature.kind.identityIsStable,
              signature.kind.rawValue
                  + (signature.authority.map { " — \($0)" } ?? ""))
        if !signature.kind.identityIsStable {
            print("     Run ./Scripts/fix-signing.sh once for a stable identity.")
        }
        // Readability is a separate question from identity, and the only one
        // that matters operationally. `vrc doctor` previously reported the
        // presence of a Keychain REFERENCE as though it were access.
        // Via the store, which flattens the double optional this used to get
        // wrong: a reference pointing at nothing came back `.some(nil)` and
        // was counted as readable.
        // Three outcomes, not two. A listing that was never set up is not a
        // broken credential, and reporting it as one made this gate
        // permanently red — which is exactly how a real failure stops being
        // noticed.
        let health = credentialHealth
        let unreadable = health.filter { $0.status == .unreadable }
        check("this build can actually READ its stored credentials", unreadable.isEmpty,
              unreadable.isEmpty
                  ? "\(health.filter { $0.status == .readable }.count) readable, "
                      + "\(health.filter { $0.status == .notConfigured }.count) not configured"
                  : "\(unreadable.count) unreadable — run ./Scripts/migrate-cloud-credential.sh")
        print("")
        print("Credential store: \(store.credentials.storageDescription)")
        print("Code signature:   \(signature.kind.rawValue)"
            + (signature.authority.map { " — \($0)" } ?? ""))
        print(signature.explanation)
    } catch {
        bail("doctor failed: \(error)")
    }
    exit(problems == 0 ? 0 : 1)
}


// MARK: - feed-diff

/// Fetches each authorised feed twice and compares the semantic hash, to settle
/// whether change detection can work against the real platforms.
///
/// Deliberately prints nothing that identifies a guest, a reservation, or a
/// credential: source name, HTTP status, byte count, event count, a truncated
/// hash, and — when a difference is found — the NAMES of the fields that moved.
/// Never a URL, a token, a UID, a summary or a date.
func runFeedDiff() async {
    let store = makeStore()
    let gap = Double(value(for: "--gap") ?? "") ?? 300
    let fetcher = URLSessionFeedFetcher()

    do {
        let listings = try store.listings.all().filter { $0.connectionState.shouldAttemptImport }
        guard !listings.isEmpty else { bail("no connected listings to test") }

        print("Feed-diff experiment")
        print("  Fetches each connected feed twice, \(Int(gap))s apart, and compares the")
        print("  semantic hash. Excluded from the hash: \(SemanticFeedHash.excludedProperties.joined(separator: ", ")).")
        print("  No URL, token, UID, summary or date is printed.\n")

        var firstPass: [Int64: (hash: String, events: [ICalEvent], bytes: Int, status: Int?)] = [:]

        for pass in 1...2 {
            if pass == 2 {
                print("  waiting \(Int(gap))s before the second fetch…\n")
                try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
            }
            print("── pass \(pass)")
            for listing in listings {
                guard let id = listing.id else { continue }
                let name = listing.platform.displayName
                do {
                    let resolved = try store.listings.resolveURL(for: listing)
                    let response = try await fetcher.fetch(urlString: resolved)
                    let parsed = try ICalParser.parse(response.text)
                    let digest = SemanticFeedHash.hash(parsed.events)
                    let label: String = name.padding(toLength: 12, withPad: " ", startingAt: 0)
                    let status: String = response.httpStatus.map(String.init) ?? "?"
                    let bytes: Int = response.text.utf8.count
                    let count: Int = parsed.events.count
                    let short: String = String(digest.prefix(16))
                    print("   \(label) HTTP \(status)  \(bytes) bytes  \(count) events  hash \(short)")
                    if pass == 1 {
                        firstPass[id] = (digest, parsed.events, response.text.utf8.count,
                                         response.httpStatus)
                    } else if let before = firstPass[id] {
                        if before.hash == digest {
                            print("     → IDENTICAL hash. Change detection works for this source.")
                            let nowBytes: Int = response.text.utf8.count
                            if before.bytes != nowBytes {
                                let was: Int = before.bytes
                                print("     → note: raw byte count changed (\(was) → \(nowBytes)),")
                                print("       so a raw-bytes checksum WOULD have reported a false change.")
                            }
                        } else {
                            let names = SemanticFeedHash.changedFieldNames(
                                from: before.events, to: parsed.events)
                            print("     → HASH DIFFERS between two fetches.")
                            print("     → fields that moved: "
                                + (names.isEmpty ? "(none in common events — the UID set changed)"
                                                 : names.joined(separator: ", ")))
                        }
                    }
                } catch {
                    let detail = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    print("   \(name): could not fetch — \(detail)")
                }
            }
            print("")
        }

        print("── synthetic control (offline, proves the hash is not simply constant)")
        let base = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\n"
            + "DTSTAMP:20261108T090000Z\r\nUID:control@test\r\n"
            + "DTSTART;VALUE=DATE:20261210\r\nDTEND;VALUE=DATE:20261217\r\n"
            + "SUMMARY:Reserved\r\nEND:VEVENT\r\nEND:VCALENDAR"
        let restamped = base.replacingOccurrences(
            of: "DTSTAMP:20261108T090000Z", with: "DTSTAMP:20261108T094500Z")
        let moved = base.replacingOccurrences(
            of: "DTEND;VALUE=DATE:20261217", with: "DTEND;VALUE=DATE:20261218")
        let h0 = SemanticFeedHash.hash(try ICalParser.parse(base).events)
        let h1 = SemanticFeedHash.hash(try ICalParser.parse(restamped).events)
        let h2 = SemanticFeedHash.hash(try ICalParser.parse(moved).events)
        print("   DTSTAMP changed only       → \(h0 == h1 ? "same hash (correct)" : "DIFFERENT (wrong)")")
        print("   check-out date changed     → \(h0 != h2 ? "different hash (correct)" : "SAME (wrong)")")
    } catch {
        bail("feed-diff failed: \(error)")
    }
}

// MARK: - Cloud

/// Configures and inspects the AWS staging service.
///
/// The access key and secret are read with echo suppressed, stored in the
/// Keychain, and never printed, logged or written to the database -- the same
/// treatment feed URLs get.
func runCloud() async {
    let store = makeStore()
    let connection = CloudConnection(settings: store.settings, credentials: store.credentials)
    let subcommand = arguments.count > 1 ? arguments[1] : "status"

    switch subcommand {
    case "status":
        print("AWS staging configuration")
        print("")
        switch connection.availability() {
        case .configured(let endpoint, let region):
            print("  endpoint    \(endpoint.absoluteString)")
            print("  region      \(region)")
            print("  credentials present in the Keychain and readable")
        case .notConfigured(let missing):
            print("  not configured — missing \(missing.joined(separator: ", "))")
            print("")
            print("  vrc cloud set-endpoint https://<id>.execute-api.<region>.amazonaws.com")
            print("  vrc cloud set-credentials")
        case .insecureEndpoint(let text):
            print("  stored endpoint is not https and will not be used: \(text)")
        case .credentialUnreadable(let detail):
            print("  credentials are stored but could not be read: \(detail)")
        }

    case "set-endpoint":
        guard arguments.count > 2 else {
            bail("usage: vrc cloud set-endpoint <https url> [--region us-east-1]")
        }
        let region = value(for: "--region") ?? "us-east-1"
        do {
            try connection.setEndpoint(arguments[2], region: region)
            print("Stored. endpoint \(arguments[2]) · region \(region)")
        } catch {
            bail("\(error)")
        }

    case "set-credentials":
        // Non-interactive path for piping straight from `aws iam
        // create-access-key`, so the secret never reaches a terminal, a shell
        // history or a log. Two lines: key id, then secret.
        if flags.contains("--stdin") {
            guard let keyID = Swift.readLine(strippingNewline: true),
                  let secret = Swift.readLine(strippingNewline: true),
                  !keyID.isEmpty, !secret.isEmpty else {
                bail("--stdin expects two lines: access key id, then secret")
            }
            do {
                try connection.setCredentials(accessKeyID: keyID, secretAccessKey: secret)
                print("Stored in the Keychain (\(keyID.count)-character key id).")
            } catch {
                bail("\(error)")
            }
            return
        }

        print("Storing an AWS access key for the staging API.")
        print("")
        print("  Your typing will not be shown. Neither value is printed, written")
        print("  to the database, or stored in this project.")
        if !SecureInput.standardInputIsTerminal {
            print("")
            print("  NOTE: standard input is not a terminal, so echo cannot be")
            print("        suppressed. Saving is refused — run this in Terminal.")
            exit(1)
        }
        print("")
        guard let keyID = SecureInput.readLine(prompt: "  Access key ID: "),
              !keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            bail("no access key ID supplied")
        }
        guard let secret = SecureInput.readLine(prompt: "  Secret access key: "),
              !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            bail("no secret access key supplied")
        }
        do {
            try connection.setCredentials(
                accessKeyID: keyID.trimmingCharacters(in: .whitespacesAndNewlines),
                secretAccessKey: secret.trimmingCharacters(in: .whitespacesAndNewlines))
            // Only the identifier's length is reported. Printing any part of
            // either value would defeat reading them without echo.
            print("")
            print("Stored in the Keychain (\(keyID.count)-character key id).")
        } catch {
            bail("\(error)")
        }

    case "check":
        // --json is the GUI's entry point. It prints exactly one line of
        // sanitized JSON to stdout and nothing else there; every human message
        // and every error goes to stderr. The GUI reads stdout only, so a
        // stray diagnostic can never be parsed as status, and a secret can
        // never reach stdout because only CloudStatusPayload is written there.
        let asJSON = flags.contains("--json")

        func emit(_ payload: CloudStatusPayload) -> Never {
            if asJSON {
                print(payload.encoded())
                exit(payload.ok ? 0 : 0)   // JSON mode: the payload carries ok
            }
            exit(payload.ok ? 0 : 1)
        }

        guard let client = connection.makeClient() else {
            switch connection.availability() {
            case .insecureEndpoint(let text):
                if asJSON { emit(.failure(.insecureEndpoint,
                    "The stored endpoint is not https.")) }
                bail("stored endpoint is not https: \(text)")
            case .credentialUnreadable(let detail):
                if asJSON { emit(.failure(.notConfigured,
                    "The helper cannot read its AWS credential. Re-run vrc cloud set-credentials.")) }
                bail(detail)
            default:
                if asJSON { emit(.failure(.notConfigured,
                    "No AWS endpoint or credentials stored.")) }
                bail("not configured — run `vrc cloud status`")
            }
        }
        if asJSON {
            do {
                let status = try client.status()
                let intervals = (try? client.availability()) ?? []
                emit(.reached(status, intervals: intervals))
            } catch {
                // The error text from CloudSyncClient is secret-free by design
                // (status codes and service messages, never the credential),
                // but the GUI is given a fixed sentence regardless.
                FileHandle.standardError.write(Data("could not reach the service: \(error)\n".utf8))
                emit(.failure(.unreachable, "Could not reach the AWS service."))
            }
        }
        do {
            let status = try client.status()
            print("Reached the service.")
            print("")
            print("  live source events     \(status.liveSourceEvents)")
            print("  approved decisions     \(status.approvedDecisions)")
            print("  published decisions    \(status.publishedDecisions)")
            print("  open conflicts         \(status.openConflicts)")
            print("  last successful import \(status.lastSuccessfulImport)")
            print("  outbound enabled       \(status.outboundEnabled)")
            print("  platforms confirmed    \(status.remoteSynchronised)")
            for (source, reason) in status.failingSources.sorted(by: { $0.key < $1.key }) {
                print("  FAILING \(source): \(reason)")
            }
            for (source, reason) in status.staleSources.sorted(by: { $0.key < $1.key }) {
                print("  STALE   \(source): \(reason)")
            }
            let intervals = (try? client.availability()) ?? []
            print("")
            print("  \(intervals.count) blocking interval(s)")
            for interval in intervals {
                print("    \(interval.from) → \(interval.to)  "
                      + "\(interval.source) · \(interval.basis)")
            }
        } catch {
            bail("could not reach the service: \(error)")
        }

    default:
        bail("unknown: vrc cloud \(subcommand) — try status, set-endpoint, set-credentials, check")
    }
}

// MARK: - Keychain

/// Reports, per stored item, whether this executable can read it — and when it
/// cannot, the actual reason.
///
/// Values are never printed. The point is the status, because "refused" and
/// "wants to ask" need opposite fixes and a timeout cannot tell them apart.
func runKeychain() {
    let store = makeStore()
    var references: [(String, String)] = []
    for listing in (try? store.listings.all()) ?? [] where !listing.credentialRef.isEmpty {
        references.append((listing.label, listing.credentialRef))
    }
    references.append(("AWS access key id", CloudConnection.accessKeyReference))
    references.append(("AWS secret access key", CloudConnection.secretKeyReference))

    print("Keychain readability for this executable")
    print("  \(Bundle.main.executablePath ?? CommandLine.arguments[0])")
    print("")
    var unreadable = 0
    for (label, reference) in references {
        let probe = KeychainDiagnostics.probe(reference: reference)
        let mark = probe.isReadable ? "ok  " : "FAIL"
        print("  \(mark) \(label) [\(reference)] — \(probe.detail)")
        if !probe.isReadable, probe.outcome != .absent { unreadable += 1 }
    }
    print("")
    if unreadable == 0 {
        print("Every stored item is readable by this executable.")
    } else {
        print("\(unreadable) item(s) unreadable. The access list names code by its")
        print("designated requirement; an item created by a differently signed")
        print("build is not covered by it.")
        exit(1)
    }
}

// MARK: - Dispatch

switch command {
case "seed": runSeed()
case "set-url": await runSetURL()
case "status": runStatus()
case "import": await runImport()
case "review": runReview()
case "classify": runClassify()
case "conflicts": runConflicts()
case "feed": runFeed()
case "availability": runAvailability()
case "connection": runConnection()
case "preview": runPreview()
case "draft": runDraft()
case "approve": runApprove()
case "rehearse": await runRehearsal()
case "export": runExport()
case "doctor": runDoctor()
case "feed-diff": await runFeedDiff()
case "cloud": await runCloud()
case "keychain": runKeychain()
case "help", "--help", "-h": runHelp()
default:
    runHelp()
    exit(1)
}
