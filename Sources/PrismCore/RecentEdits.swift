import Foundation
import GraphKit
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
        edits.removeAll { edit in fresh.contains { Self.sameRow($0, edit) } }
        edits.insert(contentsOf: fresh, at: 0)
        if edits.count > Self.most { edits.removeLast(edits.count - Self.most) }
    }

    /// Whether two edits are of one row, written on: in the same note, and
    /// the same words — or one's grown from, or cut back to, the other's,
    /// under the same rows; or mostly the same at their start.
    public static func sameRow(_ a: Edit, _ b: Edit) -> Bool {
        guard a.path == b.path else { return false }
        if a.text == b.text { return true }
        guard a.ancestors == b.ancestors else { return false }
        if a.text.hasPrefix(b.text) || b.text.hasPrefix(a.text) { return true }
        let shared = zip(a.text, b.text).prefix { $0 == $1 }.count
        return shared >= max(16, min(a.text.count, b.text.count) / 2)
    }

    /// Each row once: its latest words — as written by an older Prism,
    /// which kept a row's every few words.
    public var distinct: [Edit] {
        var kept: [Edit] = []
        for edit in edits where !kept.contains(where: { Self.sameRow($0, edit) }) { kept.append(edit) }
        return kept
    }

    /// Those whose words, their parents', or their note's name — `title` —
    /// have every word asked for: each row once.
    public func matching(_ query: String, title: (String) -> String = { _ in "" }) -> [Edit] {
        let words = PageIndex.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return distinct }
        return distinct.filter { edit in
            let haystack = PageIndex.fold(([title(edit.path)] + edit.ancestors + [edit.text]).joined(separator: " "))
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
