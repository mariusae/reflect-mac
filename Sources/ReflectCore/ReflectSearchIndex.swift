import Foundation
import SQLite3

/// Reflect's own search index — `.reflect/index.sqlite`, kept by the Reflect
/// app as it runs — read for finding words in notes: its full-text table is
/// ranked, and knows the notes' text better than a scan.
///
/// It is Reflect's, not this app's: it is only ever opened read-only, and
/// when it is not there — Reflect has never run on this graph — nothing is
/// asked of it.
public final class ReflectSearchIndex: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSLock()

    public init?(root: URL) {
        let file = root.appendingPathComponent(".reflect/index.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              Self.hasSearchTable(handle) else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 200)
        database = handle
    }

    deinit { sqlite3_close(database) }

    private static func hasSearchTable(_ handle: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "select 1 from sqlite_master where name = 'search_fts'", -1, &statement, nil) == SQLITE_OK
        else { return false }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    public struct Hit: Sendable {
        public var path: String
        public var title: String
        /// The text around the words found, with them between `\u{1}` and
        /// `\u{2}`.
        public var snippet: String
    }

    /// Notes with every word of a query in them — the last word as the start
    /// of one, since it may not be typed out yet — best first.
    public func search(_ query: String, limit: Int = 30) -> [Hit] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { word in
            word.filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" || $0 == "_" }
        }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        // Each word quoted, so nothing typed is taken for FTS syntax.
        let match = words.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: " ") + "*"
        let sql = """
            select path, title, snippet(search_fts, 2, char(1), char(2), '…', 14)
            from search_fts where search_fts match ? order by bm25(search_fts, 0, 10, 1) limit ?
            """
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, match, -1, transient)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var hits: [Hit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
            hits.append(Hit(path: text(0), title: text(1), snippet: text(2)))
        }
        return hits
    }
}

/// New notes, made as Reflect makes them: `notes/<slug of the title>.md`,
/// holding a frontmatter `id` — a lowercase ULID, the note's lasting
/// identity — and the title as its first heading.
public enum NoteCreation {
    /// `---\nid: 01h…\n---\n# Title\n`.
    public static func source(title: String, id: String = ulid()) -> String {
        "---\nid: \(id)\n---\n# \(title.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    /// Writes a blank note — an id, and a title to type — under a name held
    /// for it until it has one: its id. Its title, once settled, names it.
    public static func createBlank(in root: URL) throws -> String {
        let folder = root.appendingPathComponent(GraphPaths.notesDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = ulid()
        let path = "\(GraphPaths.notesDirectory)/\(id).md"
        let descriptor = open(root.appendingPathComponent(path).path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteFileExists) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data("---\nid: \(id)\n---\n# \n".utf8))
        try handle.close()
        return path
    }

    /// Writes a new note for a title at the first free path, and returns it.
    public static func create(title: String, in root: URL) throws -> String {
        let folder = root.appendingPathComponent(GraphPaths.notesDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let slug = Assets.slug(title)
        for attempt in 1...1000 {
            let name = attempt == 1 ? "\(slug).md" : "\(slug)-\(attempt).md"
            let url = folder.appendingPathComponent(name)
            let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: Data(source(title: title).utf8))
            try handle.close()
            return "\(GraphPaths.notesDirectory)/\(name)"
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// A ULID in lower case: 48 bits of milliseconds, then 80 random bits,
    /// in Crockford's base 32.
    public static func ulid(at date: Date = Date()) -> String {
        let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
        var time = UInt64(date.timeIntervalSince1970 * 1000)
        var text = [Character](repeating: "0", count: 26)
        for index in stride(from: 9, through: 0, by: -1) {
            text[index] = alphabet[Int(time % 32)]
            time /= 32
        }
        var generator = SystemRandomNumberGenerator()
        for index in 10..<26 { text[index] = alphabet[Int(generator.next() % 32)] }
        return String(text)
    }
}
