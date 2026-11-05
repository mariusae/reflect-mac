import Foundation
import ReflectCore
import SQLite3

/// The graph's words on disk, for finding pages by what they say: SQLite's
/// full-text search over every page — its title, its other names, its text —
/// and over each of its lines, to show the line that says it.
///
/// Kept by each app in its own caches, never in the graph: nothing more is
/// synced, and a lost file is only made again. Made again too only where
/// pages changed since it was last kept: each page's file is known by a
/// hash of what it says.
///
/// Written on a queue of its own, read on whatever thread asks — through
/// a second connection, so a search never waits on pages being written.
public final class TextIndex: @unchecked Sendable {
    public let file: URL
    private var writer: OpaquePointer?
    private var reader: OpaquePointer?
    private let queue = DispatchQueue(label: "GraphKit.TextIndex", qos: .utility)
    private let readLock = NSLock()
    private let stateLock = NSLock()
    private var synced = false
    private var hadPages = false

    /// The version of what is kept: another, and it is made afresh.
    private static let schema = "2"

    /// Lines of a page are numbered within its row ids: this many to a page.
    private static let lineBits: Int64 = 20

    /// The index kept in a file — one per file, however many ask for it.
    public static func shared(at file: URL) -> TextIndex? {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let open = shared[file.path] { return open }
        guard let index = TextIndex(file: file) else { return nil }
        shared[file.path] = index
        return index
    }
    nonisolated(unsafe) private static var shared: [String: TextIndex] = [:]
    private static let sharedLock = NSLock()

    /// Where an app keeps a graph's: its caches, by the graph's path.
    public static func location(for root: URL, app: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let name = String(format: "%016llx", UInt64(bitPattern: Self.hash(root.standardizedFileURL.path)))
        return caches.appendingPathComponent(app).appendingPathComponent("Search").appendingPathComponent("\(name).sqlite")
    }

    init?(file: URL) {
        self.file = file
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let writer = Self.open(file, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) else { return nil }
        self.writer = writer
        Self.run(writer, "pragma journal_mode = wal")
        Self.run(writer, "pragma synchronous = normal")
        if Self.value(writer, "select value from meta where key = 'schema'") != Self.schema {
            for table in ["meta", "files", "pages", "lines"] { Self.run(writer, "drop table if exists \(table)") }
        }
        let tokenizer = "tokenize = \"unicode61 remove_diacritics 2\""
        guard Self.run(writer, "create table if not exists meta(key text primary key, value text)"),
              Self.run(writer, "create table if not exists files(path text primary key, stamp integer)"),
              Self.run(writer, "create virtual table if not exists pages using fts5(title, names, body, \(tokenizer))"),
              Self.run(writer, "create virtual table if not exists lines using fts5(text, \(tokenizer))"),
              Self.run(writer, "insert or replace into meta values('schema', '\(Self.schema)')"),
              let reader = Self.open(file, flags: SQLITE_OPEN_READONLY)
        else {
            sqlite3_close(writer)
            return nil
        }
        self.reader = reader
        hadPages = Self.value(writer, "select count(*) from files").flatMap(Int.init).map { $0 > 0 } ?? false
    }

    deinit {
        sqlite3_close(writer)
        sqlite3_close(reader)
    }

    /// Whether what it says can be asked: kept before, or made now.
    public var isReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return synced || hadPages
    }

    // MARK: Writing

    /// A page as given to be kept: its file, its names, and its text — its
    /// frontmatter not part of it — known again by a hash of them.
    public struct Source: Sendable {
        public var path: String
        public var title: String
        public var names: [String]
        public var text: String

        public init(path: String, title: String, names: [String] = [], text: String) {
            self.path = path
            self.title = title
            self.names = names
            self.text = text
        }

        init(_ entry: PageIndex.Entry) {
            self.init(path: entry.path, title: entry.shown, names: entry.note.aliases, text: entry.page.text)
        }

        var stamp: Int64 { TextIndex.hash(path + "\u{0}" + title + "\u{0}" + names.joined(separator: "\n") + "\u{0}" + text) }
    }

    /// A page as it is kept: what is searched, and the hash it was made from.
    struct Document {
        var path: String
        var stamp: Int64
        var title: String
        var names: String
        var body: String
        var lines: [(number: Int, text: String)]

        init(_ source: Source) {
            path = source.path
            title = source.title
            names = source.names.joined(separator: "\n")
            stamp = source.stamp
            var lines: [(Int, String)] = []
            for (number, line) in source.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let plain = PageIndex.plainLine(String(line))
                if !plain.isEmpty, number < 1 << TextIndex.lineBits { lines.append((number, plain)) }
            }
            self.lines = lines
            body = lines.map(\.1).joined(separator: "\n")
        }
    }

    /// Made to say what the pages say: those changed since it was kept,
    /// kept again; those gone, forgotten.
    func sync(_ entries: [PageIndex.Entry]) { sync(sources: entries.map(Source.init)) }

    /// Made to say what the pages given say — read in the background: those
    /// changed since it was kept, kept again; those gone, forgotten.
    public func sync(sources: [Source]) {
        queue.async { [self] in
            guard let writer else { return }
            Self.run(writer, "begin")
            var kept: [String: (id: Int64, stamp: Int64)] = [:]
            Self.each(writer, "select path, rowid, stamp from files") { row in
                kept[Self.text(row, 0)] = (sqlite3_column_int64(row, 1), sqlite3_column_int64(row, 2))
            }
            // Only a page whose hash differs is made into lines again.
            for source in sources {
                if let was = kept.removeValue(forKey: source.path), was.stamp == source.stamp { continue }
                write(Document(source))
            }
            for path in kept.keys { forget(path) }
            Self.run(writer, "commit")
            stateLock.lock()
            synced = true
            stateLock.unlock()
        }
    }

    /// A page kept as it is now — before this returns, so what is asked
    /// next finds it.
    func put(_ entry: PageIndex.Entry) { put(Source(entry)) }

    /// A page kept as it is now — before this returns, so what is asked
    /// next finds it.
    public func put(_ source: Source) {
        queue.sync { [self] in
            let document = Document(source)
            guard let writer else { return }
            Self.run(writer, "begin")
            write(document)
            Self.run(writer, "commit")
        }
    }

    /// A page's file forgotten, before this returns.
    public func remove(path: String) {
        queue.sync { [self] in
            guard let writer else { return }
            Self.run(writer, "begin")
            forget(path)
            Self.run(writer, "commit")
        }
    }

    /// Waits for what is being written: for tests, and the like.
    public func settle() { queue.sync {} }

    private func write(_ document: Document) {
        guard let writer else { return }
        let id: Int64
        if let was = rowid(of: document.path, in: writer) {
            if stamp(of: was, in: writer) == document.stamp { return }
            clear(was)
            id = was
            Self.run(writer, "update files set stamp = ? where rowid = ?", .int(document.stamp), .int(id))
        } else {
            Self.run(writer, "insert into files(path, stamp) values(?, ?)", .text(document.path), .int(document.stamp))
            id = sqlite3_last_insert_rowid(writer)
        }
        Self.run(writer, "insert into pages(rowid, title, names, body) values(?, ?, ?, ?)",
                 .int(id), .text(document.title), .text(document.names), .text(document.body))
        for (number, text) in document.lines {
            Self.run(writer, "insert into lines(rowid, text) values(?, ?)", .int(id << Self.lineBits | Int64(number)), .text(text))
        }
    }

    private func forget(_ path: String) {
        guard let writer, let id = rowid(of: path, in: writer) else { return }
        clear(id)
        Self.run(writer, "delete from files where rowid = ?", .int(id))
    }

    /// A page's words taken out, its file still known.
    private func clear(_ id: Int64) {
        guard let writer else { return }
        Self.run(writer, "delete from pages where rowid = ?", .int(id))
        Self.run(writer, "delete from lines where rowid between ? and ?", .int(id << Self.lineBits), .int((id + 1) << Self.lineBits - 1))
    }

    private func rowid(of path: String, in db: OpaquePointer) -> Int64? {
        var id: Int64?
        Self.each(db, "select rowid from files where path = ?", .text(path)) { id = sqlite3_column_int64($0, 0) }
        return id
    }

    private func stamp(of id: Int64, in db: OpaquePointer) -> Int64? {
        var stamp: Int64?
        Self.each(db, "select stamp from files where rowid = ?", .int(id)) { stamp = sqlite3_column_int64($0, 0) }
        return stamp
    }

    // MARK: Reading

    /// Pages with what is asked, best first — a word in a title counting
    /// most, then in another name, then in the text — each with its score:
    /// the higher, the better.
    func pages(matching match: String, limit: Int) -> [(path: String, score: Double)] {
        readLock.lock()
        defer { readLock.unlock() }
        guard let reader else { return [] }
        var found: [(String, Double)] = []
        Self.each(reader, """
            select files.path, bm25(pages, 10.0, 6.0, 1.0) as score from pages join files on files.rowid = pages.rowid
            where pages match ? order by score limit ?
            """, .text(match), .int(Int64(limit))) { row in
            found.append((Self.text(row, 0), -sqlite3_column_double(row, 1)))
        }
        return found
    }

    /// The pages saying what is asked, best first, by their files.
    public func paths(matching query: TextQuery, limit: Int = 200) -> [String] {
        guard let match = query.match else { return [] }
        return pages(matching: match, limit: limit).map(\.path)
    }

    /// A page's lines saying any of what is asked, best first: each its
    /// number in the page's text, and its words with what was asked
    /// between `\u{1}` and `\u{2}`.
    func lines(of path: String, matching match: String, limit: Int) -> [(number: Int, marked: String)] {
        readLock.lock()
        defer { readLock.unlock() }
        guard let reader, let id = rowid(of: path, in: reader) else { return [] }
        var found: [(Int, String)] = []
        Self.each(reader, """
            select rowid, highlight(lines, 0, char(1), char(2)) from lines
            where lines match ? and rowid between ? and ? order by rank limit ?
            """, .text(match), .int(id << Self.lineBits), .int((id + 1) << Self.lineBits - 1), .int(Int64(limit))) { row in
            found.append((Int(sqlite3_column_int64(row, 0) & ((1 << Self.lineBits) - 1)), Self.text(row, 1)))
        }
        return found
    }

    // MARK: SQLite

    private enum Value {
        case int(Int64)
        case text(String)
    }

    private static func open(_ file: URL, flags: Int32) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(file.path, &handle, flags | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 2000)
        return handle
    }

    @discardableResult
    private static func run(_ db: OpaquePointer, _ sql: String, _ values: Value...) -> Bool {
        var ok = true
        each(db, sql, values, ok: &ok) { _ in }
        return ok
    }

    private static func each(_ db: OpaquePointer, _ sql: String, _ values: Value..., row: (OpaquePointer) -> Void) {
        var ok = true
        each(db, sql, values, ok: &ok, row: row)
    }

    private static func each(_ db: OpaquePointer, _ sql: String, _ values: [Value], ok: inout Bool, row: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            ok = false
            return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            switch value {
            case .int(let number): sqlite3_bind_int64(statement, Int32(index + 1), number)
            case .text(let text): sqlite3_bind_text(statement, Int32(index + 1), text, -1, transient)
            }
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { row(statement); continue }
            ok = step == SQLITE_DONE
            return
        }
    }

    private static func value(_ db: OpaquePointer, _ sql: String) -> String? {
        var found: String?
        each(db, sql) { found = text($0, 0) }
        return found
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }

    /// FNV-1a, 64 bits: what a page's file said, known again by it.
    static func hash(_ text: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return Int64(bitPattern: hash)
    }
}

/// What is typed to find pages by what they say, as SQLite's full-text
/// search is asked it: every word, `"words together"`, and `-left out`;
/// as it is being typed, the last word as the start of one.
public struct TextQuery: Equatable, Sendable {
    public var words: [String] = []
    public var phrases: [String] = []
    public var excluded: [String] = []
    /// Whether the last word may be the start of one, still being typed.
    public var prefix = false

    public init(_ text: String, typing: Bool = false) {
        var rest = Substring(text)
        var lastIsWord = false
        while let start = rest.firstIndex(where: { !$0.isWhitespace }) {
            rest = rest[start...]
            var negated = false
            if rest.first == "-", rest.count > 1 { negated = true; rest = rest.dropFirst() }
            if rest.first == "\"" {
                let body = rest.dropFirst()
                let end = body.firstIndex(of: "\"") ?? body.endIndex
                let phrase = Self.terms(String(body[..<end])).joined(separator: " ")
                if !phrase.isEmpty { if negated { excluded.append(phrase) } else { phrases.append(phrase) } }
                rest = end < body.endIndex ? body[body.index(after: end)...] : body[end...]
                lastIsWord = false
            } else {
                let end = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
                let terms = Self.terms(String(rest[..<end]))
                if negated { excluded += terms } else { words += terms }
                rest = rest[end...]
                lastIsWord = !negated && !terms.isEmpty
            }
        }
        // Still being typed: the last word, not yet whole — unless a space
        // after it says it is.
        prefix = typing && lastIsWord && !(text.last?.isWhitespace ?? true)
    }

    /// Nothing to find by.
    public var isEmpty: Bool { words.isEmpty && phrases.isEmpty }

    /// The words of a text, as the index has them.
    static func terms(_ text: String) -> [String] {
        text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map { PageIndex.fold(String($0)) }
    }

    /// Every word and phrase, as SQLite is asked: each quoted, so nothing
    /// typed is taken for its own syntax. Nil when there is nothing to find.
    var match: String? {
        guard !isEmpty else { return nil }
        var parts = words.enumerated().map { index, word in
            "\"\(word)\"" + (prefix && index == words.count - 1 ? "*" : "")
        }
        parts += phrases.map { "\"\($0)\"" }
        return parts.joined(separator: " ") + excluded.map { " NOT \"\($0)\"" }.joined()
    }

    /// Any of the words or phrases: the lines that say some of it.
    var anyMatch: String? {
        guard !isEmpty else { return nil }
        let parts = words.enumerated().map { index, word in
            "\"\(word)\"" + (prefix && index == words.count - 1 ? "*" : "")
        } + phrases.map { "\"\($0)\"" }
        return parts.joined(separator: " OR ")
    }
}
