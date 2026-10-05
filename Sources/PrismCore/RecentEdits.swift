import Foundation
import ReflectCore

/// The rows lately written in — each with the rows it is under — to go
/// back to quickly: the newest first, found again by their words.
public struct RecentEdits: Codable, Sendable, Equatable {
    public struct Edit: Codable, Sendable, Equatable {
        public var path: String
        public var text: String
        /// The rows it is under, the outermost first.
        public var ancestors: [String]
        public var date: Date

        public init(path: String, text: String, ancestors: [String], date: Date) {
            self.path = path
            self.text = text
            self.ancestors = ancestors
            self.date = date
        }
    }

    public private(set) var edits: [Edit] = []
    public static let most = 400

    public init(edits: [Edit] = []) { self.edits = edits }

    /// Each row, unfolded, with the rows it is under.
    public static func rowsWithAncestors(_ source: String) -> [(text: String, ancestors: [String])] {
        var found: [(String, [String])] = []
        var chain: [(depth: Int, text: String)] = []
        for row in Row.unfold(OutlineMarkdown.parse(source).rows) {
            while let last = chain.last, last.depth >= row.depth { chain.removeLast() }
            let text = row.text.trimmingCharacters(in: .whitespaces)
            found.append((text, chain.map(\.text)))
            chain.append((row.depth, text))
        }
        return found
    }

    /// The rows written in between two versions of a note: those whose words
    /// the old one did not have — typed, changed, or new.
    public static func changed(from old: String, to new: String) -> [(text: String, ancestors: [String])] {
        var before: [String: Int] = [:]
        for row in rowsWithAncestors(old) { before[row.text, default: 0] += 1 }
        var found: [(String, [String])] = []
        for row in rowsWithAncestors(new) where !row.text.isEmpty {
            if let count = before[row.text], count > 0 {
                before[row.text] = count - 1
            } else {
                found.append(row)
            }
        }
        return found
    }

    /// A note written: the rows changed in it, newest first, each once.
    public mutating func note(_ path: String, from old: String, to new: String, at date: Date = Date()) {
        let changed = Self.changed(from: old, to: new)
        guard !changed.isEmpty else { return }
        let fresh = changed.map { Edit(path: path, text: $0.text, ancestors: $0.ancestors, date: date) }
        // A row typed in again and again is one edit: its latest words. One
        // whose words grew from an earlier edit's replaces it.
        edits.removeAll { edit in
            edit.path == path && fresh.contains { $0.text == edit.text || $0.text.hasPrefix(edit.text) && $0.ancestors == edit.ancestors }
        }
        edits.insert(contentsOf: fresh, at: 0)
        if edits.count > Self.most { edits.removeLast(edits.count - Self.most) }
    }

    /// Those whose words, their parents', or their note's name — `title` —
    /// have every word asked for.
    public func matching(_ query: String, title: (String) -> String = { _ in "" }) -> [Edit] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return edits }
        return edits.filter { edit in
            let haystack = ([title(edit.path)] + edit.ancestors + [edit.text]).joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// Where an edit's row is now, among the note's rows unfolded: the one
    /// with its words under the same rows, else any with its words.
    public static func locate(_ edit: Edit, in source: String) -> Int? {
        let rows = rowsWithAncestors(source)
        return rows.firstIndex { $0.text == edit.text && $0.ancestors == edit.ancestors }
            ?? rows.firstIndex { $0.text == edit.text }
            ?? rows.firstIndex { $0.text.hasPrefix(edit.text) || edit.text.hasPrefix($0.text) && !$0.text.isEmpty }
    }
}
