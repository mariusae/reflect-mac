import Foundation
import ReflectCore

/// The timeline: every day there is a note for, and today, in order —
/// each week's note before the days it covers.
public enum Timeline {
    /// The day a note is placed at in the timeline, when it has a place there.
    public static func day(of ref: NoteRef) -> Day? {
        ref.day ?? GraphPaths.week(fromWeeklyPath: ref.path)?.monday
    }

    /// Every entry of the timeline, oldest first, `including` one besides.
    public static func entries(graph: Graph, index: NoteIndex, including ref: NoteRef? = nil) -> [NoteRef] {
        var entries: [(Day, Int, NoteRef)] = graph.dailyNoteFiles().keys.map { ($0, 1, .day($0)) }
        var refs = Set(entries.map(\.2))
        func add(_ ref: NoteRef) {
            guard !refs.contains(ref), let day = day(of: ref) else { return }
            refs.insert(ref)
            entries.append((day, ref.day == nil ? 0 : 1, ref))
        }
        add(.day(.today))
        for note in index.all where GraphPaths.week(fromWeeklyPath: note.path) != nil { add(.note(note.path)) }
        if let ref { add(ref) }
        entries.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        return entries.map(\.2)
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

    /// The notes with all the words — regardless of case and accents — the
    /// most lately changed first, each with the rows they are in. Reads
    /// every note: call it off the main thread.
    public static func find(_ words: [String], in index: NoteIndex, limit: Int = 60) -> [Found] {
        guard !words.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var found: [Found] = []
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
