import Foundation

/// A page as a file: YAML frontmatter, then the body — its title in the
/// frontmatter, or the `# Heading` the body opens with, as Prism titles
/// notes (see docs/markdown.md).
///
/// ```
/// ---
/// id: 01jbxk3t6y8q2zp4m9v7c5r0wd
/// tags: [Welcome]
/// wiki: true
/// ---
/// # HelloThere
///
/// Welcome to [[TiddlyWiki]]…
/// ```
///
/// A page's `text` is its body without that heading. Reading a file and
/// writing it back unchanged gives the same bytes; a page written over its
/// file changes only the entries that changed, the heading if its title
/// did, and the body if it did.
public enum PageFile {
    /// The page in a file's text. `fallbackTitle` names one whose file
    /// gives no title: its day, its week, its file's name — or, with
    /// `fixedTitle`, every one: a day's page is its date, whatever heads it.
    public static func read(_ source: String, fallbackTitle: String, fixedTitle: Bool = false) -> Page {
        let parts = split(source)
        let header = Header(raw: parts.header ?? "")
        var title = fixedTitle ? fallbackTitle : header["title"]?.text.flatMap { $0.isEmpty ? nil : $0 }
        var text = parts.body
        if title == nil, let heading = heading(parts.body) {
            title = heading.title
            text = heading.rest
        }
        var page = Page(title: title ?? fallbackTitle,
                        id: header["id"]?.text,
                        tags: tags(header["tags"]),
                        created: header["created"]?.text.flatMap(date),
                        modified: header["modified"]?.text.flatMap(date),
                        text: text)
        var seen = Set<String>()
        for entry in header.entries {
            guard let key = entry.key, let value = entry.value, !Page.reservedFields.contains(key),
                  seen.insert(key).inserted else { continue }
            page.fields.append(Page.Field(key, value))
        }
        return page
    }

    /// The file's text for a page, written over `source` — its file as it
    /// was — keeping what has not changed as it was written. A page titled
    /// by its heading keeps it so; a title that is still `fallbackTitle`, in
    /// a file that never gave one, is not written. A new file is titled by a
    /// `# Heading` with `headingTitle`, else in its frontmatter — or not at
    /// all, when the title is its `fallbackTitle`.
    public static func write(_ page: Page, over source: String? = nil, fallbackTitle: String? = nil,
                             headingTitle: Bool = false, fixedTitle: Bool = false) -> String {
        guard let source else {
            let titled = !headingTitle && !fixedTitle && page.title != fallbackTitle
            let lines = entries(for: page, title: titled).flatMap { Header.lines(key: $0.key, value: $0.value) }
            let body = headingTitle ? "# \(page.title)\n" + (page.text.isEmpty ? "" : "\n" + page.text) : page.text
            return lines.isEmpty ? body : "---\n" + lines.joined(separator: "\n") + "\n---\n" + body
        }
        let parts = split(source)
        let old = Header(raw: parts.header ?? "")
        let oldHeading = old["title"] == nil && !fixedTitle ? heading(parts.body) : nil
        // Titled now, where it was not — as an untitled page given a title
        // is — by a heading, as a new page is.
        let headed = headingTitle && !fixedTitle && oldHeading == nil && old["title"] == nil && page.title != fallbackTitle
        let titled = !fixedTitle && oldHeading == nil && !headed && (old["title"] != nil || page.title != fallbackTitle)
        let wanted = entries(for: page, title: titled)
        let wantedByKey = Dictionary(wanted.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        var lines: [String] = []
        var written = Set<String>()
        for entry in old.entries {
            guard let key = entry.key else {
                lines += entry.lines
                continue
            }
            guard let value = wantedByKey[key], written.insert(key).inserted else { continue }
            lines += same(key: key, entry.value, value) ? entry.lines : Header.lines(key: key, value: value)
        }
        for entry in wanted where !written.contains(entry.key) {
            lines += Header.lines(key: entry.key, value: entry.value)
        }
        var body = page.text
        if headed {
            body = "# \(page.title)\n" + (page.text.isEmpty ? "" : "\n" + page.text)
        } else if let oldHeading {
            let line = page.title == oldHeading.title ? oldHeading.line : "# \(page.title)"
            body = oldHeading.leading + line + oldHeading.after + page.text
        }
        guard let header = parts.header else {
            return lines.isEmpty ? body : "---\n" + lines.joined(separator: "\n") + "\n---\n" + body
        }
        // Every key it had taken out: no frontmatter left, empty.
        if lines.isEmpty, old.entries.contains(where: { $0.key != nil }) { return body }
        // An empty header's closing fence has no newline before it to keep.
        let gap = header.isEmpty && !lines.isEmpty ? "\n" : ""
        return parts.open + lines.joined(separator: "\n") + gap + parts.close + body
    }

    /// The `# Heading` a body opens with — after blank lines, if any — that
    /// titles its page: the title; the blank lines before it, its line, and
    /// what follows it (its line's end, and a blank line under it); and the
    /// rest of the body.
    static func heading(_ body: String) -> (title: String, leading: String, line: String, after: String, rest: String)? {
        let lines = Self.lines(body)
        var index = 0
        while index < lines.count, lines[index].content.allSatisfy({ $0 == " " || $0 == "\t" }), !lines[index].end.isEmpty { index += 1 }
        guard index < lines.count else { return nil }
        let line = lines[index].content
        guard line.hasPrefix("# ") else { return nil }
        let title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        let leading = lines[..<index].map { $0.content + $0.end }.joined()
        var after = lines[index].end
        var restStart = index + 1
        if restStart < lines.count, lines[restStart].content.isEmpty, !lines[restStart].end.isEmpty {
            after += lines[restStart].end
            restStart += 1
        }
        let rest = lines[restStart...].map { $0.content + $0.end }.joined()
        return (title, leading, line, after, rest)
    }

    /// A text's lines, each with how it ends: `\n`, `\r\n`, or nothing,
    /// for the last. Worked out by Unicode scalars.
    static func lines(_ text: String) -> [(content: String, end: String)] {
        var result: [(content: String, end: String)] = []
        var current = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        var pending = scalars.next()
        while let scalar = pending {
            pending = scalars.next()
            if scalar == "\n" {
                var content = String(current)
                var end = "\n"
                if content.hasSuffix("\r") {
                    content.removeLast()
                    end = "\r\n"
                }
                result.append((content, end))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { result.append((String(current), "")) }
        return result
    }

    // MARK: Parts

    /// A file's frontmatter (without its fences) and body; `open` and
    /// `close` are the fences as written, newlines and all. Worked out by
    /// Unicode scalars, not characters, since `\r\n` is one character.
    static func split(_ source: String) -> (open: String, header: String?, close: String, body: String) {
        let scalars = Array(source.unicodeScalars)
        func text(_ range: Range<Int>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[range])
            return String(view)
        }
        /// Where a `---` line at `index` ends, past its newline; `...` closes too.
        func fence(at index: Int, closing: Bool) -> Int? {
            guard index + 3 <= scalars.count else { return nil }
            let marker = String(String.UnicodeScalarView(scalars[index..<(index + 3)]))
            guard marker == "---" || (closing && marker == "...") else { return nil }
            var end = index + 3
            while end < scalars.count, scalars[end] == " " || scalars[end] == "\t" { end += 1 }
            if end == scalars.count { return closing ? end : nil }
            if scalars[end] == "\r", end + 1 < scalars.count, scalars[end + 1] == "\n" { return end + 2 }
            return scalars[end] == "\n" ? end + 1 : nil
        }
        guard let open = fence(at: 0, closing: false) else { return ("", nil, "", source) }
        if let end = fence(at: open, closing: true) {
            return (text(0..<open), "", text(open..<end), text(end..<scalars.count))
        }
        var search = open
        while let newline = scalars[search...].firstIndex(of: "\n") {
            if let end = fence(at: newline + 1, closing: true) {
                // The newline before the closing fence belongs to the fence.
                let headerEnd = newline > open && scalars[newline - 1] == "\r" ? newline - 1 : newline
                return (text(0..<open), text(open..<headerEnd), text(headerEnd..<end), text(end..<scalars.count))
            }
            search = newline + 1
        }
        return ("", nil, "", source)
    }

    // MARK: Entries

    private static func entries(for page: Page, title: Bool) -> [(key: String, value: Page.Value)] {
        var entries: [(key: String, value: Page.Value)] = []
        if let id = page.id { entries.append(("id", .text(id))) }
        if title { entries.append(("title", .text(page.title))) }
        if !page.tags.isEmpty { entries.append(("tags", .list(page.tags))) }
        if let created = page.created { entries.append(("created", .text(format(created)))) }
        if let modified = page.modified { entries.append(("modified", .text(format(modified)))) }
        for field in page.fields where !Page.reservedFields.contains(field.name) {
            entries.append((field.name, field.value))
        }
        return entries
    }

    private static func same(key: String, _ old: Page.Value?, _ new: Page.Value) -> Bool {
        guard let old else { return false }
        if key == "created" || key == "modified", let a = old.text.flatMap(date), let b = new.text.flatMap(date) {
            return milliseconds(a) == milliseconds(b)
        }
        if key == "tags" { return tags(old) == tags(new) }
        return old == new
    }

    private static func tags(_ value: Page.Value?) -> [String] {
        switch value {
        case .list(let items): items
        case .text(let text): text.isEmpty ? [] : [text]
        case nil: []
        }
    }

    // MARK: Dates

    /// `2026-10-31T10:41:12Z`, with milliseconds when there are any.
    public static func format(_ date: Date) -> String {
        let total = milliseconds(date)
        let fraction = Int(((total % 1000) + 1000) % 1000)
        let seconds = Date(timeIntervalSince1970: Double(total - Int64(fraction)) / 1000)
        let whole = seconds.formatted(Date.ISO8601FormatStyle())
        return fraction == 0 ? whole : whole.dropLast() + String(format: ".%03dZ", fraction)
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// An ISO 8601 date, with or without a time or fractions of a second, or
    /// TiddlyWiki's `YYYYMMDDhhmmssSSS`.
    public static func date(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle()) { return date }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle().year().month().day()) { return date }
        return TiddlyWikiDate.parse(text)
    }
}

/// TiddlyWiki's dates: `YYYYMMDDhhmmssSSS`, in UTC, the later parts optional.
public enum TiddlyWikiDate {
    public static func parse(_ text: String) -> Date? {
        let digits = Array(text.utf8)
        guard digits.count >= 8, digits.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        func number(_ start: Int, _ length: Int) -> Int {
            guard start + length <= digits.count else { return 0 }
            return digits[start..<(start + length)].reduce(0) { $0 * 10 + Int($1 - 48) }
        }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = number(0, 4)
        components.month = number(4, 2)
        components.day = number(6, 2)
        components.hour = number(8, 2)
        components.minute = number(10, 2)
        components.second = number(12, 2)
        guard let date = components.date else { return nil }
        return date.addingTimeInterval(Double(number(14, 3)) / 1000)
    }
}
