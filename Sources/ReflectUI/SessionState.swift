import AppKit
import ReflectCore

/// Where the app was left, so it opens there again: for each graph, the
/// day at the top of the window and how far into it, the caret or the
/// selection and the day it was in, the rows folded in each note, where
/// each note was last read and written in, and whether the console was open.
///
/// This is how this Mac shows the notes, not what they say, so it is kept
/// here rather than in the graph: in
/// `~/Library/Application Support/Reflect Mac/State.json`.
@MainActor
package final class SessionState {
    package static let shared = SessionState()

    package struct Place: Codable, Equatable {
        package var day: String
        /// Points from the top of the day to the top of the window.
        package var offset: Double

        package init(day: String, offset: Double) {
            self.day = day
            self.offset = offset
        }
    }

    package struct Focus: Codable, Equatable {
        package var day: String
        package var location: Int
        package var length: Int
        /// Rows selected as rows: the one the selection started from, and
        /// the one it reached.
        package var rows: [Int]?

        package init(day: String, location: Int, length: Int, rows: [Int]?) {
            self.day = day
            self.location = location
            self.length = length
            self.rows = rows
        }
    }

    /// Where a note was left: its caret or selection, and how far down it
    /// was scrolled where it is shown on its own.
    package struct NotePlace: Codable, Equatable {
        package var location: Int
        package var length: Int
        package var offset: Double?
    }

    /// How a PDF is shown under its link: the page it is at, and the size
    /// it was given, when it was given one.
    package struct PDFPlace: Codable, Equatable {
        package var page = 0
        package var width: Double?
        package var height: Double?
    }

    package struct PictureSize: Codable, Equatable {
        package var width: Double
        package var height: Double
    }

    /// The row a note was focused on: where it was among the note's rows,
    /// and its words and the words of those it was in, to find it again
    /// should the note have changed.
    package struct FocusMark: Codable, Equatable {
        package var index: Int
        package var text: String
        package var path: [String]
    }

    /// A column of a window that arranges notes in columns: what it shows —
    /// the timeline, a note, or what links to a note — and where it was
    /// scrolled to, as the note at its top and how far into it.
    package struct ColumnPlace: Codable, Equatable {
        package var kind: String
        package var note: String?
        package var top: String?
        package var offset: Double
        /// The sheets beneath it, in a column that stacks them: the bottom first.
        package var beneath: [ColumnPlace]?

        package init(kind: String, note: String?, top: String?, offset: Double) {
            self.kind = kind
            self.note = note
            self.top = top
            self.offset = offset
        }
    }

    package struct Graph: Codable {
        package var top: Place?
        package var focus: Focus?
        package var folds: [String: [OutlineFolds.Mark]] = [:]
        package var places: [String: NotePlace]?
        /// By the PDF's source in the graph.
        package var pdfs: [String: PDFPlace]?
        /// The picture each carousel shows, by its first picture's source.
        package var carousels: [String: Int]?
        /// The row each note is focused on, by the note's key.
        package var focuses: [String: FocusMark]?
        /// The size each picture, or carousel, was given here, by `ImageBox.sizeKey`.
        package var pictureSizes: [String: PictureSize]?
        package var consoleOpen: Bool?
        /// The note open in the window's main place, when not the timeline.
        package var mainNote: String?
        /// The note in the split view.
        package var splitNote: String?
        /// What the sidebar searches for.
        package var search: String?
        /// The notes open in windows of their own.
        package var noteWindows: [String]?
        /// The columns of a window that has them, left to right; the one the
        /// keyboard was in, and the note it was in there.
        package var columns: [ColumnPlace]?
        package var activeColumn: Int?
        package var keyNote: String?
        /// For each note, the notes linking to it whose links are folded away.
        package var backlinkFolds: [String: [String]]?
    }

    private var graphs: [String: Graph] = [:]
    private let url: URL
    private var pending: DispatchWorkItem?

    /// The app's own folder in Application Support, where its state is
    /// kept: each app that shows the notes keeps its own. Set before the
    /// state is first used.
    package static var folder = "Reflect Mac"

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.folder)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        // A scripted run keeps its own: it must not write over the state of
        // the app someone is using, nor have that written over its own.
        let environment = ProcessInfo.processInfo.environment
        let scripted = environment["REFLECT_SCRIPT"] != nil || environment["PRISM_SNAP"] != nil
        url = support.appendingPathComponent(scripted ? "State (scripts).json" : "State.json")
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode([String: Graph].self, from: data) {
            graphs = stored
        }
    }

    private static func key(_ root: URL) -> String { root.standardizedFileURL.path }

    package func graph(_ root: URL) -> Graph { graphs[Self.key(root)] ?? Graph() }

    package func update(_ root: URL, _ change: (inout Graph) -> Void) {
        var graph = graph(root)
        change(&graph)
        graphs[Self.key(root)] = graph
        scheduleWrite()
    }

    package func folds(_ root: URL, _ note: NoteRef) -> [OutlineFolds.Mark] {
        graph(root).folds[note.stateKey] ?? []
    }

    /// Notes a note's folds, writing only when they changed.
    /// A note's folds, and its place as the note open, kept through a move.
    package func moved(_ root: URL, from old: NoteRef, to new: NoteRef) {
        update(root) { state in
            if let marks = state.folds.removeValue(forKey: old.stateKey) { state.folds[new.stateKey] = marks }
            if let place = state.places?.removeValue(forKey: old.stateKey) { state.places?[new.stateKey] = place }
            if let mark = state.focuses?.removeValue(forKey: old.stateKey) { state.focuses?[new.stateKey] = mark }
            if state.mainNote == old.path { state.mainNote = new.path }
            if state.splitNote == old.path { state.splitNote = new.path }
            state.noteWindows = state.noteWindows?.map { $0 == old.path ? new.path : $0 }
            state.columns = state.columns?.map { column in
                var column = column
                if column.note == old.path { column.note = new.path }
                if column.top == old.path { column.top = new.path }
                return column
            }
            if state.keyNote == old.path { state.keyNote = new.path }
        }
    }

    package func place(_ root: URL, _ note: NoteRef) -> NotePlace? {
        graph(root).places?[note.stateKey]
    }

    /// Notes where a note's caret is, keeping how far down it was scrolled.
    package func setSelection(_ root: URL, _ note: NoteRef, _ range: NSRange) {
        var place = place(root, note) ?? NotePlace(location: 0, length: 0)
        guard place.location != range.location || place.length != range.length else { return }
        place.location = range.location
        place.length = range.length
        update(root) { $0.places = ($0.places ?? [:]).merging([note.stateKey: place]) { $1 } }
    }

    /// Notes how far down a note shown on its own is scrolled.
    package func setOffset(_ root: URL, _ note: NoteRef, _ offset: Double) {
        var place = place(root, note) ?? NotePlace(location: 0, length: 0)
        guard place.offset != offset else { return }
        place.offset = offset
        update(root) { $0.places = ($0.places ?? [:]).merging([note.stateKey: place]) { $1 } }
    }

    package func pdf(_ root: URL, _ source: String) -> PDFPlace? {
        graph(root).pdfs?[source]
    }

    package func setPDF(_ root: URL, _ source: String, _ change: (inout PDFPlace) -> Void) {
        var place = pdf(root, source) ?? PDFPlace()
        change(&place)
        guard place != pdf(root, source) else { return }
        update(root) { $0.pdfs = ($0.pdfs ?? [:]).merging([source: place]) { $1 } }
    }

    package func focus(_ root: URL, _ note: NoteRef) -> FocusMark? {
        graph(root).focuses?[note.stateKey]
    }

    package func setFocus(_ root: URL, _ note: NoteRef, _ mark: FocusMark?) {
        guard focus(root, note) != mark else { return }
        update(root) { state in
            var focuses = state.focuses ?? [:]
            focuses[note.stateKey] = mark
            state.focuses = focuses.isEmpty ? nil : focuses
        }
    }

    package func carouselIndex(_ root: URL, _ first: String) -> Int {
        graph(root).carousels?[first] ?? 0
    }

    package func setCarouselIndex(_ root: URL, _ first: String, _ index: Int) {
        guard carouselIndex(root, first) != index else { return }
        update(root) { $0.carousels = ($0.carousels ?? [:]).merging([first: index]) { $1 } }
    }

    package func pictureSize(_ root: URL, _ key: String) -> CGSize? {
        graph(root).pictureSizes?[key].map { CGSize(width: $0.width, height: $0.height) }
    }

    /// Keeps the size a picture was given; nil forgets it, for its own.
    package func setPictureSize(_ root: URL, _ key: String, _ size: CGSize?) {
        let value = size.map { PictureSize(width: Double($0.width), height: Double($0.height)) }
        guard graph(root).pictureSizes?[key] != value else { return }
        update(root) { state in
            var sizes = state.pictureSizes ?? [:]
            sizes[key] = value
            state.pictureSizes = sizes.isEmpty ? nil : sizes
        }
    }

    /// Whether a note's links to another are folded away among its backlinks.
    package func backlinkFolded(_ root: URL, to target: String, from source: String) -> Bool {
        graph(root).backlinkFolds?[target]?.contains(source) ?? false
    }

    package func setBacklinkFolded(_ root: URL, to target: String, from source: String, _ folded: Bool) {
        update(root) { state in
            var folds = state.backlinkFolds ?? [:]
            var sources = Set(folds[target] ?? [])
            if folded { sources.insert(source) } else { sources.remove(source) }
            folds[target] = sources.isEmpty ? nil : sources.sorted()
            state.backlinkFolds = folds.isEmpty ? nil : folds
        }
    }

    package func setFolds(_ root: URL, _ note: NoteRef, _ marks: [OutlineFolds.Mark]) {
        guard folds(root, note) != marks else { return }
        update(root) { $0.folds[note.stateKey] = marks.isEmpty ? nil : marks }
    }

    // MARK: Writing

    private func scheduleWrite() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.writeNow() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    package func writeNow() {
        pending?.cancel()
        pending = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(graphs) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
