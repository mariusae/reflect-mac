import Foundation

/// When a note's title changes, what else changes with it — as Reflect's
/// rename pipeline does it (`packages/core/src/indexing/rename.ts`):
///
/// - every `[[Old Title]]` that led here becomes `[[New Title]]`, and a
///   `[[target|Old Title]]` whose shown text mirrored the old title shows the
///   new one — unless the old title now belongs to another note (a
///   *collision*: those links are that note's now), or the new title already
///   belongs to another (the *destination is blocked*: only the shown text
///   changes, and the old title's alias keeps the links resolving);
/// - the old title joins the note's aliases, so links it could not rewrite —
///   and links from outside — still find it; a chain of renames prunes the
///   aliases the previous one added, never one written by hand;
/// - a note Reflect manages — directly in `notes/`, with a ULID `id` — moves
///   to the file its new title names.
public enum TitleRename {
    /// What a title is linked by: the title, its `//` segments aside.
    static func key(_ title: String) -> String { Backlinks.key(title) }

    // MARK: Rewriting links

    /// A source's text with the links to a renamed note retitled.
    ///
    /// - `repoint`: links whose target is `fromKey` point at `to` instead.
    /// - `display`: a pipe display equal to `from` on a link that leads to
    ///   the note — its target's key in `subjectKeys` — shows `to`.
    public static func retitleLinks(in source: String, repoint: (fromKey: String, to: String)?,
                                    display: (from: String, to: String)?, subjectKeys: Set<String>) -> String {
        guard source.contains("[[") else { return source }
        let text = source as NSString
        var edits: [(range: NSRange, text: String)] = []
        var fence: String?
        var lineStart = 0
        while lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = text.substring(with: lineRange)
            defer { lineStart = NSMaxRange(lineRange) }
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                continue
            }
            guard line.contains("[[") else { continue }
            for span in InlineMarkup.spans(in: text, range: lineRange) {
                guard case .wikiLink = span.kind else { continue }
                let inner = text.substring(with: NSRange(location: span.range.location + 2, length: span.range.length - 4))
                let pipe = inner.firstIndex(of: "|")
                let target = pipe.map { String(inner[..<$0]) } ?? inner
                let shown = pipe.map { String(inner[inner.index(after: $0)...]) }
                let targetKey = key(target)
                let nextTarget = repoint.flatMap { targetKey == $0.fromKey ? $0.to : nil } ?? target
                var nextShown = shown
                if let display, let shown, subjectKeys.contains(targetKey) || targetKey == repoint?.fromKey,
                   shown == display.from {
                    nextShown = display.to
                }
                guard nextTarget != target || nextShown != shown else { continue }
                edits.append((span.range, "[[" + nextTarget + (nextShown.map { "|" + $0 } ?? "") + "]]"))
            }
        }
        guard !edits.isEmpty else { return source }
        let result = NSMutableString(string: source)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: edit.range, with: edit.text)
        }
        return result as String
    }

    // MARK: The old title, kept

    /// A title's `//` segments, then the whole title.
    static func aliasFamily(_ title: String) -> [String] {
        let parts = title.components(separatedBy: "//").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (parts.count > 1 ? parts : []) + [title]
    }

    /// The note's aliases after a rename, or nil when they stay as they are:
    /// the previous rename's own aliases pruned, and the old title added —
    /// with its `//` segments — less what the new title answers to anyway.
    public static func nextAliases(_ current: [String], from: String, to: String, previousAutoAliases: [String]) -> [String]? {
        let pruned = Set(previousAutoAliases)
        var next = current.filter { !pruned.contains($0) }
        var kept = Set(next.map(NoteIndex.foldKey))
        let derivable = Set(aliasFamily(to).map(NoteIndex.foldKey))
        for alias in aliasFamily(from) {
            let key = NoteIndex.foldKey(alias)
            guard !derivable.contains(key), !kept.contains(key) else { continue }
            kept.insert(key)
            next.append(alias)
        }
        return next == current ? nil : next
    }

    /// A note's aliases, as its frontmatter lists them.
    public static func aliases(in source: String) -> [String] {
        CommitMessage.splitFrontmatter(source).raw.map { Frontmatter(raw: $0).list("aliases") } ?? []
    }

    /// What a rename added, of the aliases now.
    public static func added(_ before: [String], _ after: [String]) -> [String] {
        let had = Set(before)
        return after.filter { !had.contains($0) }
    }

    // MARK: Which notes move

    /// Whether a note's file is named by its title: directly in `notes/`,
    /// its frontmatter `id` a ULID.
    public static func isManaged(path: String, source: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count == 2, parts[0].lowercased() == GraphPaths.notesDirectory, path.hasSuffix(".md") else { return false }
        let (raw, _) = CommitMessage.splitFrontmatter(source)
        guard let id = raw.flatMap({ Frontmatter(raw: $0).scalar("id") }) else { return false }
        return id.range(of: #"^[0-7][0-9a-hjkmnp-tv-z]{25}$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The title a note's text gives it — its frontmatter `title:`, else its
    /// first top-level heading — or nil when it gives none.
    public static func authoredTitle(path: String, source: String) -> String? {
        let entry = NoteIndex.entry(path: path, source: source)
        let (raw, _) = CommitMessage.splitFrontmatter(source)
        let declared = raw.flatMap { Frontmatter(raw: $0).scalar("title") }?.trimmingCharacters(in: .whitespaces)
        if let declared, !declared.isEmpty { return declared }
        return entry.titleIsHeading ? entry.title : nil
    }
}

extension Frontmatter {
    /// A note's text with a frontmatter key set to a list — written as
    /// Reflect's YAML writer does, `key:` then `  - item` lines — or taken
    /// out, for an empty one.
    public static func setting(_ key: String, toList items: [String], in source: String) -> String {
        guard !items.isEmpty else { return setting(key, to: nil, in: source) }
        let value = "\n" + items.map { "  - " + yamlScalar($0) }.joined(separator: "\n")
        // `setting` writes `key: value`; the list starts on the next line.
        return setting(key, to: "\u{0}", in: source).replacingOccurrences(of: "\(key): \u{0}", with: "\(key):" + value)
    }

    /// A string as a YAML scalar: plain when that reads back the same,
    /// else double-quoted.
    static func yamlScalar(_ value: String) -> String {
        let special = "-?:,[]{}#&*!|>'\"%@`"
        let plain = !value.isEmpty
            && value.trimmingCharacters(in: .whitespaces) == value
            && !special.contains(value.first!)
            && !value.contains(": ") && !value.contains(" #") && !value.hasSuffix(":")
            && !["true", "false", "yes", "no", "on", "off", "null", "~"].contains(value.lowercased())
            && Double(value) == nil
            && !value.contains("\n")
        if plain { return value }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"" + escaped + "\""
    }
}

extension NoteIndex {
    /// What a rename of a note did to the links that lead to it.
    public struct RetitleResult: Sendable {
        public var rewritten: [String] = []
        public var failed: [String] = []
        /// The old title is another note's now: its links were left alone,
        /// and it must not become this note's alias.
        public var collision = false
        /// The new title is another note's: no link was repointed.
        public var destinationBlocked = false
    }

    /// Rewrites the links to a note renamed `from` → `to`, across the notes
    /// that link to it. `read` and `write` are the graph's.
    public func retitleLinks(to path: String, from: String, to title: String,
                             read: (String) -> String?, write: (String, String) throws -> Void) -> RetitleResult {
        var result = RetitleResult()
        let fromKey = TitleRename.key(from)
        let owner = resolve(from)
        result.collision = owner != nil && owner != path
        if !result.collision {
            let destination = resolve(title)
            result.destinationBlocked = title.contains("[") || title.contains("]") || title.contains("|")
                || (destination != nil && destination != path)
        }
        // The names the note answers to: the links through any of them are
        // its, and a pipe display mirroring the old title changes on them too.
        var subjectKeys = Set<String>()
        if let entry = entry(path) {
            subjectKeys.insert(NoteIndex.foldKey(entry.title))
            for alias in entry.aliases { subjectKeys.insert(NoteIndex.foldKey(alias)) }
        }
        if !result.collision { subjectKeys.insert(fromKey) }
        let sources = linkingPaths(to: subjectKeys).filter { $0 != path && !$0.hasPrefix("templates/") }.sorted()
        let repoint = result.collision || result.destinationBlocked ? nil : (fromKey: fromKey, to: title)
        let display = (from: from, to: title)
        for source in sources {
            guard let text = read(source) else {
                result.failed.append(source)
                continue
            }
            let next = TitleRename.retitleLinks(in: text, repoint: repoint, display: display, subjectKeys: subjectKeys)
            guard next != text else { continue }
            do {
                try write(next, source)
                refresh(source)
                result.rewritten.append(source)
            } catch {
                result.failed.append(source)
            }
        }
        return result
    }

    /// Where a managed note titled so would live: its slug, or the first
    /// free `-2`, `-3`… — its own path always counting as free.
    public func managedPath(for title: String, current: String) -> String {
        let slug = Assets.slug(title)
        for attempt in 1...1000 {
            let path = "\(GraphPaths.notesDirectory)/" + (attempt == 1 ? slug : "\(slug)-\(attempt)") + ".md"
            if path.lowercased() == current.lowercased() { return current }
            if entry(path) == nil && !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
                return path
            }
        }
        return current
    }
}
