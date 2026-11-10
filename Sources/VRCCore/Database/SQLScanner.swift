import Foundation

/// Minimal SQL lexing, for the two jobs the Data API forces on us.
///
/// The repositories are written against SQLite's `?` placeholders. The Data API
/// takes named parameters, so the `?` have to be rewritten — and a rewriter
/// that does not understand string literals would corrupt any SQL containing a
/// literal question mark. There is such SQL in this project: reason text,
/// summaries, and the `'%?%'` style patterns a search can produce.
///
/// This is not a SQL parser and does not try to be. It tracks exactly the
/// contexts in which a `?` is not a placeholder.
public enum SQLScanner {

    public struct Rewritten: Sendable, Equatable {
        public var sql: String
        public var placeholderCount: Int
    }

    /// Replaces each positional `?` with `:p0`, `:p1`, … in order, leaving
    /// anything inside a string literal, a quoted identifier, a line comment
    /// or a block comment untouched.
    public static func rewritePlaceholders(_ sql: String) -> Rewritten {
        var output = ""
        output.reserveCapacity(sql.count + 16)
        var index = 0
        var placeholders = 0

        enum Context { case code, singleQuoted, doubleQuoted, lineComment, blockComment, dollarQuoted }
        var context = Context.code
        var dollarTag = ""

        let characters = Array(sql)
        func peek(_ offset: Int) -> Character? {
            let target = index + offset
            return target < characters.count ? characters[target] : nil
        }

        while index < characters.count {
            let character = characters[index]

            switch context {
            case .code:
                if character == "'" {
                    context = .singleQuoted
                } else if character == "\"" {
                    context = .doubleQuoted
                } else if character == "-", peek(1) == "-" {
                    context = .lineComment
                } else if character == "/", peek(1) == "*" {
                    context = .blockComment
                } else if character == "$" {
                    // Postgres dollar quoting: $$ … $$ or $tag$ … $tag$.
                    var scan = index + 1
                    var tag = ""
                    while scan < characters.count, characters[scan] != "$" {
                        tag.append(characters[scan]); scan += 1
                    }
                    if scan < characters.count, characters[scan] == "$",
                       tag.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                        dollarTag = "$\(tag)$"
                        output += dollarTag
                        index = scan + 1
                        context = .dollarQuoted
                        continue
                    }
                } else if character == "?" {
                    output += ":p\(placeholders)"
                    placeholders += 1
                    index += 1
                    continue
                }

            case .singleQuoted:
                // '' is an escaped quote, not the end of the literal.
                if character == "'" {
                    if peek(1) == "'" {
                        output.append(character); output.append("'")
                        index += 2
                        continue
                    }
                    context = .code
                }

            case .doubleQuoted:
                if character == "\"" {
                    if peek(1) == "\"" {
                        output.append(character); output.append("\"")
                        index += 2
                        continue
                    }
                    context = .code
                }

            case .lineComment:
                if character == "\n" { context = .code }

            case .blockComment:
                if character == "*", peek(1) == "/" {
                    output.append("*"); output.append("/")
                    index += 2
                    context = .code
                    continue
                }

            case .dollarQuoted:
                if character == "$", !dollarTag.isEmpty {
                    let remaining = characters.count - index
                    if remaining >= dollarTag.count,
                       String(characters[index..<(index + dollarTag.count)]) == dollarTag {
                        output += dollarTag
                        index += dollarTag.count
                        context = .code
                        dollarTag = ""
                        continue
                    }
                }
            }

            output.append(character)
            index += 1
        }

        return Rewritten(sql: output, placeholderCount: placeholders)
    }

    /// Splits a script into statements, on semicolons that are genuinely
    /// terminators.
    ///
    /// Dollar-quoting is the part that matters. A PostgreSQL function body is
    /// written `AS $$ … $$`, and those bodies are full of semicolons. A
    /// splitter that does not track them shreds every `CREATE FUNCTION` into
    /// fragments — which is exactly what this did before, turning one function
    /// into five "statements" and making it impossible to run a migration over
    /// the Data API, where statements must be sent one at a time.
    public static func splitStatements(_ sql: String) -> [String] {
        var statements: [String] = []
        var current = ""
        var depth = 0

        enum Context { case code, singleQuoted, doubleQuoted, lineComment, blockComment, dollarQuoted }
        var context = Context.code
        var dollarTag = ""

        let characters = Array(sql)
        var index = 0

        func peek(_ offset: Int) -> Character? {
            let target = index + offset
            return target < characters.count ? characters[target] : nil
        }

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { statements.append(trimmed) }
            current = ""
        }

        while index < characters.count {
            let character = characters[index]

            switch context {
            case .code:
                if character == "'" { context = .singleQuoted }
                else if character == "\"" { context = .doubleQuoted }
                else if character == "-", peek(1) == "-" { context = .lineComment }
                else if character == "/", peek(1) == "*" { context = .blockComment }
                else if character == "$" {
                    // $$ … $$ or $tag$ … $tag$
                    var scan = index + 1
                    var tag = ""
                    while scan < characters.count, characters[scan] != "$" {
                        tag.append(characters[scan]); scan += 1
                    }
                    if scan < characters.count, characters[scan] == "$",
                       tag.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                        dollarTag = "$\(tag)$"
                        current += dollarTag
                        index = scan + 1
                        context = .dollarQuoted
                        continue
                    }
                }
                else if character == "(" { depth += 1 }
                else if character == ")" { depth = max(0, depth - 1) }
                else if character == ";", depth == 0 {
                    flush()
                    index += 1
                    continue
                }

            case .singleQuoted:
                if character == "'" {
                    if peek(1) == "'" { current += "''"; index += 2; continue }
                    context = .code
                }

            case .doubleQuoted:
                if character == "\"" {
                    if peek(1) == "\"" { current += "\"\""; index += 2; continue }
                    context = .code
                }

            case .lineComment:
                if character == "\n" { context = .code }

            case .blockComment:
                if character == "*", peek(1) == "/" {
                    current += "*/"; index += 2; context = .code; continue
                }

            case .dollarQuoted:
                if character == "$", !dollarTag.isEmpty,
                   characters.count - index >= dollarTag.count,
                   String(characters[index..<(index + dollarTag.count)]) == dollarTag {
                    current += dollarTag
                    index += dollarTag.count
                    context = .code
                    dollarTag = ""
                    continue
                }
            }

            current.append(character)
            index += 1
        }

        flush()
        return statements
    }

}
