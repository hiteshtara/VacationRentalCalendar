import Foundation

/// One unfolded iCalendar content line: `NAME;PARAM=VALUE:value`.
public struct ICalContentLine: Hashable, Sendable {
    public let name: String
    public let parameters: [String: String]
    public let rawValue: String

    public init(name: String, parameters: [String: String], rawValue: String) {
        self.name = name
        self.parameters = parameters
        self.rawValue = rawValue
    }

    public func parameter(_ key: String) -> String? {
        parameters[key.uppercased()]
    }

    /// RFC 5545 §3.3.11 TEXT: unescape `\n`, `\,`, `\;`, `\\`.
    public var textValue: String {
        var result = ""
        var iterator = rawValue.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let next = iterator.next() else {
                result.append("\\")
                break
            }
            switch next {
            case "n", "N": result.append("\n")
            case "\\": result.append("\\")
            case ",": result.append(",")
            case ";": result.append(";")
            default:
                result.append("\\")
                result.append(next)
            }
        }
        return result
    }
}

/// Turns raw .ics bytes into unfolded content lines.
public enum ICalLexer {
    /// RFC 5545 §3.1 line unfolding: a CRLF followed by a space or tab is a
    /// continuation. Real feeds also use bare LF, so both are handled.
    public static func unfold(_ text: String) -> [String] {
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines: [String] = []
        for rawLine in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let first = line.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += String(line.dropFirst())
            } else {
                lines.append(line)
            }
        }
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Splits `NAME;PARAM="x:y";OTHER=z:the value` respecting quoted parameters.
    public static func parse(line: String) -> ICalContentLine? {
        var nameAndParameters = ""
        var value = ""
        var inQuotes = false
        var foundColon = false

        for character in line {
            if foundColon {
                value.append(character)
                continue
            }
            if character == "\"" {
                inQuotes.toggle()
                nameAndParameters.append(character)
                continue
            }
            if character == ":" && !inQuotes {
                foundColon = true
                continue
            }
            nameAndParameters.append(character)
        }

        guard foundColon else { return nil }

        // Split name from parameters on unquoted semicolons.
        var segments: [String] = []
        var current = ""
        inQuotes = false
        for character in nameAndParameters {
            if character == "\"" { inQuotes.toggle(); continue }
            if character == ";" && !inQuotes {
                segments.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        segments.append(current)

        guard let name = segments.first?.uppercased(), !name.isEmpty else { return nil }

        var parameters: [String: String] = [:]
        for segment in segments.dropFirst() {
            guard let equals = segment.firstIndex(of: "=") else {
                parameters[segment.uppercased()] = ""
                continue
            }
            let key = String(segment[segment.startIndex..<equals]).uppercased()
            let parameterValue = String(segment[segment.index(after: equals)...])
            parameters[key] = parameterValue
        }

        return ICalContentLine(name: name, parameters: parameters, rawValue: value)
    }
}
