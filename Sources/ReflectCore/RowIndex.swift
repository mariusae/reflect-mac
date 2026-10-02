import Foundation

/// The rows of every note, for finding one by what it says and where it is
/// — its note's title the top of its path — as Go to Row does across the
/// graph. Built from the note index's texts, a note at a time, and a note
/// again only once it has changed: what a search reads is already in
/// memory. Safe to use from any thread; search off the main one.
public final class RowIndex: @unchecked Sendable {
    public struct Found: Sendable {
        public var path: String
        public var noteTitle: String
        public var entry: OutlineFind.Entry
    }

    private let index: NoteIndex
    private let lock = NSLock()
    /// A row, and its words and path folded once, for searching.
    private struct Keyed {
        var entry: OutlineFind.Entry
        var own: String
        var trail: [String]
    }

    private var notes: [String: (modified: Date, title: String, rows: [Keyed])] = [:]

    public init(index: NoteIndex) {
        self.index = index
    }

    /// Takes in the notes as they are: those new or changed parsed, those
    /// gone forgotten.
    public func update() {
        let all = index.all.filter { !$0.path.hasPrefix("templates/") }
        let known = lock.withLock { notes.mapValues(\.modified) }
        var fresh: [String: (modified: Date, title: String, rows: [Keyed])] = [:]
        for entry in all where known[entry.path] != entry.modified || known[entry.path] == nil {
            guard let body = index.body(entry.path) else { continue }
            let title = entry.day.map(\.description) ?? entry.title
            // A note's title heading is the note: once in a path is enough.
            // Not a note's title heading: that is the note, which Open finds.
            let rows = OutlineFind.entries(OutlineMarkdown.parse(body).rows)
                .filter { !$0.text.isEmpty && !($0.index == 0 && $0.ancestors.isEmpty && $0.text == title) }.map { row in
                Keyed(entry: row, own: NoteIndex.foldKey(row.text),
                      trail: ([title] + row.path.filter { $0 != title }).map(NoteIndex.foldKey))
            }
            fresh[entry.path] = (entry.modified, title, rows)
        }
        let present = Set(all.map(\.path))
        lock.withLock {
            notes = notes.filter { present.contains($0.key) }
            notes.merge(fresh) { $1 }
        }
    }

    /// The rows a query finds across the notes, best first — a note's own
    /// title, as the top of each of its rows' paths, matched with them.
    public func find(_ query: String, excluding: String? = nil, limit: Int = 60) -> [Found] {
        let words = NoteIndex.foldKey(query).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let snapshot = lock.withLock { notes }
        var scored: [(found: Found, score: Int)] = []
        for (notePath, note) in snapshot where notePath != excluding {
            for row in note.rows {
                guard let score = OutlineFind.score(depth: row.entry.ancestors.count, words: words, own: row.own, path: row.trail)
                else { continue }
                scored.append((Found(path: notePath, noteTitle: note.title, entry: row.entry), score))
            }
        }
        return scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.found.noteTitle != b.found.noteTitle { return a.found.noteTitle < b.found.noteTitle }
            return a.found.entry.index < b.found.entry.index
        }.prefix(limit).map(\.found)
    }
}
