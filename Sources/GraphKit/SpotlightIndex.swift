import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// The graph's pages in the system's search — Spotlight on the Mac, the
/// phone's search — each found by its title, its other names and tags, and
/// what it says; chosen there, opened in the app.
///
/// Only what changed is told: what was told last is kept beside the app's
/// other caches, by a hash of each page. A page is known to Spotlight by its
/// graph and its file, so a page of another graph is never opened for it.
public final class SpotlightIndex: @unchecked Sendable {
    /// The graph's: every page of it is told under this.
    public let domain: String
    private let kept: URL
    private var stamps: [String: Int64] = [:]
    private let queue = DispatchQueue(label: "GraphKit.SpotlightIndex", qos: .background)

    /// How many are told at once.
    private static let batch = 200

    public init(root: URL, app: String) {
        domain = Self.domain(of: root)
        kept = TextIndex.cache(for: root, app: app, kind: "Spotlight").appendingPathExtension("json")
        try? FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: kept), let read = try? JSONDecoder().decode([String: Int64].self, from: data) {
            stamps = read
        }
    }

    static func domain(of root: URL) -> String {
        "graph-" + String(format: "%016llx", UInt64(bitPattern: TextIndex.hash(root.standardizedFileURL.path)))
    }

    /// A page as Spotlight is told it.
    public struct Item: Sendable {
        public var path: String
        public var title: String
        /// What it says, plain, its start: shown under its title.
        public var summary: String
        public var keywords: [String]
        public var modified: Date?

        public init(path: String, title: String, summary: String, keywords: [String] = [], modified: Date? = nil) {
            self.path = path
            self.title = title
            self.summary = summary
            self.keywords = keywords
            self.modified = modified
        }

        var stamp: Int64 {
            TextIndex.hash(path + "\u{0}" + title + "\u{0}" + summary + "\u{0}" + keywords.joined(separator: "\n")
                + "\u{0}" + String(modified?.timeIntervalSince1970 ?? 0))
        }
    }

    /// What a page's text says, as Spotlight shows under its title: its
    /// lines plain, run together, the first few hundred letters.
    public static func summary(of text: String, most: Int = 400) -> String {
        var summary = ""
        for line in text.split(separator: "\n") {
            let plain = PageIndex.plainLine(String(line))
            guard !plain.isEmpty else { continue }
            summary += (summary.isEmpty ? "" : " · ") + plain
            if summary.count >= most { break }
        }
        return summary.count > most ? String(summary.prefix(most)) + "…" : summary
    }

    /// Told what the pages are now: those changed since, again; those gone, forgotten.
    public func sync(_ items: [Item]) {
        queue.async { [self] in
            var gone = Set(stamps.keys)
            var changed: [Item] = []
            for item in items {
                gone.remove(item.path)
                if stamps[item.path] != item.stamp { changed.append(item) }
            }
            tell(changed)
            forget(Array(gone))
            keep()
        }
    }

    /// A page as it is now.
    public func put(_ item: Item) {
        queue.async { [self] in
            guard stamps[item.path] != item.stamp else { return }
            tell([item])
            keep()
        }
    }

    /// A page gone.
    public func remove(path: String) {
        queue.async { [self] in
            guard stamps[path] != nil else { return }
            forget([path])
            keep()
        }
    }

    /// Every page of the graph taken out of the system's search.
    public func removeAll() {
        queue.async { [self] in
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
            stamps = [:]
            keep()
        }
    }

    private func tell(_ items: [Item]) {
        for start in stride(from: 0, to: items.count, by: Self.batch) {
            let some = items[start..<min(start + Self.batch, items.count)]
            let searchable = some.map { item in
                let attributes = CSSearchableItemAttributeSet(contentType: .text)
                attributes.title = item.title
                attributes.displayName = item.title
                attributes.contentDescription = item.summary
                attributes.keywords = item.keywords
                attributes.contentModificationDate = item.modified
                return CSSearchableItem(uniqueIdentifier: identifier(of: item.path), domainIdentifier: domain, attributeSet: attributes)
            }
            CSSearchableIndex.default().indexSearchableItems(searchable) { _ in }
            for item in some { stamps[item.path] = item.stamp }
        }
    }

    private func forget(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        for start in stride(from: 0, to: paths.count, by: Self.batch) {
            let some = Array(paths[start..<min(start + Self.batch, paths.count)])
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: some.map(identifier(of:))) { _ in }
        }
        for path in paths { stamps[path] = nil }
    }

    private func keep() {
        if let data = try? JSONEncoder().encode(stamps) { try? data.write(to: kept, options: .atomic) }
    }

    private func identifier(of path: String) -> String { domain + "/" + path }

    // MARK: Opened from the system's search

    /// What the system says when one of its results is chosen.
    public static let activityType = CSSearchableItemActionType

    /// The page a result chosen in the system's search is — if it is one of
    /// this graph's.
    public static func path(of activity: NSUserActivity, in root: URL) -> String? {
        guard activity.activityType == activityType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return nil }
        let prefix = domain(of: root) + "/"
        guard identifier.hasPrefix(prefix) else { return nil }
        return String(identifier.dropFirst(prefix.count))
    }
}
