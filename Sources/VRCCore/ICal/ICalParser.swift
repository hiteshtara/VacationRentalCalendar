import Foundation

public struct ICalParseResult: Sendable {
    public var productID: String
    public var events: [ICalEvent]
    /// Problems worth telling the owner about without failing the whole import.
    public var warnings: [String]

    public init(productID: String = "", events: [ICalEvent] = [], warnings: [String] = []) {
        self.productID = productID
        self.events = events
        self.warnings = warnings
    }
}

public enum ICalParseError: Error, LocalizedError {
    case notACalendar
    case empty

    public var errorDescription: String? {
        switch self {
        case .notACalendar:
            return "That response is not an iCalendar feed. Check the URL — platforms sometimes return an HTML error page with a 200 status."
        case .empty:
            return "The feed was empty."
        }
    }
}

public enum ICalParser {
    /// Parses a complete .ics document.
    ///
    /// Lenient about the things real feeds get wrong (bare LF line endings,
    /// missing DTEND, unknown properties) and strict about the one thing that
    /// matters: an event with no usable date range is reported, never guessed at.
    public static func parse(_ text: String) throws -> ICalParseResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ICalParseError.empty }
        guard trimmed.uppercased().contains("BEGIN:VCALENDAR") else {
            throw ICalParseError.notACalendar
        }

        var result = ICalParseResult()
        var current: ICalEvent?
        var inEvent = false
        var nestedDepth = 0

        for rawLine in ICalLexer.unfold(text) {
            guard let line = ICalLexer.parse(line: rawLine) else { continue }

            switch line.name {
            case "BEGIN":
                let component = line.rawValue.uppercased()
                if component == "VEVENT" {
                    inEvent = true
                    current = ICalEvent()
                } else if inEvent {
                    // VALARM and friends inside a VEVENT: skip their properties.
                    nestedDepth += 1
                }
                continue

            case "END":
                let component = line.rawValue.uppercased()
                if component == "VEVENT" {
                    if var event = current {
                        if event.uid.isEmpty {
                            // A feed without UIDs cannot be deduplicated on identity,
                            // so synthesise a stable one from the content.
                            event.uid = "synthetic-" + event.contentHash()
                            result.warnings.append(
                                "An event had no UID; a content-derived identifier was used, "
                                    + "so editing it on the platform will look like a new event."
                            )
                        }
                        if event.resolvedCheckIn == nil {
                            result.warnings.append(
                                "Skipped an event with no readable start date (UID \(event.uid))."
                            )
                        } else {
                            result.events.append(event)
                        }
                    }
                    inEvent = false
                    current = nil
                } else if inEvent, nestedDepth > 0 {
                    nestedDepth -= 1
                }
                continue

            case "PRODID" where !inEvent:
                result.productID = line.textValue
                continue

            default:
                break
            }

            guard inEvent, nestedDepth == 0, current != nil else { continue }

            current!.allLines.append(line)

            switch line.name {
            case "UID":
                current!.uid = line.rawValue.trimmingCharacters(in: .whitespaces)
            case "RECURRENCE-ID":
                current!.recurrenceID = line.rawValue.trimmingCharacters(in: .whitespaces)
            case "SUMMARY":
                current!.summary = line.textValue
            case "DESCRIPTION":
                current!.description = line.textValue
            case "LOCATION":
                current!.location = line.textValue
            case "STATUS":
                current!.status = line.rawValue.trimmingCharacters(in: .whitespaces)
            case "SEQUENCE":
                current!.sequence = Int(line.rawValue.trimmingCharacters(in: .whitespaces)) ?? 0
            case "DTSTART":
                current!.dtStart = ICalDateParser.parse(line)
            case "DTEND":
                current!.dtEnd = ICalDateParser.parse(line)
            case "DURATION":
                current!.duration = ICalDateParser.parseDuration(line.rawValue)
            case "DTSTAMP":
                current!.dtStamp = ICalDateParser.parse(line)?.date
            case "LAST-MODIFIED":
                current!.lastModified = ICalDateParser.parse(line)?.date
            case "RRULE", "RDATE":
                // Not expanded. Flagged so the event is reviewed rather than
                // silently treated as a single occurrence.
                current!.hasRecurrenceRule = true
                result.warnings.append(
                    "An event uses a repeating rule, which this app does not expand. "
                        + "It is flagged for review (UID \(current!.uid))."
                )
            default:
                break
            }
        }

        if inEvent {
            result.warnings.append("The feed ended inside an event; it may be truncated.")
        }

        return result
    }
}
