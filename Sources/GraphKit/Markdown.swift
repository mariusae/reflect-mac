import Foundation

/// A page's Markdown as blocks, to be shown: the Markdown weft writes
/// (and the importer makes), not all of CommonMark.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([ListItem])
    case quote([MarkdownBlock])
    /// `> [!TIP]` and its kin.
    case callout(kind: String, blocks: [MarkdownBlock])
    case code(language: String, text: String)
    /// WikiText the importer could not convert, in a ```` ```tiddlywiki ```` fence.
    case wikiText(String)
    /// A ```` ```query ```` block: pages found and shown.
    case query(Query)
    case table(header: [String], rows: [[String]])
    /// A paragraph that is a picture and nothing else.
    case image(alt: String, source: String, width: Double?)
    /// A paragraph that is `![[Title]]` and nothing else.
    case embed(String)
    case rule

    public struct ListItem: Equatable, Sendable {
        /// 0 for the outermost list.
        public var depth: Int
        public var ordered: Bool
        /// `- [ ]` and `- [x]`.
        public var checked: Bool?
        public var text: String
    }

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var parser = Parser(lines: markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
        return parser.blocks()
    }
}

private struct Parser {
    let lines: [String]
    var index = 0

    init(lines: [String]) {
        self.lines = lines
    }

    mutating func blocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
            } else if let fence = Self.fence(line) {
                blocks.append(code(fence))
            } else if let heading = Self.heading(line) {
                blocks.append(heading)
                index += 1
            } else if Self.isRule(trimmed) {
                blocks.append(.rule)
                index += 1
            } else if line.hasPrefix(">") {
                blocks.append(quote())
            } else if Self.listMarker(line) != nil {
                blocks.append(list())
            } else if line.hasPrefix("|"), index + 1 < lines.count, Self.isTableSeparator(lines[index + 1]) {
                blocks.append(table())
            } else {
                blocks.append(paragraph())
            }
        }
        return blocks
    }

    // MARK: Code

    /// A fence's backticks and language: ```` ```swift ````.
    private static func fence(_ line: String) -> (marker: String, language: String)? {
        let ticks = line.prefix { $0 == "`" }
        guard ticks.count >= 3 else { return nil }
        let language = line.dropFirst(ticks.count).trimmingCharacters(in: .whitespaces)
        guard !language.contains("`") else { return nil }
        return (String(ticks), language)
    }

    private mutating func code(_ fence: (marker: String, language: String)) -> MarkdownBlock {
        index += 1
        var body: [String] = []
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.hasPrefix(fence.marker), line.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == "`" }) { break }
            body.append(line)
        }
        let text = body.joined(separator: "\n")
        switch fence.language {
        case "tiddlywiki": return .wikiText(text)
        case "query": return .query(Query(text: text))
        default: return .code(language: fence.language, text: text)
        }
    }

    // MARK: Headings, rules

    private static func heading(_ line: String) -> MarkdownBlock? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    // MARK: Quotes

    private mutating func quote() -> MarkdownBlock {
        var inner: [String] = []
        while index < lines.count, lines[index].hasPrefix(">") {
            var line = lines[index].dropFirst()
            if line.hasPrefix(" ") { line = line.dropFirst() }
            inner.append(String(line))
            index += 1
        }
        if let first = inner.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("[!"), first.hasSuffix("]") {
            let kind = String(first.dropFirst(2).dropLast()).lowercased()
            var parser = Parser(lines: Array(inner.dropFirst()))
            return .callout(kind: kind, blocks: parser.blocks())
        }
        var parser = Parser(lines: inner)
        return .quote(parser.blocks())
    }

    // MARK: Lists

    /// A list item's indentation, whether it is numbered, and where its text starts.
    private static func listMarker(_ line: String) -> (indent: Int, ordered: Bool, text: Substring)? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return (indent, false, rest.dropFirst(2))
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count < 10 {
            let after = rest.dropFirst(digits.count)
            if let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " {
                return (indent, true, after.dropFirst(2))
            }
        }
        return nil
    }

    private mutating func list() -> MarkdownBlock {
        var items: [MarkdownBlock.ListItem] = []
        // The indentation of each list we are in, outermost first.
        var indents: [Int] = []
        while index < lines.count {
            let line = lines[index]
            if let marker = Self.listMarker(line) {
                while let last = indents.last, marker.indent < last { indents.removeLast() }
                if indents.last.map({ marker.indent > $0 }) ?? true { indents.append(marker.indent) }
                var text = marker.text.trimmingCharacters(in: .whitespaces)
                var checked: Bool?
                for (box, value) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(box) {
                    checked = value
                    text = String(text.dropFirst(box.count))
                }
                items.append(.init(depth: indents.count - 1, ordered: marker.ordered, checked: checked, text: text))
                index += 1
            } else if !items.isEmpty, line.hasPrefix(" "), !line.trimmingCharacters(in: .whitespaces).isEmpty {
                // A line carried on from the item above.
                items[items.count - 1].text += "\n" + line.trimmingCharacters(in: .whitespaces)
                index += 1
            } else {
                break
            }
        }
        return .list(items)
    }

    // MARK: Tables

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private mutating func table() -> MarkdownBlock {
        let header = Self.cells(lines[index])
        index += 2
        var rows: [[String]] = []
        while index < lines.count, lines[index].hasPrefix("|") {
            rows.append(Self.cells(lines[index]))
            index += 1
        }
        return .table(header: header, rows: rows)
    }

    /// A row's cells, split at `|` not escaped, with `\|` unescaped.
    private static func cells(_ line: String) -> [String] {
        var body = Substring(line.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") && !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped {
                current += character == "|" ? "|" : "\\\(character)"
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current += "\\" }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: Paragraphs

    private mutating func paragraph() -> MarkdownBlock {
        var body: [String] = []
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if !body.isEmpty, Self.fence(line) != nil || Self.heading(line) != nil || line.hasPrefix(">")
                || Self.listMarker(line) != nil && !line.hasPrefix(" ") { break }
            body.append(line)
            index += 1
        }
        let text = body.joined(separator: "\n")
        if let embed = Self.wholeEmbed(text) { return .embed(embed) }
        if let image = Self.wholeImage(text) { return image }
        return .paragraph(text)
    }

    private static func wholeEmbed(_ text: String) -> String? {
        guard text.hasPrefix("![["), text.hasSuffix("]]"), !text.dropFirst(3).dropLast(2).contains("]]") else { return nil }
        let title = text.dropFirst(3).dropLast(2)
        return String(title.split(separator: "|", maxSplits: 1).first ?? title)
    }

    /// `![alt](source)`, and the width Reflect notes after it, `<!-- {"width":425} -->`.
    private static func wholeImage(_ text: String) -> MarkdownBlock? {
        guard text.hasPrefix("!["), let altEnd = text.range(of: "]("), let close = text[altEnd.upperBound...].firstIndex(of: ")") else {
            return nil
        }
        let rest = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
        var width: Double?
        if !rest.isEmpty {
            guard rest.hasPrefix("<!--"), rest.hasSuffix("-->") else { return nil }
            let json = rest.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces)
            if let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                width = (object["width"] as? NSNumber)?.doubleValue
            }
        }
        let alt = String(text[text.index(text.startIndex, offsetBy: 2)..<altEnd.lowerBound])
        return .image(alt: alt, source: String(text[altEnd.upperBound..<close]), width: width)
    }
}

/// Inline Markdown made ready for a renderer that knows CommonMark's
/// inline syntax and no more (as `AttributedString(markdown:)` does):
/// wiki links become links to `weft://open?title=…`, and the bits of HTML
/// the importer writes are taken out.
public enum InlineMarkdown {
    public static let scheme = "weft"

    /// The address a link to a page goes to.
    public static func url(for title: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "title", value: title)]
        return components.url!
    }

    /// The page an address made by `url(for:)` is to.
    public static func title(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "open" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "title" }?.value
    }

    public static func prepared(_ text: String) -> String {
        var output = ""
        let characters = Array(text)
        var index = 0
        func at(_ string: String) -> Bool {
            let needle = Array(string)
            return index + needle.count <= characters.count && characters[index..<(index + needle.count)].elementsEqual(needle)
        }
        func find(_ string: String, from start: Int) -> Int? {
            let needle = Array(string)
            var offset = start
            while offset + needle.count <= characters.count {
                if characters[offset..<(offset + needle.count)].elementsEqual(needle) { return offset }
                offset += 1
            }
            return nil
        }
        while index < characters.count {
            let character = characters[index]
            // An escape passes the next character as it is.
            if character == "\\", index + 1 < characters.count {
                output.append(character)
                output.append(characters[index + 1])
                index += 2
                continue
            }
            // Code is left alone.
            if character == "`" {
                let run = characters[index...].prefix { $0 == "`" }.count
                let fence = String(repeating: "`", count: run)
                if let end = find(fence, from: index + run) {
                    output += String(characters[index..<(end + run)])
                    index = end + run
                    continue
                }
            }
            if at("![[") || at("[["), let end = find("]]", from: index + (at("![[") ? 3 : 2)) {
                let start = index + (at("![[") ? 3 : 2)
                let body = String(characters[start..<end]).replacingOccurrences(of: "\\|", with: "|")
                let parts = body.split(separator: "|", maxSplits: 1).map(String.init)
                let target = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
                let shown = parts.count > 1 ? parts[1] : target
                output += "[\(escapeLinkText(shown))](\(url(for: target).absoluteString))"
                index = end + 2
                continue
            }
            // WikiText left in a line — a macro call, a widget — is shown as code.
            if at("<<"), let end = find(">>", from: index + 2) {
                let call = String(characters[index..<(end + 2)])
                output += call.contains("`") ? call : "`\(call)`"
                index = end + 2
                continue
            }
            if at("<$") || at("</$"), let end = find(">", from: index + 2) {
                let tag = String(characters[index...end])
                output += tag.contains("`") ? tag : "`\(tag)`"
                index = end + 1
                continue
            }
            if at("<!--"), let end = find("-->", from: index + 4) {
                index = end + 3
                continue
            }
            if character == "<", let end = find(">", from: index + 1) {
                let tag = String(characters[(index + 1)..<end]).lowercased()
                if ["u", "/u", "sup", "/sup", "sub", "/sub", "kbd", "/kbd", "br", "br/", "br /", "code", "/code"].contains(tag) {
                    output += tag.hasPrefix("br") ? "  \n" : tag.hasSuffix("code") ? "`" : ""
                    index = end + 1
                    continue
                }
            }
            output.append(character)
            index += 1
        }
        return output
    }

    private static func escapeLinkText(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
}
