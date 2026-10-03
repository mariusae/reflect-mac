import Foundation
import ReflectCore

/// A piece of a note shown away from it — a task, or the row a link is in
/// — editable there: its row and the rows under it, as focusing on it shows
/// them, and where they are in the note, to write them back to.
public struct NoteSlice: Sendable {
    public var path: String
    /// The task it is, in the tasks column.
    public var task: NoteTask?
    /// The rows it is under, outermost first, as they read.
    public var crumbs: [String] = []
    /// The first of its rows among the note's, and how many it has there.
    public var start: Int
    public var count: Int
    /// How deep the task is in its note: its rows are shown from the left.
    public var depth: Int
    public var rows: [Row]

    public init(path: String, task: NoteTask? = nil, crumbs: [String] = [], start: Int, count: Int, depth: Int, rows: [Row]) {
        self.path = path
        self.task = task
        self.crumbs = crumbs
        self.start = start
        self.count = count
        self.depth = depth
        self.rows = rows
    }

    /// The tasks of a note, each with what is under it, from its text.
    public static func slices(of tasks: [NoteTask], in source: String) -> [NoteSlice] {
        let rows = OutlineMarkdown.parse(source).rows
        var starts: [Int] = []
        for (i, row) in rows.enumerated() where Tasks.isTask(row) { starts.append(i) }
        return tasks.compactMap { task in
            guard starts.indices.contains(task.ordinal) else { return nil }
            let start = starts[task.ordinal]
            let block = OutlineEditing.block(rows, start..<(start + 1))
            let depth = rows[start].depth
            let shown = rows[block].map { row -> Row in
                var row = row
                row.depth -= depth
                return row
            }
            return NoteSlice(path: task.notePath, task: task, start: block.lowerBound, count: block.count, depth: depth, rows: shown)
        }
    }

    /// The rows of a note holding any of some links, each with what is
    /// under it: one slice for rows one inside another.
    public static func slices(holding links: [String], path: String, in source: String) -> [NoteSlice] {
        let links = Set(links.filter { !$0.isEmpty })
        return slices(path: path, in: source) { text in links.contains(where: text.contains) }
    }

    /// The rows of a note with any of some words in them — regardless of
    /// case and accents — each with what is under it.
    public static func slices(finding words: [String], path: String, in source: String) -> [NoteSlice] {
        slices(path: path, in: source) { text in
            words.contains { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// The rows of a note whose text says so, each with what is under it.
    public static func slices(path: String, in source: String, where wanted: (String) -> Bool) -> [NoteSlice] {
        let rows = OutlineMarkdown.parse(source).rows
        var slices: [NoteSlice] = []
        var covered = 0..<0
        var ancestors: [(depth: Int, text: String)] = []
        for (i, row) in rows.enumerated() {
            while let last = ancestors.last, last.depth >= row.depth { ancestors.removeLast() }
            defer { if row.kind.isListItem { ancestors.append((row.depth, InlineMarkup.plainText(row.text))) } }
            guard !covered.contains(i), wanted(row.text) else { continue }
            // A heading alone, not the section under it; and a note's title
            // heading not at all — its name says it already.
            var block = OutlineEditing.block(rows, i..<(i + 1))
            if case .heading(let level) = row.kind {
                if level == 1, rows[..<i].allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
                block = i..<(i + 1)
            }
            covered = block
            let depth = row.depth
            let shown = rows[block].map { row -> Row in
                var row = row
                row.depth -= depth
                return row
            }
            slices.append(NoteSlice(path: path, crumbs: ancestors.map(\.text).filter { !$0.isEmpty },
                                    start: block.lowerBound, count: block.count, depth: depth, rows: shown))
        }
        return slices
    }
}


extension NoteSlice {
    /// A note's text with this slice's rows put back in its place, as edited.
    public func writing(_ edited: [Row], into source: String) -> String? {
        var outline = OutlineMarkdown.parse(source)
        let range = start..<(start + count)
        guard range.upperBound <= outline.rows.count else { return nil }
        outline.rows.replaceSubrange(range, with: edited)
        return OutlineMarkdown.serialize(outline)
    }
}
