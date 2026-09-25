import Foundation

/// A note of the graph: where it is, and what it is called.
public struct NoteEntry: Equatable, Sendable {
    public var path: String
    public var title: String
    /// Other names it answers to: frontmatter `aliases`, and the parts of a
    /// `Project // Topic` title.
    public var aliases: [String]
    /// The day, for a daily note.
    public var day: Day?
    public var modified: Date
    public var isPrivate: Bool
    /// Whether the title is the note's own first heading, rather than its
    /// frontmatter's or its file's name.
    public var titleIsHeading: Bool
    /// Where it is pinned, by Reflect's frontmatter `pinned:` — a number
    /// orders the pinned notes, `true` pins it after the numbered ones; nil
    /// when it is not pinned.
    public var pin: Pin? = nil
    /// The `#tags` in its text, each once, as first written.
    public var tags: [String] = []

    public enum Pin: Equatable, Sendable, Comparable {
        case order(Double)
        case unordered
    }
}

/// The graph's notes by name, as Reflect names them, for finding and
/// linking: a note's title is its frontmatter `title:`, else its first
/// top-level heading, else — a daily note — its date, else its file name.
/// Names match without regard to case or surrounding space.
public final class NoteIndex: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private var entries: [String: NoteEntry] = [:]
    /// The text of each note, as written and lowercased, for finding words
    /// in notes when Reflect's own index is not there to ask.
    private var bodies: [String: (text: String, folded: String)] = [:]

    public init(root: URL) {
        self.root = root
    }

    public static let directories = [GraphPaths.dailyDirectory, GraphPaths.notesDirectory, "templates"]

    /// The key two names match by: trimmed, and in lower case.
    public static func foldKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: Reading the graph

    /// Reads every note's name. A few thousand notes take a moment; call it
    /// off the main thread.
    public func scan() {
        var found: [String: NoteEntry] = [:]
        var texts: [String: (text: String, folded: String)] = [:]
        for directory in Self.directories {
            let base = root.appendingPathComponent(directory).resolvingSymlinksInPath()
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension == "md" {
                let full = url.resolvingSymlinksInPath().path
                guard full.hasPrefix(base.path + "/") else { continue }
                let path = directory + "/" + full.dropFirst(base.path.count + 1)
                guard let entry = read(path, at: url) else { continue }
                found[path] = entry.entry
                texts[path] = entry.text
            }
        }
        lock.lock()
        entries = found
        bodies = texts
        lock.unlock()
    }

    /// Reads one note again, after it was written; or forgets it, when it
    /// is gone.
    public func refresh(_ path: String) {
        let entry = read(path, at: root.appendingPathComponent(path))
        lock.lock()
        entries[path] = entry?.entry
        bodies[path] = entry?.text
        lock.unlock()
    }

    private func read(_ path: String, at url: URL) -> (entry: NoteEntry, text: (text: String, folded: String))? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let source = String(decoding: data, as: UTF8.self)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return (Self.entry(path: path, source: source, modified: modified), (source, source.lowercased()))
    }

    /// A note's name and the names it answers to, from its text.
    public static func entry(path: String, source: String, modified: Date = .distantPast) -> NoteEntry {
        let (raw, body) = CommitMessage.splitFrontmatter(source)
        let frontmatter = raw.map(Frontmatter.init) ?? Frontmatter(raw: "")
        let day = GraphPaths.day(fromDailyPath: path)
        var titleIsHeading = false
        var title = frontmatter.scalar("title")?.trimmingCharacters(in: .whitespaces) ?? ""
        if title.isEmpty, let heading = CommitMessage.firstH1(body) {
            title = heading
            titleIsHeading = true
        }
        if title.isEmpty { title = day?.description ?? String(path.split(separator: "/").last?.dropLast(3) ?? "") }

        var aliases = frontmatter.list("aliases")
        var keys = Set(aliases.map(foldKey))
        // `Project // Topic` answers to each of its parts.
        let parts = title.components(separatedBy: "//").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count > 1 {
            for part in parts where !part.isEmpty && keys.insert(foldKey(part)).inserted { aliases.append(part) }
        }
        let privacy = frontmatter.scalar("private").map { ["true", "yes", "on", "1"].contains($0.lowercased()) } ?? false
        return NoteEntry(path: path, title: title, aliases: aliases, day: day, modified: modified,
                         isPrivate: privacy, titleIsHeading: titleIsHeading,
                         pin: pin(frontmatter.scalar("pinned")), tags: tags(in: body))
    }

    /// Reflect's reading of `pinned:`: `true` (or yes, on, 1) pins, a
    /// number pins in that place, anything else does not.
    static func pin(_ value: String?) -> NoteEntry.Pin? {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return nil }
        if ["true", "yes", "on"].contains(value) { return .unordered }
        if let number = Double(value), number.isFinite { return .order(number) }
        return nil
    }

    /// The `#tags` in a note's text, outside code and links: each once,
    /// regardless of case, as first written.
    public static func tags(in body: String) -> [String] {
        guard body.contains("#") else { return [] }
        var tags: [String] = []
        var seen = Set<String>()
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
            guard line.contains("#") else { continue }
            let text = String(line) as NSString
            for span in InlineMarkup.spans(in: text, range: NSRange(location: 0, length: text.length)) {
                guard case .tag = span.kind else { continue }
                let tag = String(text.substring(with: span.range).dropFirst())
                if seen.insert(tag.lowercased()).inserted { tags.append(tag) }
            }
        }
        return tags
    }

    /// The pinned notes, in the order Reflect's sidebar has them: numbered
    /// ones by number, then the rest by title.
    public var pinned: [NoteEntry] {
        all.filter { $0.pin != nil }.sorted { a, b in
            if a.pin != b.pin { return a.pin! < b.pin! }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// Every tag in the graph, and how many notes have it, by name.
    public var tags: [(name: String, count: Int)] {
        var counts: [String: (name: String, count: Int)] = [:]
        for entry in all {
            for tag in entry.tags {
                counts[tag.lowercased(), default: (tag, 0)].count += 1
            }
        }
        return counts.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The notes with a tag, newest first.
    public func notes(tagged tag: String) -> [NoteEntry] {
        let key = tag.lowercased()
        return all.filter { $0.tags.contains { $0.lowercased() == key } }.sorted { $0.modified > $1.modified }
    }

    /// The order a note pinned now takes: after every other, as Reflect
    /// numbers its shelf.
    public var nextPinOrder: Int {
        let highest = all.compactMap { entry -> Double? in
            if case .order(let order) = entry.pin { return order }
            return nil
        }.max()
        return highest.map { min(Int($0) + 1024, Int(Int32.max)) } ?? 1024
    }

    public var all: [NoteEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.values)
    }

    /// A note's text, as last read.
    public func body(_ path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return bodies[path]?.text
    }

    public func entry(_ path: String) -> NoteEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[path]
    }

    // MARK: Links

    /// What `[[target]]` leads to, as Reflect resolves it: a date is its
    /// day's note, whether or not one is written yet; otherwise a note by
    /// title, then by alias. Nil when there is none.
    public func resolve(_ target: String) -> String? {
        let raw = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if let day = Day(raw) { return GraphPaths.dailyPath(for: day) }
        let key = Self.foldKey(raw)
        let notes = all.sorted { $0.path < $1.path }
        return notes.first { Self.foldKey($0.title) == key }?.path
            ?? notes.first { $0.aliases.contains { Self.foldKey($0) == key } }?.path
    }

    // MARK: Finding

    /// A note found by a query, and how well it was found.
    public struct Match: Sendable {
        public var entry: NoteEntry
        public var score: Double
        /// The name it was found by, when not its title.
        public var alias: String?
    }

    /// Notes whose names match a query, best first: the whole name, then
    /// its start, then the starts of its words, then anywhere in it, then
    /// its letters in order. Daily notes, whose names are dates, are left
    /// to the dates themselves.
    public func matches(_ query: String, limit: Int = 50) -> [Match] {
        let key = Self.foldKey(query)
        // Days are found by their dates, not by name.
        let notes = all.filter { $0.day == nil }
        guard !key.isEmpty else {
            return notes.sorted { $0.modified > $1.modified }.prefix(limit).map { Match(entry: $0, score: 0) }
        }
        var found: [Match] = []
        for note in notes {
            var best: (score: Double, alias: String?)?
            for (name, alias) in [(note.title, nil as String?)] + note.aliases.map({ ($0, $0 as String?) }) {
                guard let score = Self.score(Self.foldKey(name), key) else { continue }
                // A title found is worth a little more than an alias.
                let adjusted = alias == nil ? score + 1 : score
                if best == nil || adjusted > best!.score { best = (adjusted, alias) }
            }
            if let best { found.append(Match(entry: note, score: best.score, alias: best.alias)) }
        }
        return found.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.entry.modified > $1.entry.modified
        }.prefix(limit).map { $0 }
    }

    /// How well a name matches a query, both folded; nil for not at all.
    static func score(_ name: String, _ query: String) -> Double? {
        if name == query { return 1000 }
        if name.hasPrefix(query) { return 800 - Double(name.count - query.count) * 0.1 }
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let terms = query.split(separator: " ")
        if !terms.isEmpty, terms.allSatisfy({ term in words.contains { $0.hasPrefix(term) } }) {
            return 600 - Double(name.count) * 0.1
        }
        if name.contains(query) { return 400 - Double(name.count) * 0.1 }
        // The query's letters in order, each starting a word or following
        // the one before — "dd" is "Design Doc", "apdes" "Apex Design" —
        // not strewn anywhere through a long name.
        return initials(name, query).map { 200 - Double($0) * 5 - Double(name.count) * 0.05 }
    }

    /// How many words a query's letters jump between, spelled out by word
    /// starts and runs; nil when they cannot be.
    private static func initials(_ name: String, _ query: String) -> Int? {
        let letters = Array(name), wanted = Array(query.filter { $0 != " " })
        func starts(_ index: Int) -> Bool {
            index == 0 || !(letters[index - 1].isLetter || letters[index - 1].isNumber)
                || (letters[index].isUppercase && letters[index - 1].isLowercase)
        }
        var best: Int?
        // Depth-first, taking the fewest jumps: names are short, queries shorter.
        func search(_ at: Int, _ from: Int, _ jumps: Int, _ previous: Int?) {
            if at == wanted.count {
                best = min(best ?? .max, jumps)
                return
            }
            if let best, jumps >= best { return }
            var index = from
            while index < letters.count {
                if Character(letters[index].lowercased()) == wanted[at] {
                    if previous == index - 1 { search(at + 1, index + 1, jumps, index) }
                    else if starts(index) { search(at + 1, index + 1, jumps + 1, index) }
                }
                index += 1
            }
        }
        search(0, 0, 0, nil)
        return best
    }

    /// Notes with a query's words in them, by reading their text: what is
    /// used when Reflect's own index is not there.
    public func containing(_ query: String, limit: Int = 30) -> [(path: String, snippet: String)] {
        let terms = Self.foldKey(query).split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        lock.lock()
        let texts = bodies
        lock.unlock()
        var found: [(path: String, snippet: String, modified: Date)] = []
        for (path, body) in texts where terms.allSatisfy({ body.folded.contains($0) }) {
            let text = body.text
            guard let range = text.range(of: terms[0], options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
            let snippet = text[start..<end].replacingOccurrences(of: "\n", with: " ")
            found.append((path, (start > text.startIndex ? "…" : "") + snippet + (end < text.endIndex ? "…" : ""),
                          entry(path)?.modified ?? .distantPast))
        }
        return found.sorted { $0.modified > $1.modified }.prefix(limit).map { ($0.path, $0.snippet) }
    }
}

/// The parts of a note's frontmatter a note's name needs: scalars, and lists
/// written either `[a, b]` or as `- a` lines.
public struct Frontmatter {
    let lines: [Substring]

    public init(raw: String) {
        lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
    }

    public func scalar(_ key: String) -> String? {
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].trimmingCharacters(in: .whitespaces) == key,
                  !line.hasPrefix(" ") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return Self.unquote(value)
        }
        return nil
    }

    public func list(_ key: String) -> [String] {
        for (index, line) in lines.enumerated() {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].trimmingCharacters(in: .whitespaces) == key,
                  !line.hasPrefix(" ") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("[") && value.hasSuffix("]") {
                return value.dropFirst().dropLast().split(separator: ",")
                    .map { Self.unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
            }
            if !value.isEmpty { return [Self.unquote(value)] }
            var items: [String] = []
            for next in lines[(index + 1)...] {
                let trimmed = next.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("-") else { break }
                let item = Self.unquote(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                if !item.isEmpty { items.append(item) }
            }
            return items
        }
        return []
    }

    /// A note's text with a frontmatter key set to a value — or taken out,
    /// for nil — leaving everything else as it was written. A note with no
    /// frontmatter gets some; frontmatter left with nothing in it goes.
    public static func setting(_ key: String, to value: String?, in source: String) -> String {
        let (raw, body) = CommitMessage.splitFrontmatter(source)
        var lines = raw.map { $0.isEmpty ? [] : $0.components(separatedBy: "\n") } ?? []
        let isKey = { (line: String) -> Bool in
            guard !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") else { return false }
            return line[..<colon].trimmingCharacters(in: .whitespaces) == key
        }
        if let index = lines.firstIndex(where: isKey) {
            // A list under the key goes with it.
            var end = index + 1
            while end < lines.count, lines[end].hasPrefix(" ") || lines[end].hasPrefix("-") { end += 1 }
            if let value {
                lines.replaceSubrange(index..<end, with: ["\(key): \(value)"])
            } else {
                lines.removeSubrange(index..<end)
            }
        } else if let value {
            lines.append("\(key): \(value)")
        } else {
            return source
        }
        if lines.isEmpty { return body }
        return "---\n" + lines.joined(separator: "\n") + "\n---\n" + body
    }

    static func unquote(_ value: String) -> String {
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
