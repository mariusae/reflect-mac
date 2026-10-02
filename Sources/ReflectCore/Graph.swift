import Foundation

/// A Reflect graph on disk: a folder of Markdown, `daily/` holding a note
/// for each day written in.
public final class Graph: @unchecked Sendable {
    public let root: URL
    /// The repository the graph is kept in, when it is kept in one.
    public let git: Git?

    /// A graph kept in step through a repository, or in none.
    public init(root: URL, git: Git?) {
        self.root = root.standardizedFileURL
        self.git = git
    }

    // MARK: Any note, by its graph-relative path

    public func url(for path: String) -> URL { root.appendingPathComponent(path) }

    public func read(path: String) -> String? {
        guard let data = try? Data(contentsOf: url(for: path)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func exists(path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: path).path)
    }

    public func write(_ text: String, path: String) throws {
        let url = url(for: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: Daily notes

    public func url(for day: Day) -> URL {
        root.appendingPathComponent(GraphPaths.dailyPath(for: day))
    }

    /// The day's note as written, or nil when there is none.
    public func read(_ day: Day) -> String? {
        guard let data = try? Data(contentsOf: url(for: day)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func exists(_ day: Day) -> Bool {
        FileManager.default.fileExists(atPath: url(for: day).path)
    }

    /// Writes the day's note, all at once, so that neither git nor another
    /// app ever reads half of it.
    public func write(_ text: String, for day: Day) throws {
        let url = url(for: day)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// A daily note's file, as its folder lists it.
    public struct DailyFile: Equatable, Sendable {
        public var size: Int
        public var modified: Date
    }

    /// Every day with a note, its size and when it was written — from the
    /// folder's listing alone, no note opened: quick however many there are,
    /// and however slowly each file opens.
    public func dailyNoteFiles() -> [Day: DailyFile] {
        let directory = root.appendingPathComponent(GraphPaths.dailyDirectory)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [:] }
        var files: [Day: DailyFile] = [:]
        for url in urls where url.pathExtension == "md" {
            guard let day = Day(url.deletingPathExtension().lastPathComponent),
                  let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            files[day] = DailyFile(size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
        }
        return files
    }

    /// Roughly how many lines a day's note runs to once wrapped: enough to
    /// guess its height before it is laid out. Reads the note.
    public func lineCount(of day: Day) -> Int? {
        (try? Data(contentsOf: url(for: day))).map(Self.lineCount(of:))
    }

    /// A guess at the same, from the note's size alone.
    public static func lineEstimate(size: Int) -> Int { max(1, size / 50 + 1) }

    static func lineCount(of data: Data) -> Int {
        var lines = 0, width = 0
        for byte in data {
            if byte == 0x0a {
                lines += 1 + width / 90
                width = 0
            } else if byte & 0xc0 != 0x80 {
                width += 1
            }
        }
        return lines + (width > 0 ? 1 + width / 90 : 0)
    }

    /// Every day with a note, and its line count. Reads every note: off
    /// the main thread, or for scripts.
    public func dailyNotes() -> [Day: Int] {
        dailyNoteFiles().keys.reduce(into: [:]) { notes, day in notes[day] = lineCount(of: day) }
    }

    /// The notes carrying sync conflict markers, graph-relative, in order.
    public func notesNeedingReview() -> [String] {
        var paths: [String] = []
        for directory in [GraphPaths.dailyDirectory, GraphPaths.notesDirectory] {
            let folder = root.appendingPathComponent(directory)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted() where name.hasSuffix(".md") {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                      data.range(of: Data("<<<<<<< ".utf8)) != nil,
                      ConflictMarkers.detect(String(decoding: data, as: UTF8.self)) else { continue }
                paths.append("\(directory)/\(name)")
            }
        }
        return paths
    }
}
