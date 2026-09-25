import Foundation

/// A Reflect graph on disk: a folder of Markdown, `daily/` holding a note
/// for each day written in.
public final class Graph: @unchecked Sendable {
    public let root: URL
    /// The repository the graph is kept in, when it is kept in one.
    public let git: Git?

    public init(root: URL) {
        self.root = root.standardizedFileURL
        self.git = Git.open(root)
    }

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

    /// Every day with a note, and roughly how many lines it runs to once
    /// wrapped: enough to guess its height before it is laid out.
    public func dailyNotes() -> [Day: Int] {
        let directory = root.appendingPathComponent(GraphPaths.dailyDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [:] }
        var notes: [Day: Int] = [:]
        for name in names where name.hasSuffix(".md") {
            guard let day = Day(name.dropLast(3)),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { continue }
            var lines = 0, width = 0
            for byte in data {
                if byte == 0x0a {
                    lines += 1 + width / 90
                    width = 0
                } else if byte & 0xc0 != 0x80 {
                    width += 1
                }
            }
            notes[day] = lines + (width > 0 ? 1 + width / 90 : 0)
        }
        return notes
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
