import Foundation

/// A page made to name another title where it named one: TiddlyWiki's
/// relinking, when a page is renamed. Links and embeds — in table cells
/// too, their bars escaped — tags, `list` fields, the titles a query asks
/// for, and fields holding just the title; never inside code.
public enum Relink {
    public static func page(_ page: Page, from old: String, to new: String) -> Page {
        var result = page
        result.text = text(page.text, from: old, to: new)
        result.tags = page.tags.map { $0 == old ? new : $0 }
        result.fields = page.fields.map { field in
            switch field.value {
            case .list(let items): Page.Field(field.name, .list(items.map { $0 == old ? new : $0 }))
            case .text(let value): Page.Field(field.name, .text(value == old && field.name != "caption" ? new : value))
            }
        }
        return result
    }

    /// Markdown with `[[old]]`, `[[old|shown]]` and `![[old]]` leading to
    /// `new`, and query blocks asking for `old` asking for `new`.
    public static func text(_ text: String, from old: String, to new: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var fence: String?
        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                fence = fence == nil ? trimmed.drop { $0 == "`" }.trimmingCharacters(in: .whitespaces) : nil
                continue
            }
            if fence == "query" {
                lines[index] = queryLine(line, from: old, to: new)
                continue
            }
            guard fence == nil, line.contains("[[") else { continue }
            // Outside code spans only: the even pieces between backticks.
            let pieces = line.components(separatedBy: "`")
            lines[index] = pieces.enumerated().map { $0.offset % 2 == 0 ? links($0.element, from: old, to: new) : $0.element }
                .joined(separator: "`")
        }
        return lines.joined(separator: "\n")
    }

    private static func links(_ text: String, from old: String, to new: String) -> String {
        var output = ""
        var rest = Substring(text)
        while let open = rest.range(of: "[[") {
            output += rest[..<open.upperBound]
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "]]") else { break }
            let body = rest[..<close.lowerBound]
            // `target`, `target|shown`, or `target\|shown` in a table.
            let bar = body.range(of: "\\|") ?? body.range(of: "|")
            let target = bar.map { body[..<$0.lowerBound] } ?? body
            if target.trimmingCharacters(in: .whitespaces) == old {
                output += new + (bar.map { String(body[$0.lowerBound...]) } ?? "")
            } else {
                output += body
            }
            output += "]]"
            rest = rest[close.upperBound...]
        }
        return output + rest
    }

    private static let titleKeys: Set<String> = ["tag", "not tag", "links to", "linked from", "listed in"]

    private static func queryLine(_ line: String, from old: String, to new: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return line }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard titleKeys.contains(key), value == old else { return line }
        return line[...colon] + " " + new
    }
}
