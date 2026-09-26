import AppKit
import ReflectCore

/// Where searches look: the notes' names and text, Reflect's own index of
/// them when it keeps one, and the text in pictures.
struct SearchSources: @unchecked Sendable {
    var index: NoteIndex
    var search: ReflectSearchIndex?
    var pictures: ImageTextIndex?
}

/// One query's search, in stages, each quick, each adding to what the ones
/// before found: a day the query names and the notes it names first, then
/// the notes with its words in them, then the pictures. What is found so
/// far is told after each, so it can be shown while the rest is looked for.
final class StagedSearch: @unchecked Sendable {
    typealias Item = OpenQuickly.Item

    let query: String
    private let sources: SearchSources
    private var items: [Item] = []
    private var seen = Set<String>()
    /// Whether a note already has the query's name; if not, the last row
    /// offers to make one.
    private var exists = false

    init(query: String, sources: SearchSources) {
        self.query = query.trimmingCharacters(in: .whitespaces)
        self.sources = sources
    }

    /// Runs the stages in turn, telling what is found after each — the last
    /// time with `done` — and stopping as soon as the search is no longer
    /// wanted.
    func run(isCurrent: () -> Bool, deliver: (_ items: [Item], _ done: Bool) -> Void) {
        let stages = query.isEmpty ? [recent] : [named, written, pictured]
        for (number, stage) in stages.enumerated() {
            guard isCurrent() else { return }
            stage()
            guard isCurrent() else { return }
            deliver(shown, number == stages.count - 1)
        }
    }

    /// The first stage alone: what Return must have, if it comes before
    /// anything else has.
    func first() -> [Item] {
        (query.isEmpty ? recent : named)()
        return shown
    }

    private var shown: [Item] {
        guard !query.isEmpty, !exists else { return items }
        // Last, so Return never makes a note by chance; ⌥Return makes one
        // from whatever is typed.
        return items + [Item(target: .create(query), title: "New Note “\(query)”", detail: OpenQuickly.plain("⌥↩ Make a note with this title"),
                             symbol: "square.and.pencil", name: query)]
    }

    private func add(_ item: Item, path: String) {
        guard seen.insert(path).inserted else { return }
        var item = item
        switch item.target {
        case .day(let day): item.name = day.description
        case .note(let path): item.name = sources.index.entry(path)?.title ?? item.title
        case .create(let title): item.name = title
        }
        items.append(item)
    }

    private func title(for path: String, fallback: String) -> (title: String, isDay: Bool) {
        let entry = sources.index.entry(path)
        if let day = entry?.day ?? GraphPaths.day(fromDailyPath: path) { return (OpenQuickly.dayTitle(day), true) }
        return (entry?.title ?? fallback, false)
    }

    // MARK: Stages

    /// Nothing typed: today, and the notes last written.
    private func recent() {
        let today = Day.today
        add(Item(target: .day(today), title: "Today", detail: OpenQuickly.plain(OpenQuickly.dayTitle(today)), symbol: "calendar"),
            path: GraphPaths.dailyPath(for: today))
        for match in sources.index.matches("", limit: 12) {
            add(Item(target: .note(match.entry.path), title: match.entry.title,
                     detail: OpenQuickly.plain(OpenQuickly.relative(match.entry.modified)), symbol: "doc.text"), path: match.entry.path)
        }
    }

    /// A day the query names, and the notes whose names match it.
    private func named() {
        if let day = OpenQuickly.day(from: query) {
            add(Item(target: .day(day), title: OpenQuickly.dayTitle(day),
                     detail: OpenQuickly.plain(day == .today ? "Today" : day.description), symbol: "calendar"),
                path: GraphPaths.dailyPath(for: day))
        }
        let named = sources.index.matches(query, limit: 20)
        for match in named {
            let detail = match.alias.map { OpenQuickly.plain("also “\($0)”") } ?? OpenQuickly.plain(OpenQuickly.relative(match.entry.modified))
            add(Item(target: .note(match.entry.path), title: match.entry.title, detail: detail, symbol: "doc.text"), path: match.entry.path)
        }
        let key = NoteIndex.foldKey(query)
        exists = named.contains { NoteIndex.foldKey($0.entry.title) == key || $0.entry.aliases.contains { NoteIndex.foldKey($0) == key } }
    }

    /// The notes with the query's words in them: from Reflect's index when
    /// there is one, else by reading them.
    private func written() {
        if let search = sources.search {
            for hit in search.search(query, limit: 25) {
                let (title, isDay) = title(for: hit.path, fallback: hit.title)
                add(Item(target: OpenQuickly.target(for: hit.path), title: title, detail: OpenQuickly.highlighted(hit.snippet),
                         symbol: isDay ? "calendar" : "text.magnifyingglass",
                         found: .words(OpenQuickly.marked(hit.snippet) + OpenQuickly.words(query))), path: hit.path)
            }
        } else {
            for hit in sources.index.containing(query, limit: 25) {
                let (title, isDay) = title(for: hit.path, fallback: hit.path)
                add(Item(target: OpenQuickly.target(for: hit.path), title: title, detail: OpenQuickly.plain(hit.snippet),
                         symbol: isDay ? "calendar" : "text.magnifyingglass", found: .words(OpenQuickly.words(query))), path: hit.path)
            }
        }
    }

    /// The notes showing pictures with the query's words in them.
    private func pictured() {
        for hit in sources.pictures?.search(query) ?? [] {
            for path in sources.index.notes(showing: hit.path).prefix(3) {
                let (title, _) = title(for: path, fallback: path)
                add(Item(target: OpenQuickly.target(for: path), title: title, detail: OpenQuickly.highlighted(hit.snippet), symbol: "photo",
                         found: .picture(hit.path, words: OpenQuickly.marked(hit.snippet))), path: path)
            }
        }
    }
}

/// Runs searches off the main thread, one after another, and tells what
/// each finds on the main thread as it finds it — only while it is the
/// latest: a search overtaken by typing is dropped between stages.
@MainActor
final class SearchRunner {
    private static let queue = DispatchQueue(label: "com.mariusae.reflect.search", qos: .userInitiated)
    private let latest = Latest()
    private(set) var sources: SearchSources
    /// The query whose results are showing, and whether they are complete.
    private(set) var shownQuery: String?
    private(set) var complete = false

    init(sources: SearchSources) {
        self.sources = sources
    }

    /// Searches for a query, telling what is found as it is found.
    func run(_ query: String, deliver: @escaping @MainActor (_ items: [OpenQuickly.Item], _ done: Bool) -> Void) {
        let generation = latest.next()
        let latest = latest
        let staged = StagedSearch(query: query, sources: sources)
        Self.queue.async {
            staged.run(isCurrent: { latest.is(generation) }) { items, done in
                let found = Found(items: items)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard latest.is(generation) else { return }
                        self.shownQuery = staged.query
                        self.complete = done
                        deliver(found.items, done)
                    }
                }
            }
        }
    }

    /// Stops telling of any search under way.
    func cancel() {
        _ = latest.next()
    }

    /// A lock-guarded count of searches begun.
    private final class Latest: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int { lock.withLock { value += 1; return value } }
        func `is`(_ generation: Int) -> Bool { lock.withLock { value == generation } }
    }

    private struct Found: @unchecked Sendable {
        var items: [OpenQuickly.Item]
    }
}
