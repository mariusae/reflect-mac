import CryptoKit
import Foundation

/// A web page captured from a browser, as Reflect's clipper keeps one: a
/// note of its own — its title, its address, what it says of itself, the
/// passages highlighted on it — and linked from the day it was captured,
/// under `[[Links]]`.
///
/// Reflect's note: its `id` is `link-` and the SHA-256 of the address, so
/// a page captured again is the same note, which takes in the highlights it
/// did not have. Here a screenshot of the page goes in too.
public enum WebCapture {
    public struct Page: Sendable, Equatable {
        public var url: String
        public var title: String
        public var description: String
        public var highlights: [String]
        /// The screenshot, once saved: its source in the graph.
        public var screenshot: String?

        public init(url: String, title: String, description: String = "", highlights: [String] = [], screenshot: String? = nil) {
            self.url = url
            self.title = title
            self.description = description
            self.highlights = highlights
            self.screenshot = screenshot
        }
    }

    /// Reflect's id for a page's note.
    public static func id(for url: String) -> String {
        "link-" + SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A page's title as a note's: on one line, and with nothing a
    /// `[[link]]` to it would trip on — `|` as Reflect writes it, `｜`, and
    /// brackets as parentheses. The address's site, for a page with none.
    public static func title(_ raw: String, url: String) -> String {
        var title = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        title = title.replacingOccurrences(of: "|", with: "｜").replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
        if title.isEmpty { title = URL(string: url)?.host ?? url }
        return title
    }

    /// A highlight as a row's text: its lines trimmed, blank ones gone.
    static func clean(_ highlight: String) -> String {
        highlight.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: The note

    /// A page's note, new.
    public static func note(for page: Page) -> String {
        var rows = [
            Row(kind: .bullet, text: "URL: <\(page.url)>"),
            Row(kind: .bullet, text: "Description:" + (page.description.isEmpty ? "" : " " + oneLine(page.description))),
            Row(kind: .bullet, text: "Type: #link"),
        ]
        rows[0].gap = [""]
        if let screenshot = page.screenshot {
            rows.append(Row(kind: .bullet, text: "Screenshot"))
            rows.append(Row(kind: .bullet, depth: 1, text: "![](\(screenshot))"))
        }
        let highlights = page.highlights.map(clean).filter { !$0.isEmpty }
        if !highlights.isEmpty {
            rows.append(Row(kind: .bullet, text: "Highlights"))
            rows += highlights.map { Row(kind: .bullet, depth: 1, text: $0) }
        }
        let title = title(page.title, url: page.url)
        // A blank line after the frontmatter, and after the title, as Reflect writes them.
        var heading = Row(kind: .heading(1), text: title)
        heading.gap = [""]
        let outline = Outline(frontmatter: "---\nid: \"\(id(for: page.url))\"\n---", rows: [heading] + rows)
        return OutlineMarkdown.serialize(outline)
    }

    /// A page's note, captured again: the highlights it did not have added
    /// under Highlights, a screenshot when it had none, a description when
    /// its was empty. Everything else as it was written.
    public static func merging(_ page: Page, into source: String) -> String {
        var outline = OutlineMarkdown.parse(source)
        var rows = Row.unfold(outline.rows)
        func section(_ name: String) -> (index: Int, children: Range<Int>)? {
            guard let index = rows.firstIndex(where: { $0.depth == 0 && $0.text.trimmingCharacters(in: .whitespaces) == name }) else { return nil }
            var end = index + 1
            while end < rows.count, rows[end].depth > 0 { end += 1 }
            return (index, (index + 1)..<end)
        }
        if !page.description.isEmpty,
           let empty = rows.firstIndex(where: { $0.depth == 0 && $0.text.trimmingCharacters(in: .whitespaces) == "Description:" }) {
            rows[empty].text = "Description: " + oneLine(page.description)
        }
        if let screenshot = page.screenshot, !rows.contains(where: { $0.text.contains("![") }) {
            let at = section("Highlights")?.index ?? rows.count
            rows.insert(contentsOf: [Row(kind: .bullet, text: "Screenshot"), Row(kind: .bullet, depth: 1, text: "![](\(screenshot))")], at: at)
        }
        let highlights = page.highlights.map(clean).filter { !$0.isEmpty }
        if !highlights.isEmpty {
            if let (index, children) = section("Highlights") {
                let known = Set(rows[children].map { clean($0.text) })
                let new = highlights.filter { !known.contains($0) }
                rows.insert(contentsOf: new.map { Row(kind: .bullet, depth: rows[index].depth + 1, text: $0) }, at: children.upperBound)
            } else {
                rows.append(Row(kind: .bullet, text: "Highlights"))
                rows += highlights.map { Row(kind: .bullet, depth: 1, text: $0) }
            }
        }
        outline.rows = rows
        return OutlineMarkdown.serialize(outline)
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: The day

    /// A day's note with a link to a page's under `[[Links]]` — made, when
    /// the day has none — unless it links there already.
    public static func linking(_ title: String, fromDay source: String) -> String {
        let link = "[[\(title)]]"
        var outline = OutlineMarkdown.parse(source)
        var rows = outline.isBlank ? [] : outline.rows
        if let links = rows.firstIndex(where: { $0.depth == 0 && $0.text.trimmingCharacters(in: .whitespaces) == "[[Links]]" }) {
            var end = links + 1
            while end < rows.count, rows[end].depth > 0 { end += 1 }
            if rows[(links + 1)..<end].contains(where: { $0.text.trimmingCharacters(in: .whitespaces) == link }) { return source }
            if rows[links].isFolded {
                rows[links].folded.append(Row(kind: .bullet, depth: rows[links].depth + 1, text: link))
            } else {
                rows.insert(Row(kind: .bullet, depth: 1, text: link), at: end)
            }
        } else {
            rows.append(Row(kind: .bullet, text: "[[Links]]"))
            rows.append(Row(kind: .bullet, depth: 1, text: link))
        }
        outline.rows = rows
        return OutlineMarkdown.serialize(outline)
    }

    // MARK: Saving

    /// Saves a capture into a graph: the page's note — its own, when it was
    /// captured before, found by its id — and the link from the day's.
    /// Returns the note's path. The note goes in the inbox, to be dealt
    /// with — captured again, back in it.
    @discardableResult
    public static func save(_ page: Page, in graph: Graph, index: NoteIndex, on day: Day = .today, inbox: Bool = true) throws -> String {
        let id = id(for: page.url)
        let marker = "id: \"\(id)\""
        let existing = index.all.first { entry in
            entry.path.hasPrefix(GraphPaths.notesDirectory + "/") && (index.body(entry.path) ?? graph.read(path: entry.path) ?? "").contains(marker)
        }
        let path: String
        let title: String
        if let existing {
            path = existing.path
            title = existing.title
            let source = graph.read(path: path) ?? ""
            let merged = merging(page, into: source)
            if merged != source { try graph.write(merged, path: path) }
        } else {
            title = self.title(page.title, url: page.url)
            path = freePath(for: title, in: graph)
            try graph.write(note(for: page), path: path)
        }
        if inbox, let source = graph.read(path: path) {
            let flagged = Frontmatter.setting("inbox", to: "true", in: source)
            if flagged != source { try graph.write(flagged, path: path) }
        }
        index.refresh(path)
        let dayPath = GraphPaths.dailyPath(for: day)
        let daySource = graph.read(path: dayPath) ?? ""
        let linked = linking(title, fromDay: daySource)
        if linked != daySource {
            try graph.write(linked, path: dayPath)
            index.refresh(dayPath)
        }
        return path
    }

    /// `notes/<slug>.md`, or the first free `-2`, `-3`…
    static func freePath(for title: String, in graph: Graph) -> String {
        let slug = Assets.slug(title)
        for attempt in 1...1000 {
            let path = "\(GraphPaths.notesDirectory)/" + (attempt == 1 ? slug : "\(slug)-\(attempt)") + ".md"
            if !graph.exists(path: path) { return path }
        }
        return "\(GraphPaths.notesDirectory)/\(slug)-\(UUID().uuidString.prefix(8)).md"
    }
}
