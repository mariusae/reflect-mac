import Foundation
import ReflectCore

/// Where a graph keeps its pages: a day's in `daily/`, a week's in
/// `weekly/`, every other in `notes/` — named for its title, as Prism names
/// notes. See docs/markdown.md.
public enum PageFolder {
    public static let directories = [GraphPaths.dailyDirectory, GraphPaths.weeklyDirectory, GraphPaths.notesDirectory]

    /// Whether a graph-relative path is a page's file.
    public static func isPage(_ path: String) -> Bool {
        guard path.hasSuffix(".md") else { return false }
        if GraphPaths.day(fromDailyPath: path) != nil || GraphPaths.week(fromWeeklyPath: path) != nil { return true }
        return path.hasPrefix(GraphPaths.notesDirectory + "/")
    }

    /// What a page is, by where it is.
    public enum Kind: Sendable, Equatable {
        case day(Day), week(Week), note
    }

    public static func kind(of path: String) -> Kind {
        if let day = GraphPaths.day(fromDailyPath: path) { return .day(day) }
        if let week = GraphPaths.week(fromWeeklyPath: path) { return .week(week) }
        return .note
    }

    /// The path a new page of this title takes: a date's, its day's; a
    /// week's, its week's; else `notes/<slug>.md`, or the first of `-2`,
    /// `-3`, … that no file has and `taken` does not hold. `own`: a file
    /// being moved, free to be taken again.
    public static func path(for title: String, in root: URL, taken: Set<String> = [], ignoring own: String? = nil) -> String {
        path(for: title, in: root, isTaken: { taken.contains($0) }, ignoring: own)
    }

    /// The same, asking whether each path is taken — by an index's own
    /// table, not a set made of every path.
    public static func path(for title: String, in root: URL, isTaken: (String) -> Bool, ignoring own: String? = nil) -> String {
        if let day = Day(title) { return GraphPaths.dailyPath(for: day) }
        if let week = Week(title) { return GraphPaths.weeklyPath(for: week) }
        let slug = Assets.slug(title)
        let manager = FileManager.default
        for attempt in 1... {
            let path = "\(GraphPaths.notesDirectory)/\(attempt == 1 ? slug : "\(slug)-\(attempt)").md"
            if path == own { return path }
            if !isTaken(path), !manager.fileExists(atPath: root.appendingPathComponent(path).path) { return path }
        }
        fatalError("unreachable")
    }

    /// The title a page goes by when its file gives none: its day, its
    /// week, or its file's name — "Untitled" for a name that is only an id.
    public static func fallbackTitle(for path: String) -> String {
        switch kind(of: path) {
        case .day(let day): return day.description
        case .week(let week): return week.title
        case .note:
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let isID = stem.range(of: #"^[0-7][0-9a-hjkmnp-tv-z]{25}$"#, options: [.regularExpression, .caseInsensitive]) != nil
            return isID ? "Untitled" : stem
        }
    }

    /// Whether a new page at this path is titled by a `# Heading`: a note
    /// is; a day or a week is named by its file.
    public static func titlesByHeading(_ path: String) -> Bool { kind(of: path) == .note }

    /// Whether a page's title is its file's, whatever its text says: a
    /// day's is its date, a week's its week.
    public static func titleIsFixed(_ path: String) -> Bool { kind(of: path) != .note }

    /// Makes the folder a page is to go in.
    public static func prepare(_ path: String, in root: URL) throws {
        let folder = root.appendingPathComponent(path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
}
