import Foundation

/// The rows of an outline, each with where it is — the rows it is in — for
/// finding one by what it says and where: `proj alph` finds Alpha, in
/// Projects. What Go to Row (⌘J) searches.
public enum OutlineFind {
    public struct Entry: Sendable, Equatable {
        /// Its place among the outline's rows, folded ones unfolded.
        public var index: Int
        /// Its words, its Markdown taken out.
        public var text: String
        /// The rows it is in, outermost first: their places, and their words.
        public var ancestors: [Int]
        public var path: [String]
        /// How many rows are in it.
        public var children: Int
        public var row: Row
    }

    /// Every row of an outline — folded rows too, unfolded — with its path.
    /// A row is in another when it is in that one's block: a list item's
    /// children, and what is under a heading, to the next.
    public static func entries(_ rows: [Row]) -> [Entry] {
        let all = Row.unfold(rows)
        var entries: [Entry] = []
        var open: [(index: Int, end: Int)] = []
        for (index, row) in all.enumerated() {
            while let last = open.last, last.end <= index { open.removeLast() }
            let block = OutlineEditing.block(all, index..<(index + 1))
            let ancestors = open.map(\.index)
            entries.append(Entry(index: index, text: InlineMarkup.plainText(row.text).replacingOccurrences(of: "\n", with: " "),
                                 ancestors: ancestors, path: ancestors.map { InlineMarkup.plainText(all[$0].text) },
                                 children: block.count - 1, row: row))
            if block.count > 1 { open.append((index, block.upperBound)) }
        }
        return entries
    }

    /// The rows a query finds, best first — among all, or only those in a
    /// row, when one is given. Each word of the query is found in the row's
    /// words or its path's, at least one in its own; its own count most, the
    /// starts of words more, and shallower rows before deeper ones. With no
    /// query: the rows straight under the row given, or the outline's top.
    public static func find(_ query: String, in entries: [Entry], within scope: Int? = nil, limit: Int = 200) -> [Entry] {
        let candidates = entries.filter { entry in
            guard let scope else { return true }
            return entry.ancestors.contains(scope)
        }
        let words = NoteIndex.foldKey(query).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else {
            let depth = scope.flatMap { scope in entries.first { $0.index == scope } }.map { $0.ancestors.count + 1 } ?? 0
            let level = candidates.filter { $0.ancestors.count == depth && !$0.text.isEmpty }
            // A note whose title holds all of it: what is under the title.
            if scope == nil, level.count == 1, let only = level.first, only.children > 0 {
                return find("", in: entries, within: only.index, limit: limit)
            }
            return Array(level.prefix(limit))
        }
        var scored: [(entry: Entry, score: Int)] = []
        for entry in candidates {
            if let score = score(entry, words: words, path: entry.path) { scored.append((entry, score)) }
        }
        return scored.sorted { a, b in
            a.score != b.score ? a.score > b.score : a.entry.index < b.entry.index
        }.prefix(limit).map(\.entry)
    }

    /// How well a row matches a query's words, given the path it is
    /// matched with; nil when it does not. Each word must be in its words
    /// or its path's, one at least in its own.
    static func score(_ entry: Entry, words: [String], path: [String]) -> Int? {
        guard !entry.text.isEmpty else { return nil }
        return score(depth: entry.ancestors.count, words: words, own: NoteIndex.foldKey(entry.text), path: path.map(NoteIndex.foldKey))
    }

    /// The same, from a row's words and path already folded — as an index
    /// keeps them, so a search folds nothing but the query.
    static func score(depth: Int, words: [String], own: String, path: [String]) -> Int? {
        guard !own.isEmpty else { return nil }
        var score = 0
        var ownHits = 0
        for word in words {
            if let range = own.range(of: word) {
                ownHits += 1
                score += 10 + (isWordStart(range.lowerBound, in: own) ? 6 : 0) + (range.lowerBound == own.startIndex ? 4 : 0)
            } else if let level = path.lastIndex(where: { $0.contains(word) }) {
                // A nearer row it is in counts more than a far one.
                score += 3 + level
            } else {
                return nil
            }
        }
        guard ownHits > 0 else { return nil }
        score -= depth
        if own == words.joined(separator: " ") { score += 20 }
        return score
    }

    private static func isWordStart(_ index: String.Index, in text: String) -> Bool {
        index == text.startIndex || !(text[text.index(before: index)].isLetter || text[text.index(before: index)].isNumber)
    }
}
