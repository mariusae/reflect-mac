import Foundation

/// A few words put at the top of a day — typed or said in passing — as
/// rows of its note: each line a bullet, made when the day has no note.
public enum QuickNote {
    /// The rows for what was written: a bullet for each line with words on
    /// it — a bullet typed for it, its own.
    public static func rows(_ text: String) -> [Row] {
        text.split(whereSeparator: \.isNewline)
            .map { line in
                var line = line.trimmingCharacters(in: .whitespaces)
                if let marker = line.first, "-*+".contains(marker), line.dropFirst().first == " " {
                    line = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                }
                return line
            }
            .filter { !$0.isEmpty }
            .map { Row(kind: .bullet, text: $0) }
    }

    /// A day's note with `added` first — after its title, when it has one.
    public static func prepending(_ added: [Row], toDay source: String) -> String {
        guard !added.isEmpty else { return source }
        var added = added
        var outline = OutlineMarkdown.parse(source)
        var rows = outline.isBlank ? [] : outline.rows
        var at = 0
        if let first = rows.first, case .heading(1) = first.kind { at = 1 }
        // The blank lines before what was first stay before what is now.
        if at < rows.count {
            added[0].gap = rows[at].gap
            rows[at].gap = []
        }
        rows.insert(contentsOf: added, at: at)
        outline.rows = rows
        return OutlineMarkdown.serialize(outline)
    }

    /// Writes `text` at the top of a day's note. Returns the day's path, or
    /// nil when there were no words to write.
    @discardableResult
    public static func add(_ text: String, in graph: Graph, index: NoteIndex, on day: Day = .today) throws -> String? {
        let rows = rows(text)
        guard !rows.isEmpty else { return nil }
        let path = GraphPaths.dailyPath(for: day)
        try graph.write(prepending(rows, toDay: graph.read(path: path) ?? ""), path: path)
        index.refresh(path)
        return path
    }
}
