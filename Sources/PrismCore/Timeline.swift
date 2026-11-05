import Foundation
import GraphKit
import ReflectCore

/// The timeline: every day there is a note for, and today, in order —
/// each week's note before the days it covers — with the days between
/// that have none standing as a gap, opened a few days at a time.
public enum Timeline {
    /// The day a note is placed at in the timeline, when it has a place there.
    public static func day(of ref: NoteRef) -> Day? {
        if let gap = ref.gap { return gap.from }
        return ref.day ?? GraphPaths.week(fromWeeklyPath: ref.path)?.monday
    }

    /// How many of a gap's days opening it shows.
    public static let revealCount = 7

    /// Every entry of the timeline, oldest first, `including` one besides:
    /// the notes there are, the days `revealed` though they have none yet,
    /// and a gap for each run of days between them with neither.
    public static func entries(graph: Graph, index: NoteIndex, including ref: NoteRef? = nil, revealed: Set<Day> = []) -> [NoteRef] {
        var weekly = index.all.compactMap { note in GraphPaths.week(fromWeeklyPath: note.path).map { (note.path, $0) } }
        // This week's note, there to write in before there is one, as today's is.
        let thisWeek = GraphPaths.weeklyPath(for: .current)
        if !weekly.contains(where: { $0.0 == thisWeek }) { weekly.append((thisWeek, .current)) }
        return entries(days: Set(graph.dailyNoteFiles().keys), weeks: weekly.compactMap { path, week in week.monday.map { (path, $0) } },
                       including: ref, revealed: revealed)
    }

    /// The same, from the days with notes and each week's note and Monday.
    public static func entries(days: Set<Day>, weeks: [(path: String, monday: Day)], today: Day = .today,
                               including ref: NoteRef? = nil, revealed: Set<Day> = []) -> [NoteRef] {
        var days = days.union(revealed)
        days.insert(today)
        if let day = ref?.day { days.insert(day) }
        // Rank: a week's note before its Monday; a gap before the days after it.
        var entries: [(Day, Int, NoteRef)] = days.map { ($0, 2, .day($0)) }
        var seen = Set(entries.map(\.2))
        for (path, monday) in weeks where seen.insert(.note(path)).inserted { entries.append((monday, 0, .note(path))) }
        if let ref, ref.day == nil, ref.gap == nil, let day = day(of: ref), seen.insert(ref).inserted { entries.append((day, 0, ref)) }
        // The days between, a gap a run — broken at a week's note, so the
        // week stays before its Monday.
        let mondays = Set(weeks.map(\.monday))
        let sorted = days.sorted()
        for (earlier, later) in zip(sorted, sorted.dropFirst()) {
            var from = earlier.adding(1)
            guard from < later else { continue }
            var day = from
            while day < later {
                let next = day.adding(1)
                if mondays.contains(next) || next == later {
                    entries.append((from, 1, .gap(from: from, to: day)))
                    from = next
                }
                day = next
            }
        }
        entries.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        return entries.map(\.2)
    }

    /// The days opening a gap shows: its last few, next to the notes after it.
    public static func reveal(_ gap: TimelineGap, count: Int = revealCount) -> [Day] {
        var days: [Day] = []
        var day = gap.to
        while day >= gap.from, days.count < count {
            days.append(day)
            day = day.adding(-1)
        }
        return days
    }
}

/// Days in the timeline with no note, between two that have one.
public struct TimelineGap: Hashable, Sendable {
    public var from: Day
    public var to: Day

    public init(from: Day, to: Day) {
        self.from = from
        self.to = to
    }

    /// How many days it stands for.
    public var count: Int {
        guard let a = from.date, let b = to.date else { return 1 }
        return (Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0) + 1
    }
}

extension NoteRef {
    static let gapPrefix = "\u{0}gap/"

    /// A timeline's gap, where a note would be: no file has its path.
    public static func gap(from: Day, to: Day) -> NoteRef { NoteRef(path: "\(gapPrefix)\(from)/\(to)") }

    /// The gap it stands for, when it is one.
    public var gap: TimelineGap? {
        guard path.hasPrefix(Self.gapPrefix) else { return nil }
        let parts = path.dropFirst(Self.gapPrefix.count).split(separator: "/")
        guard parts.count == 2, let from = Day(parts[0]), let to = Day(parts[1]) else { return nil }
        return TimelineGap(from: from, to: to)
    }
}

/// Looking for words in every note.
public enum NoteSearch {
    /// A query's words, as looked for.
    public static func words(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// A note found: where in it the words are, and whether what is typed
    /// there can go back to it.
    public struct Found: Sendable {
        public var path: String
        public var slices: [NoteSlice]
        public var editable: Bool
    }

    /// The notes with all the words — regardless of case and accents — each
    /// with the rows they are in: in the order `ranked` gives, best first,
    /// when the words on disk are ready; else the most lately changed first,
    /// every note read — call it off the main thread.
    public static func find(_ words: [String], in index: NoteIndex, ranked: [String]? = nil, limit: Int = 60) -> [Found] {
        guard !words.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var found: [Found] = []
        if let ranked {
            for path in ranked where !path.hasPrefix("templates/") {
                guard let text = index.body(path) else { continue }
                let slices = NoteSlice.slices(finding: words, path: path, in: text)
                guard !slices.isEmpty else { continue }
                found.append(Found(path: path, slices: slices, editable: OutlineMarkdown.roundTrips(text)))
                if found.count == limit { break }
            }
            return found
        }
        for entry in index.all.sorted(by: { $0.modified > $1.modified }) where !entry.path.hasPrefix("templates/") {
            guard let text = index.body(entry.path),
                  words.allSatisfy({ text.range(of: $0, options: options) != nil }) else { continue }
            let slices = NoteSlice.slices(finding: words, path: entry.path, in: text)
            guard !slices.isEmpty else { continue }
            found.append(Found(path: entry.path, slices: slices, editable: OutlineMarkdown.roundTrips(text)))
            if found.count == limit { break }
        }
        return found
    }
}

/// The notes' words on disk, ranked — in Prism's caches, kept as the notes
/// are read again — for finding notes by what they say, best first.
public final class NoteWords: @unchecked Sendable {
    private let index: TextIndex

    public init?(root: URL) {
        guard let index = TextIndex.shared(at: TextIndex.location(for: root, app: "Prism")) else { return nil }
        self.index = index
    }

    /// Made to say what the notes say now — and what their pictures say,
    /// as read so far — and kept so as each is read again. Reads every
    /// note's text the index holds: call it off the main thread.
    public func keep(_ notes: NoteIndex, pictures: ImageTextIndex? = nil, spotlight: SpotlightIndex? = nil) {
        self.notes = notes
        self.pictures = pictures
        resync()
        // The system's search told of the notes too — never of a private one.
        spotlight?.sync(notes.all.compactMap { entry in notes.body(entry.path).flatMap { Self.item(entry, $0) } })
        let index = self.index
        notes.onRefresh = { path, entry, text in
            if let entry, let text { index.put(Self.source(entry, text, pictures: pictures)) } else { index.remove(path: path) }
            if let entry, let text, let item = Self.item(entry, text) { spotlight?.put(item) } else { spotlight?.remove(path: path) }
        }
    }

    private static func item(_ entry: NoteEntry, _ text: String) -> SpotlightIndex.Item? {
        guard !entry.isPrivate else { return nil }
        return SpotlightIndex.Item(path: entry.path, title: entry.title, summary: SpotlightIndex.summary(of: body(of: text)),
                                   keywords: entry.tags + entry.aliases, modified: entry.modified)
    }

    /// More pictures read: the notes showing them kept again, with it.
    public func picturesRead() { resync() }

    private weak var notes: NoteIndex?
    private var pictures: ImageTextIndex?

    private func resync() {
        guard let notes else { return }
        let pictures = pictures
        index.sync(sources: notes.all.compactMap { entry in notes.body(entry.path).map { Self.source(entry, $0, pictures: pictures) } })
    }

    /// Where Prism keeps what a graph's pictures say.
    public static func picturesCache(for root: URL) -> URL {
        TextIndex.cache(for: root, app: "Prism", kind: "Pictures")
    }

    /// The notes about what is typed, by meaning — words like its words —
    /// the nearest first.
    public func about(_ query: String, limit: Int = 6) -> [String] {
        guard index.isReady else { return [] }
        return index.meaning(of: query, limit: limit).map(\.path)
    }

    /// The notes saying what is typed, best first; nil till the words are ready.
    public func paths(_ query: String, limit: Int = 200) -> [String]? {
        guard index.isReady else { return nil }
        return index.paths(matching: TextQuery(query), limit: limit)
    }

    private static func source(_ entry: NoteEntry, _ text: String, pictures: ImageTextIndex?) -> TextIndex.Source {
        let shown = pictures.map { pictures in
            NoteIndex.assets(in: text).sorted().compactMap { path in pictures.text(path).map { (path: path, text: $0) } }
        } ?? []
        return TextIndex.Source(path: entry.path, title: entry.title, names: entry.aliases, text: body(of: text), pictures: shown)
    }

    /// A note's text without its frontmatter.
    static func body(of source: String) -> String {
        guard source.hasPrefix("---\n") || source.hasPrefix("---\r\n"),
              let close = source.range(of: "\n---", range: source.index(source.startIndex, offsetBy: 3)..<source.endIndex)
        else { return source }
        let rest = source[close.upperBound...]
        return String(rest.drop { $0 != "\n" }.dropFirst())
    }
}
