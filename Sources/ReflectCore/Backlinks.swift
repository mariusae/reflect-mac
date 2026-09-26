import Foundation

/// The notes that link to a note, and around each link the block of the
/// note it sits in — found as Reflect finds them.
///
/// A backlink is a `[[link]]` that resolves to the note: by its day, its
/// title, or one of its aliases; templates link to nothing. Sources are
/// listed newest first — a daily note by its day, any other by when it was
/// last written — and each link's context is Reflect's (old Reflect's
/// `getBacklinkContextHtml`, as the open app ports it):
///
/// - a heading: the heading and what follows it, to the next heading — but
///   the note's own title heading alone;
/// - a top-level list item: the item and everything under it;
/// - a nested list item: its parent's own line, and each branch under that
///   parent that also links to the note, or holds this link;
/// - anything else: its own block.
///
/// Two links in a source with the same context are one.
public struct BacklinkSource: Sendable, Equatable {
    public var path: String
    /// The contexts, in the order their links come in the source.
    public var contexts: [BacklinkContext]
}

public struct BacklinkContext: Sendable, Equatable {
    /// The rows of the context, their depths from zero.
    public var rows: [Row]
    /// How the link was written, `[[…]]` and all, to find it again.
    public var link: String
}

public enum Backlinks {
    /// What a link's target is matched by: its day, or its name folded.
    static func key(_ target: String) -> String {
        let raw = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if let day = Day(raw) { return "day:\(day)" }
        return NoteIndex.foldKey(raw)
    }

    /// The keys of the `[[links]]` in a note's text, outside code.
    static func linkKeys(in source: String) -> Set<String> {
        guard source.contains("[[") else { return [] }
        let (_, body) = CommitMessage.splitFrontmatter(source)
        var keys = Set<String>()
        var fence: Substring?
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = trimmed.prefix(3)
                continue
            }
            guard line.contains("[[") else { continue }
            let text = String(line) as NSString
            for span in InlineMarkup.spans(in: text, range: NSRange(location: 0, length: text.length)) {
                if case .wikiLink(let target) = span.kind { keys.insert(key(target)) }
            }
        }
        return keys
    }

    /// Whether a note says nothing but its title: a topic, then, shown as
    /// what links to it.
    public static func isEmpty(_ rows: [Row]) -> Bool {
        rows.enumerated().allSatisfy { index, row in
            if index == 0, case .heading(1) = row.kind { return true }
            return row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The contexts of the links in a note's rows that `mentions` says lead
    /// to the note.
    public static func contexts(in outline: Outline, mentions: (String) -> Bool) -> [BacklinkContext] {
        let rows = outline.rows
        let titled = outline.frontmatter.map { Frontmatter(raw: $0).scalar("title")?.trimmingCharacters(in: .whitespaces).isEmpty == false } ?? false
        // The note's title heading: its first top-level H1 with text, unless
        // its frontmatter names it.
        let title = titled ? nil : rows.firstIndex { $0.kind == .heading(1) && $0.depth == 0 && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }

        func links(_ row: Row) -> [String] {
            guard row.kind != .code, row.text.contains("[[") else { return [] }
            let text = row.text as NSString
            return InlineMarkup.spans(in: text, range: NSRange(location: 0, length: text.length)).compactMap { span in
                guard case .wikiLink(let target) = span.kind, mentions(target) else { return nil }
                return text.substring(with: span.range)
            }
        }
        /// The end of a row's subtree: the first row after it no deeper.
        func end(of index: Int) -> Int {
            var next = index + 1
            while next < rows.count, rows[next].depth > rows[index].depth { next += 1 }
            return next
        }
        /// The row a row sits under, if any.
        func parent(of index: Int) -> Int? {
            guard rows[index].depth > 0 else { return nil }
            var at = index - 1
            while at >= 0 {
                if rows[at].depth < rows[index].depth { return rows[at].depth == rows[index].depth - 1 ? at : nil }
                at -= 1
            }
            return nil
        }
        /// Whether a branch links to the note in its own text: its row, and the
        /// paragraphs set straight under it — not deeper down.
        func branchMentions(_ index: Int) -> Bool {
            if !links(rows[index]).isEmpty { return true }
            var child = index + 1
            while child < rows.count, rows[child].depth > rows[index].depth {
                if rows[child].depth == rows[index].depth + 1, rows[child].kind == .paragraph, !links(rows[child]).isEmpty { return true }
                child += 1
            }
            return false
        }

        func context(of index: Int) -> [Row] {
            let row = rows[index]
            if case .heading = row.kind {
                if index == title { return [row] }
                var next = index + 1
                while next < rows.count {
                    if case .heading = rows[next].kind, rows[next].depth <= row.depth { break }
                    next += 1
                }
                return Array(rows[index..<next])
            }
            // The list item the link is in: its row, or the item a paragraph
            // is set in.
            var item: Int?
            if row.kind.isListItem {
                item = index
            } else if let up = parent(of: index), rows[up].kind.isListItem {
                item = up
            }
            guard let item else {
                // A quote is all its lines, as the one block it is.
                guard row.kind == .quote else { return [row] }
                var first = index, last = index
                while first > 0, rows[first - 1].kind == .quote, rows[first - 1].depth == row.depth, rows[first].gap.isEmpty { first -= 1 }
                while last + 1 < rows.count, rows[last + 1].kind == .quote, rows[last + 1].depth == row.depth, rows[last + 1].gap.isEmpty { last += 1 }
                return Array(rows[first...last])
            }
            guard let above = parent(of: item), rows[above].kind.isListItem else {
                return Array(rows[item..<end(of: item)])
            }
            // A nested item: the parent's own line, and its branches that link here.
            var picked = [rows[above]]
            var branch = above + 1
            while branch < rows.count, rows[branch].depth > rows[above].depth {
                let after = end(of: branch)
                if branchMentions(branch) || (branch...max(branch, after - 1)).contains(index) {
                    picked.append(contentsOf: rows[branch..<after])
                }
                branch = after
            }
            return picked
        }

        var found: [BacklinkContext] = []
        var seen = Set<String>()
        for index in rows.indices {
            guard let link = links(rows[index]).first else { continue }
            var context = context(of: index)
            let base = context.map(\.depth).min() ?? 0
            for at in context.indices {
                context[at].depth -= base
                context[at].gap = []
                context[at].folded = []
            }
            guard seen.insert(OutlineMarkdown.serialize(Outline(rows: context))).inserted else { continue }
            found.append(BacklinkContext(rows: context, link: link))
        }
        return found
    }
}

extension NoteIndex {
    /// The notes linking to a note, newest first, with the context of each
    /// link. Reads each source; call it off the main thread.
    public func backlinks(to path: String) -> [BacklinkSource] {
        let notes = all
        guard let target = notes.first(where: { $0.path == path }) ?? entry(path)
                ?? GraphPaths.day(fromDailyPath: path).map({ NoteEntry(path: path, title: $0.description, aliases: [], day: $0,
                                                                        modified: .distantPast, isPrivate: false, titleIsHeading: false) })
        else { return [] }
        // Every name the note answers to, and — as a link resolves by day,
        // then title, then alias — only those no other note answers to first.
        let sorted = notes.sorted { $0.path < $1.path }
        var titles: [String: String] = [:]
        var aliases: [String: String] = [:]
        for note in sorted {
            if titles[NoteIndex.foldKey(note.title)] == nil { titles[NoteIndex.foldKey(note.title)] = note.path }
            for alias in note.aliases where aliases[NoteIndex.foldKey(alias)] == nil { aliases[NoteIndex.foldKey(alias)] = note.path }
        }
        func resolves(_ target: String) -> Bool {
            let key = Backlinks.key(target)
            if key.hasPrefix("day:") { return key == "day:" + (GraphPaths.day(fromDailyPath: path)?.description ?? "") }
            return (titles[key] ?? aliases[key]) == path
        }
        var keys = Set<String>()
        if let day = target.day { keys.insert("day:\(day)") }
        keys.insert(NoteIndex.foldKey(target.title))
        for alias in target.aliases { keys.insert(NoteIndex.foldKey(alias)) }
        keys = keys.filter { key in key.hasPrefix("day:") || (titles[key] ?? aliases[key]) == path }

        let sources = linkingPaths(to: keys).filter { !$0.hasPrefix("templates/") }
        func recency(_ source: String) -> Date {
            if let day = GraphPaths.day(fromDailyPath: source), let date = day.date { return date }
            return entry(source)?.modified ?? .distantPast
        }
        return sources.map { ($0, recency($0)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .compactMap { source, _ in
                guard let text = body(source) else { return nil }
                let contexts = Backlinks.contexts(in: OutlineMarkdown.parse(text), mentions: resolves)
                return contexts.isEmpty ? nil : BacklinkSource(path: source, contexts: contexts)
            }
    }
}
