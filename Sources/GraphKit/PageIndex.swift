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
        /// What it is shown as: its title — or, untitled, what it begins with.
        public var shown: String { note.untitledName ?? page.title }
        /// Whether it has no title yet: see `Untitled`.
        public var isUntitled: Bool { note.untitledName != nil }
        /// The names it is found by as they are typed: an untitled page's
        /// by what it is shown as, not by its made-up name.
        var searchNames: [String] { note.untitledName.map { [$0] + note.aliases } ?? names }
        /// Its frontmatter's tags and the `#tags` in its body, each once.
        public var tags: [String] {
            var seen = Set<String>()
            return (page.tags + note.tags).filter { seen.insert($0.lowercased()).inserted }
        }
    }

    public private(set) var entries: [String: Entry] = [:]
    /// The title of the page in each file.
    private var titlesByPath: [String: String] = [:]
    /// Whether private notes are read too: Prism lists them, saying only
    /// that they are private; Weft, as Reflect, never shows them.
    public let includesPrivate: Bool

    // Every structure below is kept as pages come and go — one page's worth
    // of work for each — so that no question asked of the index costs more
    // as the graph grows: only as what it asks about does.

    /// Every title, in order.
    public private(set) var titles: [String] = []
    /// Every title, the most lately written first.
    private var byRecency: [String] = []
    /// Who claims each name, by its fold key — as a title, and as an alias —
    /// and so the title it leads to: a title before an alias, the first by
    /// path of each, as Prism resolves links.
    private var titleClaims: [String: [(path: String, title: String)]] = [:]
    private var aliasClaims: [String: [(path: String, title: String)]] = [:]
    private var names: [String: String] = [:]
    /// The week each week's page is.
    private var weeks: [Week: String] = [:]
    /// The names each page links to, and the pages linking to each name, by
    /// its fold key, and how that name was last written.
    private var outgoing: [String: Set<String>] = [:]
    private var incoming: [String: Set<String>] = [:]
    private var spelling: [String: String] = [:]
    /// Names linked to that lead nowhere, by fold key.
    private var unresolved: [String: String] = [:]
    /// The pages with each tag, by the tag in lower case, and how it is written.
    private var taggedWith: [String: Set<String>] = [:]
    private var tagSpelling: [String: String] = [:]
    /// The pages with each flag, or of each kind.
    private var flagged: [Query.Flag: Set<String>] = [:]
    /// The pages listing each title in their `list` field, and those holding
    /// each name in any other field.
    private var listers: [String: Set<String>] = [:]
    private var fieldMentions: [String: Set<String>] = [:]
    /// Pages a sync left both sides in.
    private var conflictedTitles: Set<String> = []

    /// What search looks through, folded once as each page is indexed —
    /// case, accents and widths set aside, curly quotes as straight.
    private struct Folded {
        var names: [String]
        var text: [UInt8]
    }
    private var folded: [String: Folded] = [:]
    /// Every page's words, each with the pages using it, and every word in
    /// order — so the pages with a word, or with a word starting so, are
    /// found without reading any.
    private var wordPages: [UInt64: Set<Int32>] = [:]
    private var vocabulary: [String] = []
    /// Each page's number, for the word index's sets: small, and quick to
    /// hash and to intersect.
    private var ids: [String: Int32] = [:]
    private var titleOf: [Int32: String] = [:]
    private var freeIDs: [Int32] = []
    private var nextID: Int32 = 0
    /// Every tag, in order, made again only when one comes or goes.
    private var sortedTags: [String]?
    /// Each name folded — and each of its words, with the rest of it — with
    /// its page, in order: so the pages a name starts with, or a word in a
    /// name, are found by halving.
    private struct NameKey: Comparable {
        var key: String
        var title: String
        static func < (a: NameKey, b: NameKey) -> Bool { a.key != b.key ? a.key < b.key : a.title < b.title }
    }
    private var nameKeys: [NameKey] = []
    /// While every page is read at once: the ordered tables are made once, at the end.
    private var bulk = false
    /// While every page is read at once: told each word new to the index.
    private var wordSpelled: ((UInt64, String) -> Void)?

    /// Case, accents and widths set aside, and curly quotes taken as
    /// straight: "ai's" finds "AI’s".
    public static func fold(_ text: String) -> String {
        var folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        if folded.unicodeScalars.contains(where: { quotes[$0] != nil }) {
            folded = String(String.UnicodeScalarView(folded.unicodeScalars.map { quotes[$0] ?? $0 }))
        }
        return folded
    }

    private static let quotes: [Unicode.Scalar: Unicode.Scalar] = ["\u{2018}": "'", "\u{2019}": "'", "\u{201C}": "\"", "\u{201D}": "\""]

    /// Told of each page that changes — saved, read again, or deleted —
    /// as it was and as it is: for an app to redraw only what showed it.
    public var onChanged: ((_ before: Entry?, _ after: Entry?) -> Void)?

    /// The pages' words on disk, ranked, kept as pages change: what finding
    /// pages by what they say asks, once it is ready — till then, and
    /// without one, the word index here. Given, made to say what the pages
    /// read so far say.
    public var textIndex: TextIndex? {
        didSet { if let textIndex, textIndex !== oldValue, !entries.isEmpty { textIndex.sync(sources: textSources()) } }
    }

    /// The text in the graph's pictures, as read so far: what a page's
    /// pictures say, found as what it says.
    public var pictures: ImageTextIndex?

    /// The system's search, told of the pages as they change — but never of
    /// a private note. Given, told of those read so far.
    public var spotlight: SpotlightIndex? {
        didSet { if let spotlight, spotlight !== oldValue, !entries.isEmpty { spotlight.sync(entries.values.compactMap(spotlightItem)) } }
    }

    /// A page as the system's search is told it; nil for a private note.
    func spotlightItem(_ entry: Entry) -> SpotlightIndex.Item? {
        guard !entry.note.isPrivate else { return nil }
        return SpotlightIndex.Item(path: entry.path, title: entry.shown, summary: SpotlightIndex.summary(of: entry.page.text),
                                   keywords: entry.tags + entry.note.aliases, modified: entry.modified)
    }

    /// The system's search told of a page as it is now — or that it is gone.
    private func tellSpotlight(_ entry: Entry?, was path: String?) {
        guard let spotlight else { return }
        if let path, path != entry?.path { spotlight.remove(path: path) }
        if let entry {
            if let item = spotlightItem(entry) { spotlight.put(item) } else { spotlight.remove(path: entry.path) }
        }
    }

    /// More pictures read: the pages showing them kept again, with it.
    public func picturesRead() {
        textIndex?.sync(sources: textSources())
    }

    private func textSources() -> [TextIndex.Source] { entries.values.map(textSource) }

    /// A page as the words on disk keep it: its names, its text, and the
    /// text in the pictures it shows that have any.
    func textSource(_ entry: Entry) -> TextIndex.Source {
        TextIndex.Source(path: entry.path, title: entry.shown, names: entry.note.aliases, text: entry.page.text,
                         pictures: picturesSaying(in: entry))
    }

    /// The pictures a page shows that have text, in order, with it.
    private func picturesSaying(in entry: Entry) -> [(path: String, text: String)] {
        guard let pictures, entry.page.text.contains("assets/") else { return [] }
        return NoteIndex.assets(in: entry.page.text).sorted().compactMap { path in pictures.text(path).map { (path, $0) } }
    }

    public init(root: URL, includingPrivate: Bool = false) {
        self.root = root.standardizedFileURL
        includesPrivate = includingPrivate
    }

    public subscript(title: String) -> Page? { entries[title]?.page }

    /// What a page is shown as: its title, or — untitled — what it begins with.
    public func shown(_ title: String) -> String { entries[title]?.shown ?? title }

    /// A name for a new untitled page, that no page or file has.
    public func newUntitledName(at date: Date = Date()) -> String {
        while true {
            let name = Untitled.newName(at: date)
            if entries[name] == nil, !FileManager.default.fileExists(atPath: root.appendingPathComponent("\(GraphPaths.notesDirectory)/\(name).md").path) {
                return name
            }
        }
    }

    /// The page kept in a graph-relative file, as Prism finds notes.
    public func entry(atPath path: String) -> Entry? { titlesByPath[path].flatMap { entries[$0] } }

    /// When pages last changed by the graph's history — their last
    /// commit's — for those whose frontmatter does not say, and whose file
    /// has not changed since: as Prism dates notes in a fresh clone, whose
    /// files' times are all the clone's. `paths`: only these files' pages.
    public func useHistory(_ times: [String: Date], uncommitted: Set<String>, paths: Set<String>? = nil) {
        let titles = paths.map { $0.compactMap { titlesByPath[$0] } } ?? Array(entries.keys)
        for title in titles {
            guard let entry = entries[title], entry.page.modified == nil else { continue }
            let modified = (uncommitted.contains(entry.path) ? nil : times[entry.path]) ?? entry.written
            guard modified != entry.modified else { continue }
            Self.remove(title, from: &byRecency, by: recencyOrder)
            entries[title]?.modified = modified
            Self.insert(title, into: &byRecency, by: recencyOrder)
        }
    }

    /// Reads every page. A title two files claim goes to the first by path;
    /// a private note is left out, as Reflect never shows one. Safe to call
    /// off the main thread, on an index nothing else is using yet.
    public func load() throws {
        entries = [:]; titlesByPath = [:]; titles = []; byRecency = []
        titleClaims = [:]; aliasClaims = [:]; names = [:]; weeks = [:]
        outgoing = [:]; incoming = [:]; spelling = [:]; unresolved = [:]
        taggedWith = [:]; tagSpelling = [:]; flagged = [:]; listers = [:]; fieldMentions = [:]
        conflictedTitles = []; folded = [:]; wordPages = [:]; vocabulary = []; nameKeys = []
        ids = [:]; titleOf = [:]; freeIDs = []; nextID = 0; sortedTags = nil
        var spelled: [UInt64: String] = [:]
        wordSpelled = { spelled[$0] = $1 }
        bulk = true
        // Read and parsed side by side, then indexed in order — so the first
        // by path still wins a title two files claim.
        let paths = Self.pagePaths(in: root)
        var read = [Prepared?](repeating: nil, count: paths.count)
        read.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            let root = root
            DispatchQueue.concurrentPerform(iterations: paths.count) { i in base[i] = Self.read(paths[i], in: root).map(Self.prepare) }
        }
        for prepared in read {
            guard let prepared, includesPrivate || !prepared.entry.note.isPrivate, entries[prepared.entry.page.title] == nil else { continue }
            add(prepared)
        }
        bulk = false
        titles = entries.keys.sorted()
        byRecency = entries.keys.sorted(by: recencyOrder)
        vocabulary = spelled.values.sorted()
        wordSpelled = nil
        nameKeys = entries.values.flatMap { Self.nameKeys(for: $0.page.title, folded: folded[$0.page.title]?.names ?? []) }.sorted()
        for key in incoming.keys { recheckMissing(key) }
        textIndex?.sync(sources: textSources())
        spotlight?.sync(entries.values.compactMap(spotlightItem))
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
        // title it was made with, is; or it was untitled, and named by its
        // file, or is untitled now.
        let retitled = previous != nil && previous?.page.title != page.title
        let moving = retitled && (movingFile || previous.map { Untitled.isPath($0.path) } == true || Untitled.isName(page.title))
        let path: String
        if let previous, !moving {
            path = previous.path
        } else {
            path = PageFolder.path(for: page.title, in: root, isTaken: { [titlesByPath] in titlesByPath[$0] != nil && $0 != previous?.path },
                                   ignoring: previous?.path)
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
        // Read back as it will be read: its title, aliases and tags as written.
        var entry = Self.entry(path: path, source: source, written: Date())
        entry.page = page
        let prepared = Self.prepare(entry)
        // Its words still in it keep their place in the vocabulary: not
        // each taken out of it and put back, a sorted list moved each time.
        if let previous { remove(previous, keeping: Set(prepared.words.lazy.map(\.hash))) }
        add(prepared)
        if let old = previous?.path, old != entry.path { textIndex?.remove(path: old) }
        textIndex?.put(textSource(entry))
        tellSpotlight(entry, was: previous?.path)
        onChanged?(previous, entry)
        return entry
    }

    /// Reads one page's file again — after another app or a sync wrote
    /// it — or forgets it, when the file is gone.
    public func reload(path: String) {
        let previous = entry(atPath: path)
        if let previous { remove(previous) }
        var now: Entry?
        if let entry = Self.read(path, in: root), includesPrivate || !entry.note.isPrivate, entries[entry.page.title] == nil {
            add(entry)
            now = entry
        }
        if let now { textIndex?.put(textSource(now)) } else if previous != nil { textIndex?.remove(path: path) }
        tellSpotlight(now, was: previous?.path)
        if previous != nil || now != nil { onChanged?(previous, now) }
    }

    /// Takes a page out: its file goes. The repository's history keeps it.
    public func delete(_ title: String) throws {
        guard let entry = entries[title] else { return }
        try FileManager.default.removeItem(at: root.appendingPathComponent(entry.path))
        remove(entry)
        textIndex?.remove(path: entry.path)
        tellSpotlight(nil, was: entry.path)
        onChanged?(entry, nil)
    }

    // MARK: Keeping the tables

    /// A page with what indexing it needs worked out — its names and text
    /// folded, its words found — which can be done anywhere, side by side.
    private struct Prepared {
        var entry: Entry
        var folded: Folded
        var words: [(hash: UInt64, range: Range<Int>)]
    }

    private static func prepare(_ entry: Entry) -> Prepared {
        let text = Array(fold(entry.page.text).utf8)
        var words: [(UInt64, Range<Int>)] = []
        forEachWord(in: text) { hash, word in words.append((hash, word.indices)) }
        return Prepared(entry: entry, folded: Folded(names: entry.searchNames.map(fold), text: text), words: words)
    }

    private func add(_ entry: Entry) { add(Self.prepare(entry)) }

    private func add(_ prepared: Prepared) {
        let entry = prepared.entry
        let title = entry.page.title
        entries[title] = entry
        titlesByPath[entry.path] = title
        let foldedNames = prepared.folded.names
        let text = prepared.folded.text
        folded[title] = prepared.folded
        if !bulk {
            Self.insert(title, into: &titles, by: <)
            Self.insert(title, into: &byRecency, by: recencyOrder)
            for key in Self.nameKeys(for: title, folded: foldedNames) { Self.insert(key, into: &nameKeys, by: <) }
        }
        let id = freeIDs.popLast() ?? { nextID += 1; return nextID - 1 }()
        ids[title] = id
        titleOf[id] = title
        for (hash, range) in prepared.words {
            if wordPages[hash] == nil {
                let spelled = String(decoding: text[range], as: UTF8.self)
                if bulk { wordSpelled?(hash, spelled) } else { Self.insert(spelled, into: &vocabulary, by: <) }
            }
            wordPages[hash, default: []].insert(id)
        }
        // Names.
        claim(NoteIndex.foldKey(title), asTitle: true, path: entry.path, title: title)
        for alias in entry.note.aliases { claim(NoteIndex.foldKey(alias), asTitle: false, path: entry.path, title: title) }
        if case .week(let week) = entry.kind { weeks[week] = title }
        // Links.
        let targets = WikiLinks.targets(in: entry.page.text)
        outgoing[title] = targets
        for target in targets {
            let key = NoteIndex.foldKey(target)
            incoming[key, default: []].insert(title)
            spelling[key] = target
            if !bulk { recheckMissing(key) }
        }
        // Tags, flags, lists, fields, conflicts.
        for tag in entry.tags {
            if taggedWith[tag.lowercased()] == nil { sortedTags = nil }
            taggedWith[tag.lowercased(), default: []].insert(title)
            if tagSpelling[tag.lowercased()] == nil { tagSpelling[tag.lowercased()] = tag }
        }
        for flag in Query.Flag.allCases where flag.holds(for: entry) { flagged[flag, default: []].insert(title) }
        for listed in entry.page[field: "list"]?.list ?? [] { listers[listed, default: []].insert(title) }
        for key in Self.fieldKeys(entry.page) { fieldMentions[key, default: []].insert(title) }
        if entry.source.contains("<<<<<<< "), ConflictMarkers.detect(entry.source) { conflictedTitles.insert(title) }
    }

    private func remove(_ entry: Entry, keeping kept: Set<UInt64> = []) {
        let title = entry.page.title
        guard entries[title]?.path == entry.path else { return }
        let old = folded[title]
        Self.remove(title, from: &titles, by: <)
        Self.remove(title, from: &byRecency, by: recencyOrder)
        for key in Self.nameKeys(for: title, folded: old?.names ?? []) { Self.remove(key, from: &nameKeys, by: <) }
        if let id = ids[title] {
            Self.forEachWord(in: old?.text ?? []) { hash, word in
                wordPages[hash]?.remove(id)
                if wordPages[hash]?.isEmpty == true, !kept.contains(hash) {
                    wordPages[hash] = nil
                    Self.remove(String(decoding: word, as: UTF8.self), from: &vocabulary, by: <)
                }
            }
            ids[title] = nil
            titleOf[id] = nil
            freeIDs.append(id)
        }
        unclaim(NoteIndex.foldKey(title), asTitle: true, path: entry.path)
        for alias in entry.note.aliases { unclaim(NoteIndex.foldKey(alias), asTitle: false, path: entry.path) }
        if case .week(let week) = entry.kind, weeks[week] == title { weeks[week] = nil }
        for target in outgoing[title] ?? [] {
            let key = NoteIndex.foldKey(target)
            incoming[key]?.remove(title)
            if incoming[key]?.isEmpty == true { incoming[key] = nil; spelling[key] = nil }
            recheckMissing(key)
        }
        outgoing[title] = nil
        for tag in entry.tags {
            taggedWith[tag.lowercased()]?.remove(title)
            if taggedWith[tag.lowercased()]?.isEmpty == true {
                taggedWith[tag.lowercased()] = nil
                tagSpelling[tag.lowercased()] = nil
                sortedTags = nil
            }
        }
        for flag in Query.Flag.allCases { flagged[flag]?.remove(title) }
        for listed in entry.page[field: "list"]?.list ?? [] { listers[listed]?.remove(title) }
        for key in Self.fieldKeys(entry.page) { fieldMentions[key]?.remove(title) }
        conflictedTitles.remove(title)
        folded[title] = nil
        if titlesByPath[entry.path] == title { titlesByPath[entry.path] = nil }
        entries[title] = nil
    }

    /// A name claimed by a page, as its title or an alias: the title it
    /// leads to settled again.
    private func claim(_ key: String, asTitle: Bool, path: String, title: String) {
        if asTitle { titleClaims[key, default: []].append((path, title)) } else { aliasClaims[key, default: []].append((path, title)) }
        settle(key)
    }

    private func unclaim(_ key: String, asTitle: Bool, path: String) {
        if asTitle {
            titleClaims[key]?.removeAll { $0.path == path }
            if titleClaims[key]?.isEmpty == true { titleClaims[key] = nil }
        } else {
            aliasClaims[key]?.removeAll { $0.path == path }
            if aliasClaims[key]?.isEmpty == true { aliasClaims[key] = nil }
        }
        settle(key)
    }

    /// The title a name leads to: the first by path to have it as a title,
    /// else as an alias.
    private func settle(_ key: String) {
        let winner = titleClaims[key]?.min { $0.path < $1.path } ?? aliasClaims[key]?.min { $0.path < $1.path }
        guard names[key] != winner?.title else { return }
        names[key] = winner?.title
        if !bulk { recheckMissing(key) }
    }

    private func recheckMissing(_ key: String) {
        guard let shown = spelling[key], incoming[key]?.isEmpty == false, title(for: shown) == nil else {
            unresolved[key] = nil
            return
        }
        unresolved[key] = shown
    }

    private func recencyOrder(_ a: String, _ b: String) -> Bool {
        let x = entries[a]?.modified ?? .distantPast, y = entries[b]?.modified ?? .distantPast
        return x != y ? x > y : a < b
    }

    private static func nameKeys(for title: String, folded names: [String]) -> [NameKey] {
        var keys: [NameKey] = []
        var seen = Set<String>()
        for name in names {
            // The whole name, and the rest of it from each word on.
            var starts = [name.startIndex]
            var previous: Character = " "
            for index in name.indices {
                let character = name[index]
                if index != name.startIndex, !(previous.isLetter || previous.isNumber), character.isLetter || character.isNumber { starts.append(index) }
                previous = character
            }
            for start in starts {
                let key = String(name[start...])
                if seen.insert(key).inserted { keys.append(NameKey(key: key, title: title)) }
            }
        }
        return keys
    }

    /// A folded text's words — its runs of letters and digits, and of
    /// anything not ASCII, which is a letter somewhere — each once, with its
    /// hash: no string is made unless the index has never seen the word.
    static func forEachWord(in text: [UInt8], _ body: (UInt64, ArraySlice<UInt8>) -> Void) {
        var seen = Set<UInt64>()
        var start: Int?
        var hash: UInt64 = 0
        func isWord(_ byte: UInt8) -> Bool { byte >= 0x80 || (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A) }
        text.withUnsafeBufferPointer { bytes in
            for i in 0...bytes.count {
                if i < bytes.count, isWord(bytes[i]) {
                    if start == nil { start = i; hash = 0xcbf29ce484222325 }
                    hash = (hash ^ UInt64(bytes[i])) &* 0x100000001b3
                } else if let s = start {
                    if i - s <= 64, seen.insert(hash).inserted { body(hash, text[s..<i]) }
                    start = nil
                }
            }
        }
    }

    static func hash(_ word: String) -> UInt64 {
        word.utf8.reduce(0xcbf29ce484222325) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
    }

    private static func fieldKeys(_ page: Page) -> Set<String> {
        var keys = Set<String>()
        for field in page.fields where field.name != "list" {
            switch field.value {
            case .text(let text): keys.insert(NoteIndex.foldKey(text))
            case .list(let items): for item in items { keys.insert(NoteIndex.foldKey(item)) }
            }
        }
        return keys
    }

    // MARK: Ordered arrays

    /// Where an element goes in an array in order — by halving.
    private static func place<T>(of element: T, in array: [T], by less: (T, T) -> Bool) -> Int {
        var low = 0, high = array.count
        while low < high {
            let middle = (low + high) / 2
            if less(array[middle], element) { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func insert<T: Equatable>(_ element: T, into array: inout [T], by less: (T, T) -> Bool) {
        let at = place(of: element, in: array, by: less)
        if at < array.count, array[at] == element { return }
        array.insert(element, at: at)
    }

    private static func remove<T: Equatable>(_ element: T, from array: inout [T], by less: (T, T) -> Bool) {
        let at = place(of: element, in: array, by: less)
        if at < array.count, array[at] == element { array.remove(at: at) }
    }

    // MARK: Names

    /// The title a link to `name` leads to: a date its day's, a week its
    /// week's — whether written yet or not — else a page by title, then by
    /// alias, case aside. Nil when nothing answers to it.
    public func title(for name: String) -> String? {
        let raw = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let day = Day(raw) { return day.description }
        // A week's page goes by its week's title, and answers to `2026-W44`.
        if let week = Week(raw) { return weeks[week] ?? week.title }
        if entries[raw] != nil { return raw }
        return names[NoteIndex.foldKey(raw)]
    }

    // MARK: Finding

    /// The pages that may have every word of a folded query — the last, as
    /// it is being typed, as the start of a word — by the word index: a set
    /// of pages (nil for every page), and, when the last word starts too many
    /// words to gather, what each page must be checked for as it is met.
    private struct Candidates {
        var pages: Set<Int32>?
        var check: [UInt8]?
    }

    private func candidates(_ query: String) -> Candidates? {
        let terms = query.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        guard let last = terms.last else { return nil }
        var sets: [Set<Int32>] = []
        for term in terms.dropLast() {
            guard let pages = wordPages[Self.hash(term)] else { return Candidates(pages: [], check: nil) }
            sets.append(pages)
        }
        var check: [UInt8]?
        // A letter alone starts too many words to gather: as a word, then.
        if last.count < 2 {
            guard let pages = wordPages[Self.hash(last)] else { return Candidates(pages: [], check: nil) }
            sets.append(pages)
        } else {
            let first = Self.place(of: last, in: vocabulary, by: <)
            var end = first
            while end < vocabulary.count, end - first <= 48, vocabulary[end].hasPrefix(last) { end += 1 }
            if end - first > 48 {
                check = Array(last.utf8)
            } else {
                var starting = Set<Int32>()
                for word in vocabulary[first..<end] { starting.formUnion(wordPages[Self.hash(word)] ?? []) }
                sets.append(starting)
            }
        }
        sets.sort { $0.count < $1.count }
        guard var found = sets.first else { return Candidates(pages: nil, check: check) }
        for set in sets.dropFirst() where !found.isEmpty { found.formIntersection(set) }
        return Candidates(pages: found, check: check)
    }

    /// Candidates, the most lately written first, as many as are wanted: by
    /// sorting them when they are few, else by walking every page newest
    /// first till enough are met — no more looked at than are needed.
    private func newestFirst(_ candidates: Candidates, while wanted: (String) -> Bool) {
        func passes(_ title: String) -> Bool {
            guard let check = candidates.check else { return true }
            return folded[title].map { Self.offset(check, in: $0.text) != nil } ?? false
        }
        if let pages = candidates.pages, pages.count * 8 < byRecency.count {
            for title in pages.compactMap({ titleOf[$0] }).sorted(by: recencyOrder) where passes(title) {
                if !wanted(title) { return }
            }
        } else {
            for title in byRecency {
                if let pages = candidates.pages { guard let id = ids[title], pages.contains(id) else { continue } }
                guard passes(title) else { continue }
                if !wanted(title) { return }
            }
        }
    }

    /// Where a needle first is in a folded text, in bytes.
    private static func offset(_ needle: [UInt8], in text: [UInt8]) -> Int? {
        guard !needle.isEmpty, text.count >= needle.count else { return nil }
        return needle.withUnsafeBytes { n in
            text.withUnsafeBytes { h in
                memmem(h.baseAddress, h.count, n.baseAddress, n.count).map { UnsafeRawPointer($0) - h.baseAddress! }
            }
        }
    }

    /// Pages by what is typed: those whose title or an alias starts with it,
    /// then those with a word in a name starting with it, then — the most
    /// lately written first — those whose text has its words.
    public func search(_ query: String, limit: Int = 50) -> [String] {
        let typed = query
        let query = Self.fold(query.trimmingCharacters(in: .whitespaces))
        guard !query.isEmpty, limit > 0 else { return [] }
        var found = named(query, limit: limit)
        var seen = Set(found)
        guard found.count < limit else { return Array(found.prefix(limit)) }
        // Then by what they say: best first, once the words on disk are
        // ready; else the most lately written first.
        if let textIndex, textIndex.isReady {
            for title in ranked(TextQuery(typed, typing: true), limit: limit * 2, in: textIndex) where seen.insert(title).inserted {
                found.append(title)
                if found.count >= limit { break }
            }
            return found
        }
        guard let candidates = candidates(query) else { return found }
        newestFirst(candidates) { title in
            if seen.insert(title).inserted { found.append(title) }
            return found.count < limit
        }
        return found
    }

    /// Pages by their names: those a name of starts with what is typed,
    /// folded, then those with a word in a name starting so.
    private func named(_ query: String, limit: Int) -> [String] {
        var starts: [String] = [], within: [String] = []
        var seen = Set<String>()
        var at = Self.place(of: NameKey(key: query, title: ""), in: nameKeys, by: <)
        while at < nameKeys.count, nameKeys[at].key.hasPrefix(query), starts.count + within.count < limit * 4 {
            let key = nameKeys[at]
            if seen.insert(key.title).inserted {
                if folded[key.title]?.names.contains(where: { $0.hasPrefix(query) }) == true { starts.append(key.title) } else { within.append(key.title) }
            }
            at += 1
        }
        return Array((starts + within).prefix(limit))
    }

    // MARK: Finding by what pages say

    /// The pages saying what is asked — every word, the phrases as written,
    /// none of what is left out — best first: by the words on disk, ranked,
    /// what was written lately a little before the rest; without them, or
    /// till they are ready, the most lately written first.
    public func textMatches(_ query: TextQuery, limit: Int = 1000) -> [String] {
        guard !query.isEmpty, limit > 0 else { return [] }
        if let textIndex, textIndex.isReady { return ranked(query, limit: limit, in: textIndex) }
        // Without them: every page read, the most lately written first — its
        // text and its names — as only till they are ready.
        let words = query.words.map { Array($0.utf8) }
        let phrases = query.phrases.map { Array($0.utf8) }
        let excluded = query.excluded.map { Array($0.utf8) }
        var found: [String] = []
        for title in byRecency {
            guard let page = folded[title] else { continue }
            let names = Array(page.names.joined(separator: "\n").utf8)
            func has(_ word: [UInt8], prefix: Bool) -> Bool {
                Self.hasWord(word, in: page.text, prefix: prefix) || Self.hasWord(word, in: names, prefix: prefix)
            }
            func says(_ phrase: [UInt8]) -> Bool { Self.offset(phrase, in: page.text) != nil || Self.offset(phrase, in: names) != nil }
            guard words.enumerated().allSatisfy({ has($1, prefix: query.prefix && $0 == words.count - 1) }),
                  phrases.allSatisfy(says), !excluded.contains(where: says) else { continue }
            found.append(title)
            if found.count >= limit { break }
        }
        return found
    }

    /// Pages about what is typed, by meaning — not its words, but words
    /// like them — the nearest first: those near enough.
    public func meaningMatches(_ text: String, limit: Int = 12) -> [String] {
        guard let textIndex, textIndex.isReady else { return [] }
        return textIndex.meaning(of: text, limit: limit).compactMap { titlesByPath[$0.path] }
    }

    /// Pages about what a page is about, the nearest first.
    public func related(byMeaning title: String, limit: Int = 8) -> [String] {
        guard let textIndex, textIndex.isReady, let path = entries[title]?.path else { return [] }
        return textIndex.meaning(near: path, limit: limit).compactMap { titlesByPath[$0.path] }
    }

    private func ranked(_ query: TextQuery, limit: Int, in textIndex: TextIndex) -> [String] {
        guard let match = query.match else { return [] }
        let now = Date()
        // A little more than asked: what was written lately moved up among it.
        let found = textIndex.pages(matching: match, limit: limit + limit / 2 + 10).compactMap { hit -> (String, Double)? in
            guard let title = titlesByPath[hit.path], let entry = entries[title] else { return nil }
            let days = max(0, now.timeIntervalSince(entry.modified) / 86400)
            return (title, hit.score * (1 + 0.5 * exp(-days / 60)))
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Whether a folded text has a word, whole — or, `prefix`, a word
    /// starting so.
    private static func hasWord(_ word: [UInt8], in text: [UInt8], prefix: Bool = false) -> Bool {
        guard !word.isEmpty, text.count >= word.count else { return false }
        return text.withUnsafeBytes { h in
            word.withUnsafeBytes { n in
                var from = 0
                while from <= h.count - n.count,
                      let found = memmem(h.baseAddress! + from, h.count - from, n.baseAddress, n.count) {
                    let at = UnsafeRawPointer(found) - h.baseAddress!
                    let end = at + n.count
                    if at == 0 || !isWordByte(text[at - 1]), prefix || end >= text.count || !isWordByte(text[end]) { return true }
                    from = at + 1
                }
                return false
            }
        }
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte >= 128
    }

    /// A page found by what is typed: by its names, or by what it says —
    /// and the lines saying it, best first.
    public struct TextHit: Sendable, Equatable {
        public var title: String
        public var path: String
        /// Found by a name of its, not only by what it says.
        public var byName: Bool
        public var lines: [Line]

        public struct Line: Sendable, Equatable {
            /// Its place in the page's text, counting from 0.
            public var number: Int
            /// A picture's text, not a line of the page's: the picture's file.
            public var picture: String?
            /// The line as plain text, cut down round what was asked when long.
            public var text: String
            /// Where what was asked is in it, in characters.
            public var marks: [Range<Int>]
        }
    }

    /// Pages by what is typed — words, `"phrases"`, `-left out`, and
    /// `#tag`, `is:todo`, `-is:done`, `edited:today` — those named so first,
    /// then by what they say, best first; each with up to `lines` of its
    /// lines saying it.
    public func searchText(_ typed: String, limit: Int = 30, lines lineLimit: Int = 2) -> [TextHit] {
        let query = Query(search: typed)
        let text = TextQuery(query.textContains, typing: true)
        var rest = query
        rest.textContains = ""
        let conditions = !rest.text.isEmpty
        let allowed = conditions ? Set(rest.run(in: self, this: "")) : nil
        var titles: [String] = []
        var seen = Set<String>()
        var byName = Set<String>()
        if !text.isEmpty {
            // As a title or an alias begins, when only words were typed.
            if text.excluded.isEmpty, text.phrases.isEmpty {
                for title in named(Self.fold(query.textContains.trimmingCharacters(in: .whitespaces)), limit: limit)
                where allowed?.contains(title) ?? true && seen.insert(title).inserted {
                    titles.append(title)
                    byName.insert(title)
                }
            }
            for title in textMatches(text, limit: max(limit * 3, 60)) where allowed?.contains(title) ?? true && seen.insert(title).inserted {
                titles.append(title)
                if titles.count >= limit { break }
            }
        } else if conditions {
            titles = rest.run(in: self, this: "")
        }
        return titles.prefix(limit).compactMap { title in
            guard let entry = entries[title] else { return nil }
            return TextHit(title: title, path: entry.path, byName: byName.contains(title),
                           lines: lineLimit > 0 && !text.isEmpty ? lines(of: entry, saying: text, limit: lineLimit) : [])
        }
    }

    /// A page's lines saying any of what is asked, best first.
    private func lines(of entry: Entry, saying query: TextQuery, limit: Int) -> [TextHit.Line] {
        if let textIndex, textIndex.isReady, let match = query.anyMatch {
            let found = textIndex.lines(of: entry.path, matching: match, limit: limit)
            if !found.isEmpty {
                let pictures = found.contains { $0.number >= TextIndex.pictureLines } ? picturesSaying(in: entry) : []
                return found.map { hit in
                    var line = Self.line(hit.number, marked: hit.marked)
                    let at = hit.number - TextIndex.pictureLines
                    if at >= 0 { line.picture = pictures.indices.contains(at) ? pictures[at].path : "" }
                    return line
                }
            }
        }
        // Without the words on disk: the lines with any of the words in them,
        // in order, the words marked as written.
        let terms = (query.words + query.phrases).filter { !$0.isEmpty }
        var found: [TextHit.Line] = []
        for (number, raw) in entry.page.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let plain = Self.plainLine(String(raw))
            var marks: [Range<Int>] = []
            for term in terms {
                var from = plain.startIndex
                while let range = plain.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: from..<plain.endIndex) {
                    marks.append(plain.distance(from: plain.startIndex, to: range.lowerBound)..<plain.distance(from: plain.startIndex, to: range.upperBound))
                    from = range.upperBound
                }
            }
            guard !marks.isEmpty else { continue }
            found.append(Self.cut(TextHit.Line(number: number, text: plain, marks: marks.sorted { $0.lowerBound < $1.lowerBound })))
            if found.count >= limit { break }
        }
        return found
    }

    /// A line as SQLite marks it — what was asked between `\u{1}` and
    /// `\u{2}` — as a line with its marks.
    static func line(_ number: Int, marked: String) -> TextHit.Line {
        var text = ""
        var marks: [Range<Int>] = []
        var start: Int?
        var count = 0
        for character in marked {
            if character == "\u{1}" { start = count; continue }
            if character == "\u{2}" {
                if let begun = start, begun < count { marks.append(begun..<count) }
                start = nil
                continue
            }
            text.append(character)
            count += 1
        }
        return cut(TextHit.Line(number: number, text: text, marks: marks))
    }

    /// A long line cut down round where what was asked first is.
    static func cut(_ line: TextHit.Line, most: Int = 160) -> TextHit.Line {
        let count = line.text.count
        guard count > most else { return line }
        let center = line.marks.first?.lowerBound ?? 0
        let start = max(0, min(center - 24, count - most))
        let end = min(count, start + most)
        let from = line.text.index(line.text.startIndex, offsetBy: start)
        let to = line.text.index(from, offsetBy: end - start)
        let lead = start > 0 ? "…" : ""
        let shift = lead.count - start
        let marks = line.marks.compactMap { mark -> Range<Int>? in
            let lower = max(mark.lowerBound, start), upper = min(mark.upperBound, end)
            return lower < upper ? (lower + shift)..<(upper + shift) : nil
        }
        return TextHit.Line(number: line.number, picture: line.picture, text: lead + line.text[from..<to] + (end < count ? "…" : ""), marks: marks)
    }

    /// A line as a list of what was found shows it: plain, its list's or
    /// task's marker, its heading's hashes gone.
    static func plainLine(_ line: String) -> String {
        var line = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- [ ] ", "- [x] ", "+ [ ] ", "+ [x] ", "* [ ] ", "* [x] ", "- ", "* ", "+ ", "> "] where line.hasPrefix(marker) {
            line.removeFirst(marker.count)
            break
        }
        if line.hasPrefix("#") {
            let hashes = line.prefix { $0 == "#" }
            if line.dropFirst(hashes.count).first == " " { line.removeFirst(hashes.count) }
        }
        return InlineMarkup.plainText(line.trimmingCharacters(in: .whitespaces))
    }

    /// A page found by what it says, and the line that says it.
    public struct Found: Sendable, Equatable {
        public var title: String
        public var path: String
        /// The line with the words in it — together, if any has them so —
        /// as plain text, cut down round them when long.
        public var line: String
        /// Whether it has the words as typed, together.
        public var phrase: Bool
    }

    /// Pages saying what is asked, best first: those with the words as
    /// typed, together, then those with every one of them anywhere — each
    /// the most lately written first — with the line saying it. Only the
    /// pages the word index gives are read.
    public func find(_ query: String, limit: Int = 30) -> [Found] {
        let phrase = Self.fold(query.trimmingCharacters(in: .whitespaces))
        let terms = phrase.split(whereSeparator: \.isWhitespace).map { Array($0.utf8) }
        guard !terms.isEmpty, limit > 0, let candidates = candidates(phrase) else { return [] }
        let whole = Array(phrase.utf8)
        // The longest word, to find the line by when the words are apart.
        let longest = terms.max { $0.count < $1.count }!
        // Newest first: those saying it together, then the rest — stopping
        // once enough say it together.
        var together: [(title: String, phrase: Bool, at: Int)] = [], apart: [(title: String, phrase: Bool, at: Int)] = []
        newestFirst(candidates) { title in
            guard let text = folded[title]?.text else { return true }
            if let at = Self.offset(whole, in: text) {
                together.append((title, true, at))
            } else if apart.count < limit, let at = Self.offset(longest, in: text) {
                apart.append((title, false, at))
            }
            return together.count < limit
        }
        return (together + apart).prefix(limit).compactMap { hit in
            guard let entry = entries[hit.title], let text = folded[hit.title]?.text else { return nil }
            // Folding keeps the lines as they are: the line the match is on
            // is the same line in the text as written.
            let number = text[..<hit.at].reduce(0) { $1 == 10 ? $0 + 1 : $0 }
            let line = Self.line(number, of: entry.page.text)
            return Found(title: hit.title, path: entry.path, line: Self.shown(line, phrase: phrase, terms: terms), phrase: hit.phrase)
        }
    }

    /// A text's line, counting from 0, found by its newlines alone.
    static func line(_ number: Int, of text: String) -> String {
        let utf8 = text.utf8
        var start = utf8.startIndex, seen = 0
        while seen < number, let newline = utf8[start...].firstIndex(of: 10) {
            start = utf8.index(after: newline)
            seen += 1
        }
        guard seen == number else { return "" }
        let end = utf8[start...].firstIndex(of: 10) ?? utf8.endIndex
        return String(text[start..<end])
    }

    /// A line found, as a list shows it: plain, its marker gone, cut
    /// down round the words when long.
    static func shown(_ found: String, phrase: String, terms: [[UInt8]]) -> String {
        let words = terms.map { String(decoding: $0, as: UTF8.self) }
        var line = found.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["- [ ] ", "- [x] ", "+ [ ] ", "+ [x] ", "- ", "* ", "+ ", "> "] where line.hasPrefix(marker) {
            line.removeFirst(marker.count)
            break
        }
        while line.hasPrefix("#") { line.removeFirst() }
        line = InlineMarkup.plainText(line.trimmingCharacters(in: .whitespaces))
        // Long, cut round where the words are.
        let most = 140
        guard line.count > most else { return line }
        let at = line.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive])
            ?? words.lazy.compactMap { line.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }.first
        let center = at.map { line.distance(from: line.startIndex, to: $0.lowerBound) } ?? 0
        let start = max(0, min(center - 40, line.count - most))
        let from = line.index(line.startIndex, offsetBy: start)
        let to = line.index(from, offsetBy: most, limitedBy: line.endIndex) ?? line.endIndex
        return (start > 0 ? "…" : "") + line[from..<to] + (to < line.endIndex ? "…" : "")
    }

    // MARK: Renaming

    /// The pages that name `title`: linking to it, embedding it, tagged
    /// with it, listing it, asking for it in a query, or holding it in a
    /// field — gathered from the indices, each then read to be sure.
    public func references(to title: String) -> [String] {
        var candidates = Set(backlinks(to: title))
        candidates.formUnion(taggedWith[title.lowercased()] ?? [])
        candidates.formUnion(listers[title] ?? [])
        candidates.formUnion(fieldMentions[NoteIndex.foldKey(title)] ?? [])
        // Named in a query, or anywhere else in what a page says.
        candidates.formUnion(exactWords(Self.fold(title)) ?? [])
        candidates.remove(title)
        return candidates.filter { candidate in
            guard let page = entries[candidate]?.page else { return false }
            return Relink.page(page, from: title, to: title + "\u{0}") != page
        }.sorted()
    }

    /// The pages having every word of a folded text, whole.
    private func exactWords(_ text: String) -> Set<String>? {
        var hashes: [UInt64] = []
        Self.forEachWord(in: Array(text.utf8)) { hash, _ in hashes.append(hash) }
        guard !hashes.isEmpty else { return nil }
        var found: Set<Int32>?
        for hash in hashes.sorted(by: { (wordPages[$0]?.count ?? 0) < (wordPages[$1]?.count ?? 0) }) {
            let pages = wordPages[hash] ?? []
            found = found.map { $0.intersection(pages) } ?? pages
            if found?.isEmpty == true { break }
        }
        return Set((found ?? []).compactMap { titleOf[$0] })
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
    public func conflicted() -> [String] { conflictedTitles.sorted() }

    public func needsReview(_ title: String) -> Bool { conflictedTitles.contains(title) }

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

    /// The pages relating themselves to a page — naming it in their
    /// frontmatter `related:` — by title. Those it relates itself to are
    /// its own `note.related`.
    public func relating(to title: String) -> [String] {
        guard let entry = entries[title] else { return [] }
        let keys = Set(entry.names.map(NoteIndex.foldKey))
        return entries.values.filter { other in
            other.page.title != title && other.note.related.contains { keys.contains(NoteIndex.foldKey($0)) }
        }.map(\.page.title).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
    public func missing() -> [String] { unresolved.values.sorted() }

    /// Pages nothing links to, tags, or lists.
    public func orphans() -> [String] {
        titles.filter { backlinks(to: $0).isEmpty && taggedWith[$0.lowercased()] == nil && listers[$0]?.isEmpty != false }
    }

    // MARK: Tags and flags

    /// A page's tags: its frontmatter's and the `#tags` in its body.
    public func tags(of title: String) -> [String] { entries[title]?.tags ?? [] }

    /// The pages tagged with `tag`, case aside, in the order the tag's own
    /// page lists them, then by title — as TiddlyWiki orders them.
    public func tagged(_ tag: String) -> [String] {
        guard let all = taggedWith[tag.lowercased()] else { return [] }
        let listed = (entries[tag]?.page[field: "list"]?.list ?? []).filter(all.contains)
        return listed + all.subtracting(listed).sorted()
    }

    /// Every tag, with how many pages have it.
    public func tags() -> [(tag: String, count: Int)] {
        if sortedTags == nil {
            sortedTags = taggedWith.keys.sorted { (tagSpelling[$0] ?? $0).localizedStandardCompare(tagSpelling[$1] ?? $1) == .orderedAscending }
        }
        return sortedTags!.map { (tagSpelling[$0] ?? $0, taggedWith[$0]?.count ?? 0) }
    }

    /// The pages with a flag, or of a kind.
    public func pages(flagged flag: Query.Flag) -> Set<String> { flagged[flag] ?? [] }

    /// The pages written most lately, newest first.
    public func recent(limit: Int = 50) -> [String] { Array(byRecency.prefix(limit)) }
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
