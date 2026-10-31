import Foundation

/// What Claude makes of a note, put into it: a summary at its top, the
/// tasks it speaks of at its end — each a row to keep, edit, or undo.
public enum NoteAssistant {
    /// Asks the relay — the app's to set while it may: `summarize`, or `tasks`.
    nonisolated(unsafe) public static var ask: (@Sendable (_ task: String, _ title: String, _ text: String) async throws -> [String])?

    /// A note with its summary at its top, after its title: a Summary row,
    /// the lines under it — one there before replaced.
    public static func withSummary(_ lines: [String], in source: String) -> String? {
        let lines = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        var outline = OutlineMarkdown.parse(source)
        var rows = outline.isBlank ? [] : outline.rows
        let at = rows.first.map { if case .heading(1) = $0.kind { 1 } else { 0 } } ?? 0
        var added = [Row(kind: .bullet, text: summaryHeading)] + lines.map { Row(kind: .bullet, depth: 1, text: $0) }
        // The last summary, gone — the blank lines before it kept: the new one in its place.
        if at < rows.count, rows[at].depth == 0, rows[at].text == summaryHeading {
            added[0].gap = rows[at].gap
            rows.removeSubrange(at..<OutlineEditing.subtreeEnd(rows, at))
        } else if at < rows.count {
            added[0].gap = rows[at].gap
            rows[at].gap = []
        }
        rows.insert(contentsOf: added, at: at)
        outline.rows = rows
        return OutlineMarkdown.serialize(outline)
    }

    /// A note with the tasks found at its end, under Actions — those it
    /// has already, as tasks, left out. Nil, with none new.
    public static func withTasks(_ lines: [String], in source: String) -> String? {
        var outline = OutlineMarkdown.parse(source)
        var rows = outline.isBlank ? [] : outline.rows
        let have = Set(rows.filter { $0.task != nil }.map { InlineMarkup.plainText($0.text).lowercased() })
        let fresh = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !have.contains($0.lowercased()) }
        guard !fresh.isEmpty else { return nil }
        rows.append(Row(kind: .bullet, text: actionsHeading))
        rows += fresh.map { Row(kind: .bullet, depth: 1, text: $0, task: .open, marker: "+") }
        outline.rows = rows
        return OutlineMarkdown.serialize(outline)
    }

    static let summaryHeading = "Summary"
    static let actionsHeading = "Actions"
}
