import Foundation
import ReflectCore

/// Every page of a graph — its days, weeks and notes — in memory, with
/// the names each answers to, what links to what, and what is tagged with
/// what: the index both apps look at the graph through. Names, aliases,
/// inline tags and flags are read as Prism reads them (`NoteIndex.entry`).
public final class PageIndex: @unchecked Sendable {
    public let root: URL

    /// A page, the file it is kept in, that file's text as last read or
    /// written, and what Prism reads in it: its aliases, its inline tags,
    /// its flags.
    public struct Entry {
        public var path: String
        public var page: Page
        public var source: String
        public var note: NoteEntry
        /// When it was last written: its `modified`, else when the graph's
        /// history last changed it, else its file's time.
        public var modified: Date
        /// Its file's time, as last read.
        public var written: Date

        public var kind: PageFolder.Kind { PageFolder.kind(of: path) }
        /// Every name the page answers to: its title and its aliases.
        public var names: [String] { [page.title] + note.aliases }
        /// Its frontmatter's tags and the `#tags` in its body, each once.
        public var tags: [String] {
            var seen = Set<String>()
            return (page.tags + note.tags).filter { seen.insert($0.lowercased()).inserted }
        }
    }

    public private(set) var entries: [String: Entry] = [:]
    /// The title each name leads to, by its fold key: a title before an
    /// alias, the first by path of each — as Prism resolves links.
    private var names: [String: String] = [:]
    /// The names each page links to, and the pages linking to each name, by
    /// its fold key.
    private var outgoing: [String: Set<String>] = [:]
    /// The title of the page in each file.
    private var titlesByPath: [String: String] = [:]
    private var incoming: [String: Set<String>] = [:]

    /// Whether private notes are read too: Prism lists them, saying only
    /// that they are private; Weft, as Reflect, never shows them.
    public let includesPrivate: Bool

    public init(root: URL, includingPrivate: Bool = false) {
        self.root = root.standardizedFileURL
        includesPrivate = includingPrivate
    }

    public var titles: [String] { entries.keys.sorted() }

    public subscript(title: String) -> Page? { entries[title]?.page }

    /// The page kept in a graph-relative file, as Prism finds notes.
    public func entry(atPath path: String) -> Entry? { titlesByPath[path].flatMap { entries[$0] } }

    /// When each page last changed by the graph's history — its last
    /// commit's — for those whose frontmatter does not say, and whose file
    /// has not changed since: as Prism dates notes in a fresh clone, whose
    /// files' times are all the clone's.
    public func useHistory(_ times: [String: Date], uncommitted: Set<String>) {
        for (title, entry) in entries where entry.page.modified == nil {
            let committed = uncommitted.contains(entry.path) ? nil : times[entry.path]
            entries[title]?.modified = committed ?? entry.written
        }
    }

    /// Reads every page. A title two files claim goes to the first by path;
    /// a private note is left out, as Reflect never shows one. Safe to call
    /// off the main thread, on an index nothing else is using yet.
    public func load() throws {
        entries = [:]
        outgoing = [:]
        incoming = [:]
        titlesByPath = [:]
        // Read one by one: side by side, the notes' parsing contends and
        // takes twice as long.
        for path in Self.pagePaths(in: root) {
            guard let entry = Self.read(path, in: root), includesPrivate || !entry.note.isPrivate, entries[entry.page.title] == nil else { continue }
            entries[entry.page.title] = entry
            index(entry)
        }
        indexNames()
    }

    /// Every page file under the graph, sorted by path.
    static func pagePaths(in root: URL) -> [String] {
        var paths: [String] = []
        for directory in PageFolder.directories {
            // Paths under the folder, as the walk gives them: whatever links
            // lead to the graph, they stay its own.
            guard let walker = FileManager.default.enumerator(atPath: root.appendingPathComponent(directory).path) else { continue }
            for case let name as String in walker where name.hasSuffix(".md") && !name.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                let relative = directory + "/" + name
                if PageFolder.isPage(relative) { paths.append(relative) }
            }
        }
        return paths.sorted()
    }

    private static func read(_ path: String, in root: URL) -> Entry? {
        let url = root.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return entry(path: path, source: String(decoding: data, as: UTF8.self), written: written)
    }

    private static func entry(path: String, source: String, written: Date) -> Entry {
        let page = PageFile.read(source, fallbackTitle: PageFolder.fallbackTitle(for: path), fixedTitle: PageFolder.titleIsFixed(path))
        return Entry(path: path, page: page, source: source, note: NoteIndex.entry(path: path, source: source),
                     modified: page.modified ?? written, written: written)
    }

    /// Writes a page to its file — a new one to a new file, in the folder
    /// its title calls for, titled by a heading if a note — changing only
    /// what changed in it.
    @discardableResult
    public func save(_ page: Page, replacing oldTitle: String? = nil, movingFile: Bool = false) throws -> Entry {
        let previous = entries[oldTitle ?? page.title]
        // Renamed, a page keeps its file — unless asked to take a file
        // named for its new title, as one just made, still named for the
        // title it was made with, is.
        let moving = movingFile && previous != nil && previous?.page.title != page.title
        let path: String
        if let previous, !moving {
            path = previous.path
        } else {
            let taken = Set(entries.values.map(\.path)).subtracting(previous.map { [$0.path] } ?? [])
            path = PageFolder.path(for: page.title, in: root, taken: taken, ignoring: previous?.path)
        }
        let source = PageFile.write(page, over: previous?.source, fallbackTitle: PageFolder.fallbackTitle(for: path),
                                    headingTitle: PageFolder.titlesByHeading(path), fixedTitle: PageFolder.titleIsFixed(path))
        if source != previous?.source || path != previous?.path {
            try PageFolder.prepare(path, in: root)
            try Data(source.utf8).write(to: root.appendingPathComponent(path), options: .atomic)
            if moving, let old = previous?.path, old != path {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(old))
            }
        }
        if let previous {
            unindex(previous)
            entries[previous.page.title] = nil
        }
        // Read back as it will be read: its title, aliases and tags as written.
        var entry = Self.entry(path: path, source: source, written: Date())
        entry.page = page
        entries[page.title] = entry
        index(entry)
        indexNames()
        return entry
    }

    /// Reads one page's file again — after another app or a sync wrote
    /// it — or forgets it, when the file is gone.
    public func reload(path: String) {
        if let previous = entry(atPath: path) {
            unindex(previous)
            entries[previous.page.title] = nil
        }
        if let entry = Self.read(path, in: root), includesPrivate || !entry.note.isPrivate {
            entries[entry.page.title] = entry
            index(entry)
        }
        indexNames()
    }

    /// Takes a page out: its file goes. The repository's history keeps it.
    public func delete(_ title: String) throws {
        guard let entry = entries[title] else { return }
        try FileManager.default.removeItem(at: root.appendingPathComponent(entry.path))
        unindex(entry)
        entries[title] = nil
        indexNames()
    }

    // MARK: Names

    private func indexNames() {
        var titles: [String: String] = [:], aliases: [String: String] = [:]
        for entry in entries.values.sorted(by: { $0.path < $1.path }) {
            let key = NoteIndex.foldKey(entry.page.title)
            if titles[key] == nil { titles[key] = entry.page.title }
            for alias in entry.note.aliases {
                let key = NoteIndex.foldKey(alias)
                if aliases[key] == nil { aliases[key] = entry.page.title }
            }
        }
        names = titles.merging(aliases) { title, _ in title }
    }

    /// The title a link to `name` leads to: a date its day's, a week its
    /// week's — whether written yet or not — else a page by title, then by
    /// alias, case aside. Nil when nothing answers to it.
    public func title(for name: String) -> String? {
        let raw = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let day = Day(raw) { return day.description }
        // A week's page goes by its week's title, and answers to `2026-W44`.
        if let week = Week(raw) {
            return entries.values.first { if case .week(week) = $0.kind { true } else { false } }?.page.title ?? week.title
        }
        if entries[raw] != nil { return raw }
        return names[NoteIndex.foldKey(raw)]
    }

    /// Pages by what is typed: those whose title or an alias starts with it,
    /// then those containing it, then those whose text does.
    public func search(_ query: String, limit: Int = 50) -> [String] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        var starts: [String] = [], contains: [String] = [], inText: [String] = []
        for title in titles {
            guard let entry = entries[title] else { continue }
            if entry.names.contains(where: { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil }) {
                starts.append(title)
            } else if entry.names.contains(where: { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
                contains.append(title)
            } else if entry.page.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                inText.append(title)
            }
        }
        return Array((starts + contains + inText).prefix(limit))
    }

    // MARK: Renaming

    /// The pages that name `title`: linking to it, embedding it, tagged
    /// with it, listing it, asking for it in a query, or holding it in a field.
    public func references(to title: String) -> [String] {
        entries.values.filter { $0.page.title != title && Relink.page($0.page, from: title, to: title + "\u{0}") != $0.page }
            .map(\.page.title).sorted()
    }

    /// Every page naming `old` made to name `new` instead, and saved.
    /// Returns how many changed.
    @discardableResult
    public func relink(from old: String, to new: String) throws -> Int {
        var changed = 0
        for title in references(to: old) {
            guard let page = self[title] else { continue }
            let relinked = Relink.page(page, from: old, to: new)
            guard relinked != page else { continue }
            try save(relinked)
            changed += 1
        }
        return changed
    }

    // MARK: Conflicts

    /// Pages a sync left both devices' changes in, between markers.
    public func conflicted() -> [String] {
        entries.values.filter { ConflictMarkers.detect($0.source) }.map(\.page.title).sorted()
    }

    public func needsReview(_ title: String) -> Bool {
        entries[title].map { ConflictMarkers.detect($0.source) } ?? false
    }

    /// Settles a page's conflicts, keeping one side of each or both, in
    /// its file as written.
    public func resolve(_ title: String, keeping side: ConflictMarkers.Resolution) throws {
        guard let entry = entries[title] else { return }
        let resolved = ConflictMarkers.resolve(entry.source, keeping: side)
        try Data(resolved.utf8).write(to: root.appendingPathComponent(entry.path), options: .atomic)
        reload(path: entry.path)
    }

    // MARK: Links

    /// The titles a page links to: those it names that lead somewhere.
    public func links(from title: String) -> Set<String> {
        Set((outgoing[title] ?? []).compactMap { self.title(for: $0) })
    }

    /// The pages linking to a page by any name it answers to.
    public func backlinks(to title: String) -> [String] {
        let names = entries[title]?.names ?? [title]
        var linking = Set<String>()
        for name in names { linking.formUnion(incoming[NoteIndex.foldKey(name)] ?? []) }
        linking.remove(title)
        return linking.sorted()
    }

    /// Names linked to that lead to no page, and are no date.
    public func missing() -> [String] {
        var shown: [String: String] = [:]
        for targets in outgoing.values {
            for target in targets where title(for: target) == nil { shown[NoteIndex.foldKey(target)] = target }
        }
        return shown.values.sorted()
    }

    /// Pages nothing links to, tags, or lists.
    public func orphans() -> [String] {
        let tags = Set(entries.values.flatMap(\.tags).map { $0.lowercased() })
        let listed = Set(entries.values.flatMap { $0.page[field: "list"]?.list ?? [] })
        return entries.keys.filter { backlinks(to: $0).isEmpty && !tags.contains($0.lowercased()) && !listed.contains($0) }.sorted()
    }

    private func index(_ entry: Entry) {
        titlesByPath[entry.path] = entry.page.title
        let targets = WikiLinks.targets(in: entry.page.text)
        outgoing[entry.page.title] = targets
        for target in targets { incoming[NoteIndex.foldKey(target), default: []].insert(entry.page.title) }
    }

    private func unindex(_ entry: Entry) {
        if titlesByPath[entry.path] == entry.page.title { titlesByPath[entry.path] = nil }
        for target in outgoing[entry.page.title] ?? [] { incoming[NoteIndex.foldKey(target)]?.remove(entry.page.title) }
        outgoing[entry.page.title] = nil
    }

    // MARK: Tags

    /// A page's tags: its frontmatter's and the `#tags` in its body.
    public func tags(of title: String) -> [String] { entries[title]?.tags ?? [] }

    /// The pages tagged with `tag`, case aside, in the order the tag's own
    /// page lists them, then by title — as TiddlyWiki orders them.
    public func tagged(_ tag: String) -> [String] {
        let key = tag.lowercased()
        let all = Set(entries.values.filter { $0.tags.contains { $0.lowercased() == key } }.map(\.page.title))
        let listed = (entries[tag]?.page[field: "list"]?.list ?? []).filter(all.contains)
        return listed + all.subtracting(listed).sorted()
    }

    /// Every tag, with how many pages have it.
    public func tags() -> [(tag: String, count: Int)] {
        var counts: [String: (tag: String, count: Int)] = [:]
        for entry in entries.values {
            for tag in entry.tags { counts[tag.lowercased(), default: (tag, 0)].count += 1 }
        }
        return counts.values.map { ($0.tag, $0.count) }.sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    /// The pages written most lately, newest first.
    public func recent(limit: Int = 50) -> [String] {
        entries.values.sorted { $0.modified > $1.modified }.prefix(limit).map(\.page.title)
    }
}

/// The links in a page's Markdown: `[[Title]]`, `[[Title|shown]]`, and
/// embeds, `![[Title]]` — outside code.
public enum WikiLinks {
    public static func targets(in markdown: String) -> Set<String> {
        var targets = Set<String>()
        var inFence = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            guard !inFence, line.contains("[[") else { continue }
            var rest = removingCodeSpans(line)[...]
            while let open = rest.range(of: "[[") {
                guard let close = rest[open.upperBound...].range(of: "]]") else { break }
                var target = String(rest[open.upperBound..<close.lowerBound])
                if let bar = target.firstIndex(of: "|") { target = String(target[..<bar]) }
                target = target.replacingOccurrences(of: "\\", with: "").trimmingCharacters(in: .whitespaces)
                if !target.isEmpty { targets.insert(target) }
                rest = rest[close.upperBound...]
            }
        }
        return targets
    }

    private static func removingCodeSpans(_ line: Substring) -> String {
        var result = ""
        var inCode = false
        for character in line {
            if character == "`" { inCode.toggle(); continue }
            if !inCode { result.append(character) }
        }
        return result
    }
}
