import Foundation

/// The frontmatter a page's file starts with: a small part of YAML.
/// `key: value`, plain or quoted; lists, `[a, b]` or one `- item` a line;
/// and `|` blocks for text over several lines. Every value is text or a
/// list of text — no numbers, no nesting.
///
/// Each entry keeps the lines it was read from, so that a header written
/// back with an entry unchanged writes that entry's lines as they were.
struct Header {
    struct Entry {
        /// Nil for a line that is no entry: blank, or a comment.
        var key: String?
        var lines: [String]
        var value: Page.Value?
    }

    var entries: [Entry]

    init(raw: String) {
        entries = []
        guard !raw.isEmpty else { return }
        // Split by scalars: `\r\n` is one character, and its `\r` is kept.
        let lines = raw.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let content = Self.trimmingCR(line[...])
            guard let first = content.first, first != "#", !first.isWhitespace, first != "-",
                  let colon = Self.keyColon(content) else {
                entries.append(Entry(key: nil, lines: [line]))
                continue
            }
            var entryLines = [line]
            // What follows the key and belongs to it: indented lines, or a
            // list's `- ` items at the left edge.
            while index < lines.count {
                let next = Self.trimmingCR(lines[index][...])
                let continues = next.first.map { $0 == " " || $0 == "\t" || $0 == "-" } ?? false
                guard continues else { break }
                entryLines.append(lines[index])
                index += 1
            }
            let key = Self.unquoteKey(content[..<colon].trimmingCharacters(in: .whitespaces))
            let inline = content[content.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let rest = entryLines.dropFirst().map { Self.trimmingCR($0[...]) }
            entries.append(Entry(key: key, lines: entryLines, value: Self.value(inline: inline, rest: Array(rest))))
        }
    }

    subscript(key: String) -> Page.Value? {
        entries.first { $0.key == key }?.value
    }

    var keys: [String] { entries.compactMap(\.key) }

    // MARK: Reading values

    private static func trimmingCR(_ line: Substring) -> Substring {
        line.hasSuffix("\r") ? line.dropLast() : line
    }

    /// The colon ending a key: the first followed by a space or the end of
    /// the line, outside quotes.
    private static func keyColon(_ line: Substring) -> Substring.Index? {
        var quote: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                if index == line.startIndex { quote = character }
            } else if character == ":" {
                let next = line.index(after: index)
                if next == line.endIndex || line[next] == " " || line[next] == "\t" { return index }
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static func unquoteKey(_ key: String) -> String {
        guard let first = key.first, first == "\"" || first == "'", key.count >= 2, key.last == first else { return key }
        return unquote(key)
    }

    private static func value(inline: String, rest: [Substring]) -> Page.Value {
        if inline.hasPrefix("|") || inline.hasPrefix(">") {
            return .text(block(indicator: inline, lines: rest))
        }
        if inline.hasPrefix("[") {
            return .list(flowList(inline))
        }
        if inline.isEmpty, !rest.isEmpty, rest.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") }) {
            return .list(rest.map { item in
                let trimmed = item.trimmingCharacters(in: .whitespaces).dropFirst()
                return scalar(trimmed.trimmingCharacters(in: .whitespaces))
            })
        }
        if inline.hasPrefix("\"") || inline.hasPrefix("'") {
            // A quoted value may run on over lines; they are joined by spaces.
            let joined = ([inline] + rest.map { $0.trimmingCharacters(in: .whitespaces) }).joined(separator: " ")
            return .text(unquote(joined))
        }
        let parts = [inline] + rest.map { $0.trimmingCharacters(in: .whitespaces) }
        return .text(parts.map(stripComment).filter { !$0.isEmpty }.joined(separator: " "))
    }

    private static func scalar(_ text: String) -> String {
        text.hasPrefix("\"") || text.hasPrefix("'") ? unquote(text) : stripComment(text)
    }

    private static func stripComment(_ text: String) -> String {
        guard let range = text.range(of: " #") else { return text }
        return text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
    }

    /// `|`, `|-`, `|+` (and `>` folded) with the lines under it, unindented.
    private static func block(indicator: String, lines: [Substring]) -> String {
        let folded = indicator.hasPrefix(">")
        let chomp = indicator.contains("-") ? "strip" : indicator.contains("+") ? "keep" : "clip"
        let indent = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " }.count } ?? 0
        var body = lines.map { line in line.count >= indent ? String(line.dropFirst(indent)) : "" }
        var trailing = 0
        while let last = body.last, last.isEmpty {
            body.removeLast()
            trailing += 1
        }
        var text = folded ? body.joined(separator: " ") : body.joined(separator: "\n")
        switch chomp {
        case "strip": break
        case "keep": text += String(repeating: "\n", count: trailing + 1)
        default: text += "\n"
        }
        return text
    }

    private static func flowList(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        let inner = text.dropFirst().reversed().drop { $0 != "]" }.dropFirst().reversed()
        for character in inner {
            if let open = quote {
                current.append(character)
                if open == "\"" && character == "\\" && !escaped {
                    escaped = true
                    continue
                }
                if character == open && !escaped { quote = nil }
                escaped = false
            } else if (character == "\"" || character == "'") && current.allSatisfy(\.isWhitespace) {
                quote = character
                current.append(character)
            } else if character == "," {
                items.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        items.append(current)
        // An empty item is a trailing comma's, unless it was quoted.
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map(scalar)
    }

    static func unquote(_ text: String) -> String {
        guard let quote = text.first, quote == "\"" || quote == "'" else { return text }
        var body = text.dropFirst()
        if body.last == quote { body = body.dropLast() }
        if quote == "'" { return body.replacingOccurrences(of: "''", with: "'") }
        var result = ""
        var iterator = body.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                result.append(character)
                continue
            }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "0": result.append("\0")
            case "u", "x":
                let count = next == "u" ? 4 : 2
                var hex = ""
                for _ in 0..<count { if let digit = iterator.next() { hex.append(digit) } }
                if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                }
            default: result.append(next)
            }
        }
        return result
    }

    // MARK: Writing values

    /// An entry's lines for a key and value, as weft writes them.
    static func lines(key: String, value: Page.Value) -> [String] {
        let name = isPlain(key, inFlow: true) ? key : quote(key)
        switch value {
        case .text(let text):
            if text.contains("\n"), let block = blockLines(text) {
                return ["\(name): \(block.indicator)"] + block.lines
            }
            return ["\(name): \(scalarText(text, inFlow: false))"]
        case .list(let items):
            if items.isEmpty { return ["\(name): []"] }
            let flow = "[" + items.map { scalarText($0, inFlow: true) }.joined(separator: ", ") + "]"
            // Short lists on one line; long ones an item a line, so that git
            // merges changes to different items.
            if items.count <= 4 && flow.count <= 60 { return ["\(name): \(flow)"] }
            return ["\(name):"] + items.map { "  - \(scalarText($0, inFlow: false))" }
        }
    }

    private static func blockLines(_ text: String) -> (indicator: String, lines: [String])? {
        guard !text.contains("\r"), !text.hasPrefix(" "), !text.hasPrefix("\n"), !text.contains("\t") else { return nil }
        var body = text
        var trailing = 0
        while body.hasSuffix("\n") {
            body.removeLast()
            trailing += 1
        }
        let indicator = trailing == 0 ? "|-" : trailing == 1 ? "|" : "|+"
        var lines = body.components(separatedBy: "\n").map { $0.isEmpty ? "" : "  " + $0 }
        if trailing > 1 { lines += Array(repeating: "", count: trailing - 1) }
        return (indicator, lines)
    }

    static func scalarText(_ text: String, inFlow: Bool) -> String {
        isPlain(text, inFlow: inFlow) ? text : quote(text)
    }

    /// Whether text reads back as itself written without quotes.
    static func isPlain(_ text: String, inFlow: Bool) -> Bool {
        guard let first = text.first, let last = text.last, !first.isWhitespace, !last.isWhitespace else { return false }
        if "-?:,[]{}#&*!|>'\"%@`".contains(first) { return false }
        if text.contains(": ") || text.contains(" #") || last == ":" { return false }
        if text.contains(where: { $0.isNewline || $0 == "\t" || $0.asciiValue.map { $0 < 0x20 } == true }) { return false }
        if inFlow && text.contains(where: { ",[]{}".contains($0) }) { return false }
        // `true`, `yes`, `4`: written plain — flags and numbers, as YAML
        // reads them, and as text here, which every value is.
        if ["null", "~"].contains(text.lowercased()) { return false }
        return true
    }

    static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\x%02x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}
