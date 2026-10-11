import Foundation
import SQLite3
import ReflectCore

/// When each note last changed, by the graph's history: the time of the
/// last commit to change it — not its file's, which a clone or a sync sets
/// to when it wrote the file. Kept in a small SQLite file outside the graph,
/// with the commit it was kept up to, so that only new commits are read
/// after the first time.
public final class ChangeHistory: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    /// The store for a graph: one file each, under `folder`.
    public init?(graph root: URL, in folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(root.standardizedFileURL.path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }, radix: 16)
        guard sqlite3_open(folder.appendingPathComponent("changes-\(name).sqlite").path, &db) == SQLITE_OK else { return nil }
        exec("CREATE TABLE IF NOT EXISTS change (path TEXT PRIMARY KEY, time REAL NOT NULL)")
        exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    }

    deinit { sqlite3_close(db) }

    /// Brought up to HEAD — the commits since the last time read, or, when
    /// history was rewritten since, all of it again — and every path's time
    /// given back. Reads the repository: call it off the main thread.
    public func update(from git: LibGit2Backend) -> [String: Date] {
        lock.lock()
        defer { lock.unlock() }
        var since = meta("head")
        if let known = since, let head = git.head(), known != head, !git.isAncestor(known, of: head) { since = nil }
        if since == nil { exec("DELETE FROM change") }
        if since == nil || since != git.head() {
            let (head, times) = git.lastChanges(since: since)
            exec("BEGIN")
            var statement: OpaquePointer?
            // Newer than what was kept: the walk only goes back to it.
            sqlite3_prepare_v2(db, "INSERT INTO change (path, time) VALUES (?, ?) ON CONFLICT(path) DO UPDATE SET time = max(time, excluded.time)",
                               -1, &statement, nil)
            for (path, time) in times {
                sqlite3_reset(statement)
                sqlite3_bind_text(statement, 1, path, -1, Self.transient)
                sqlite3_bind_double(statement, 2, time.timeIntervalSince1970)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            if let head { setMeta("head", head) }
            exec("COMMIT")
        }
        return all()
    }

    /// Every path's last change, as kept.
    public func all() -> [String: Date] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT path, time FROM change", -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var times: [String: Date] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = sqlite3_column_text(statement, 0) else { continue }
            times[String(cString: path)] = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        }
        return times
    }

    // MARK: SQLite

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func meta(_ key: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private func setMeta(_ key: String, _ value: String) {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           -1, &statement, nil)
        sqlite3_bind_text(statement, 1, key, -1, Self.transient)
        sqlite3_bind_text(statement, 2, value, -1, Self.transient)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }
}

extension ChangeHistory {
    /// Where the stores are: the app's own support folder, out of the graph.
    public static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Prism").appendingPathComponent("History")
    }

    /// The index's notes given their last changes by the graph's history,
    /// brought up to HEAD first. Nothing, for a graph that is no repository.
    /// Reads the repository: call it off the main thread.
    public static func apply(to index: NoteIndex) {
        guard let git = LibGit2Backend(root: index.root), let store = ChangeHistory(graph: index.root, in: folder) else { return }
        let times = store.update(from: git)
        index.useHistory(times, uncommitted: git.uncommittedPaths())
    }
}
