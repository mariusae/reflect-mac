import Foundation

/// Rows moved to another note: a row and those under it, taken out of one
/// note and put in another — a day's at its top, after its title, as a
/// note taken in passing is; any other note's at its end.
public enum RowMove {
    /// Rows as they go elsewhere: folded rows opened out, the first at the
    /// outline's top level and the rest as far under it as they were, the
    /// blank lines before the first left behind.
    public static func detached(_ rows: [Row]) -> [Row] {
        var rows = Row.unfold(rows)
        guard let first = rows.first else { return [] }
        let shift = first.depth
        for i in rows.indices {
            rows[i].depth = max(0, rows[i].depth - shift)
            if shift != 0 { rows[i].extraIndent = 0 }
        }
        rows[0].gap = []
        return rows
    }

    /// A note's text with rows added: a day's at its top, any other
    /// note's at its end. A note with nothing in it yet gets them alone.
    public static func adding(_ rows: [Row], to source: String, path: String) -> String {
        let rows = detached(rows)
        guard !rows.isEmpty else { return source }
        if GraphPaths.day(fromDailyPath: path) != nil { return QuickNote.prepending(rows, toDay: source) }
        var outline = OutlineMarkdown.parse(source)
        var all = outline.isBlank ? [] : outline.rows
        // Its own blank line before them, where the note's last row is text.
        var added = rows
        if let last = all.last, !last.text.isEmpty, case .paragraph = last.kind { added[0].gap = [""] }
        all += added
        outline.rows = all
        return OutlineMarkdown.serialize(outline)
    }
}
