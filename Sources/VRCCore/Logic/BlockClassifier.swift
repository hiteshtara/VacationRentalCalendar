import Foundation

/// Decides what an imported unavailable date range probably is.
///
/// Two principles govern everything here, and both come from looking at what
/// the real feeds actually contain:
///
/// 1. **Only positive evidence of a booking raises confidence.** The absence of
///    a marker never means "safe". Airbnb's own export for this owner's listing
///    is four events that all read `SUMMARY:Airbnb (Not available)` with no
///    `DESCRIPTION` at all — a confirmed booking, an owner block and a
///    host-cancellation penalty block are byte-for-byte identical in it.
///
/// 2. **When in doubt, review.** Anything short of high confidence is routed to
///    the owner rather than acted on.
public struct BlockClassifier: Sendable {

    /// A block this long is almost never a real hold — it is the edge of the
    /// listing's booking window, which platforms export as "unavailable".
    public static let longHorizonNights = 90

    public init() {}

    // MARK: - Evidence

    /// Positive, specific signs that a real guest is attached to these dates.
    public struct Evidence: Sendable {
        public var reservationURL = false
        public var confirmationCode = false
        public var guestContact = false
        public var reservedSummary = false
        public var notes: [String] = []

        public var hasStrongReservationEvidence: Bool {
            reservationURL || confirmationCode || guestContact
        }
        public var hasAnyReservationEvidence: Bool {
            hasStrongReservationEvidence || reservedSummary
        }
    }

    public func evidence(for event: ICalEvent, platform: RentalPlatform) -> Evidence {
        var evidence = Evidence()
        let summary = event.summary.lowercased()
        let details = event.description.lowercased()
        let haystack = summary + "\n" + details

        if details.contains("reservation url")
            || details.contains("/reservations/details")
            || details.contains("airbnb.com/hosting/reservations")
            || details.contains("/hosting/reservations") {
            evidence.reservationURL = true
            evidence.notes.append("The description contains a reservation link.")
        }
        if haystack.range(of: #"confirmation code[: ]"#, options: .regularExpression) != nil
            || haystack.range(of: #"\bHM[A-Z0-9]{6,}\b"#, options: [.regularExpression]) != nil {
            evidence.confirmationCode = true
            evidence.notes.append("A booking confirmation code is present.")
        }
        if details.contains("phone number")
            || details.contains("last 4 digits")
            || details.contains("guest name")
            || details.range(of: #"[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}"#,
                             options: .regularExpression) != nil {
            evidence.guestContact = true
            evidence.notes.append("Guest contact details are present.")
        }
        if summary.range(of: #"^\s*reserved\b"#, options: .regularExpression) != nil {
            evidence.reservedSummary = true
            evidence.notes.append(
                "\(platform.displayName) labels this \"Reserved\", which it uses only for bookings."
            )
        }
        // Booking.com's standard export labels bookings and blocks identically,
        // so a "CLOSED" summary is not evidence of either.
        if platform == .bookingCom, summary.contains("closed") {
            evidence.notes.append(
                "Booking.com exports \"CLOSED – Not available\" for bookings and for owner "
                    + "blocks alike, so this label proves nothing either way."
            )
        }
        return evidence
    }

    // MARK: - Classification

    public func classify(
        event: ICalEvent,
        platform: RentalPlatform,
        nights: Int
    ) -> ClassificationProposal {
        let summary = event.summary.lowercased()
        let details = event.description.lowercased()
        let haystack = summary + "\n" + details
        let evidence = evidence(for: event, platform: platform)

        var proposal = baseProposal(
            event: event,
            platform: platform,
            summary: summary,
            haystack: haystack,
            details: details,
            evidence: evidence
        )

        // A very long range is suspect whatever it is called. It caps confidence
        // and is always called out, because propagating one of these destroys
        // months of sellable inventory in a single sync.
        if nights >= Self.longHorizonNights, !evidence.hasStrongReservationEvidence {
            if proposal.confidence > .medium { proposal.confidence = .medium }
            proposal.rationale += " This range covers \(nights) nights, which is long enough to "
                + "be the edge of your booking window rather than a real hold — platforms export "
                + "the dates past the end of your window as unavailable."
            // Now has a name of its own rather than being lumped in with
            // genuinely unexplained blocks. Still reviewed, still never
            // exported — but the owner is told what it probably is.
            if proposal.kind != .confirmedReservation {
                proposal.kind = .platformRestriction
            }
        }

        if !evidence.notes.isEmpty {
            proposal.rationale += " Evidence: " + evidence.notes.joined(separator: " ")
        }

        // The single rule that cannot be bypassed: anything short of high
        // confidence, and anything the app could not positively identify, goes
        // to the owner.
        proposal.needsReview = proposal.confidence < .high
            || !proposal.kind.describesGenuineUnavailability
        if event.hasRecurrenceRule { proposal.needsReview = true }

        return proposal
    }

    private func baseProposal(
        event: ICalEvent,
        platform: RentalPlatform,
        summary: String,
        haystack: String,
        details: String,
        evidence: Evidence
    ) -> ClassificationProposal {

        // 1. A repeating rule is not expanded, so the dates cannot be trusted.
        if event.hasRecurrenceRule {
            return ClassificationProposal(
                kind: .unknownUnavailable,
                confidence: .low,
                rationale: "This event repeats using a rule this app does not expand, so its real "
                    + "dates are unknown.",
                needsReview: true
            )
        }

        // 2. Positive evidence of a guest. The only route to automatic export.
        if evidence.hasStrongReservationEvidence {
            return ClassificationProposal(
                kind: .confirmedReservation,
                confidence: .high,
                rationale: "\(platform.displayName) supplied booking-specific data for these "
                    + "dates, so a guest is genuinely staying.",
                needsReview: false
            )
        }

        // 3. The platform explicitly says "Reserved". Airbnb and Vrbo both use
        //    that word only for real bookings; their blocks say otherwise.
        if evidence.reservedSummary, platform == .airbnb || platform == .vrbo {
            return ClassificationProposal(
                kind: .confirmedReservation,
                confidence: .high,
                rationale: "\(platform.displayName) labels these dates \"Reserved\", a label it "
                    + "applies to bookings and never to blocked dates.",
                needsReview: false
            )
        }
        if evidence.reservedSummary {
            return ClassificationProposal(
                kind: .confirmedReservation,
                confidence: .medium,
                rationale: "The summary says \"Reserved\", but \(platform.displayName) is not "
                    + "consistent about that wording, so confirm it yourself.",
                needsReview: true
            )
        }

        // 4. Wording the owner may have typed on the platform. Never trusted
        //    enough to export on its own, but it points the review in the right
        //    direction.
        if haystack.range(of: #"cancel|penalt|host cancel|cancelled by host"#,
                          options: .regularExpression) != nil {
            return ClassificationProposal(
                kind: .cancellationBlock,
                confidence: .medium,
                rationale: "The wording mentions a cancellation. Dates blocked after a host "
                    + "cancellation are not booked and stay sellable on your other platforms, so "
                    + "this is never exported.",
                needsReview: true
            )
        }
        if haystack.range(of: #"mainten|repair|renovat|remodel|contractor|plumb|paint|deep clean|turnover|cleaning"#,
                          options: .regularExpression) != nil {
            return ClassificationProposal(
                kind: .maintenanceBlock,
                confidence: .medium,
                rationale: "The wording describes work on the unit.",
                needsReview: true
            )
        }
        if haystack.range(of: #"owner|personal|family|friend|my stay|do not rent|private|hold"#,
                          options: .regularExpression) != nil {
            return ClassificationProposal(
                kind: .ownerBlock,
                confidence: .medium,
                rationale: "The wording suggests you are holding these dates yourself.",
                needsReview: true
            )
        }

        // 5. The common case, and the dangerous one: a generic block.
        let genericBlock = haystack.range(
            of: #"not available|unavailable|blocked|busy|closed|reserved by owner"#,
            options: .regularExpression
        ) != nil

        if genericBlock || summary.isEmpty {
            var rationale = "\(platform.displayName) reports these dates as unavailable without "
                + "saying why."
            if platform == .airbnb {
                rationale += " Airbnb's export gives a confirmed booking, a block you made, and a "
                    + "block Airbnb imposed after a host cancellation exactly the same wording, so "
                    + "there is no way to tell them apart from the feed. Until you say which it is, "
                    + "these dates stay sellable on Vrbo and Booking.com."
            } else {
                rationale += " It cannot be told apart from a booking or from a block you made, so "
                    + "it is not exported until you decide."
            }
            return ClassificationProposal(
                kind: .unknownUnavailable,
                confidence: .low,
                rationale: rationale,
                needsReview: true
            )
        }

        // 6. Something unrecognised. Same treatment.
        return ClassificationProposal(
            kind: .unknownUnavailable,
            confidence: .low,
            rationale: "This app did not recognise \"\(event.summary)\" as either a booking or a "
                + "block, so it needs your decision before it can affect any other platform.",
            needsReview: true
        )
    }
}
