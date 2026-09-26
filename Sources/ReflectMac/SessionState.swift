import AppKit
import ReflectCore

/// Where the app was left, so it opens there again: for each graph, the
/// day at the top of the window and how far into it, the caret or the
/// selection and the day it was in, the rows folded in each note, and
/// whether the console was open.
///
/// This is how this Mac shows the notes, not what they say, so it is kept
/// here rather than in the graph: in
/// `~/Library/Application Support/Reflect Mac/State.json`.
@MainActor
final class SessionState {
    static let shared = SessionState()

    struct Place: Codable, Equatable {
        var day: String
        /// Points from the top of the day to the top of the window.
        var offset: Double
    }

    struct Focus: Codable, Equatable {
        var day: String
        var location: Int
        var length: Int
        /// Rows selected as rows: the one the selection started from, and
        /// the one it reached.
        var rows: [Int]?
    }

    struct Graph: Codable {
        var top: Place?
        var focus: Focus?
        var folds: [String: [OutlineFolds.Mark]] = [:]
        var consoleOpen: Bool?
        /// The note open in the window's main place, when not the timeline.
        var mainNote: String?
        /// The note in the split view.
        var splitNote: String?
        /// What the sidebar searches for.
        var search: String?
    }

    private var graphs: [String: Graph] = [:]
    private let url: URL
    private var pending: DispatchWorkItem?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reflect Mac")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        url = support.appendingPathComponent("State.json")
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode([String: Graph].self, from: data) {
            graphs = stored
        }
    }

    private static func key(_ root: URL) -> String { root.standardizedFileURL.path }

    func graph(_ root: URL) -> Graph { graphs[Self.key(root)] ?? Graph() }

    func update(_ root: URL, _ change: (inout Graph) -> Void) {
        var graph = graph(root)
        change(&graph)
        graphs[Self.key(root)] = graph
        scheduleWrite()
    }

    func folds(_ root: URL, _ note: NoteRef) -> [OutlineFolds.Mark] {
        graph(root).folds[note.stateKey] ?? []
    }

    /// Notes a note's folds, writing only when they changed.
    /// A note's folds, and its place as the note open, kept through a move.
    func moved(_ root: URL, from old: NoteRef, to new: NoteRef) {
        update(root) { state in
            if let marks = state.folds.removeValue(forKey: old.stateKey) { state.folds[new.stateKey] = marks }
            if state.mainNote == old.path { state.mainNote = new.path }
            if state.splitNote == old.path { state.splitNote = new.path }
        }
    }

    func setFolds(_ root: URL, _ note: NoteRef, _ marks: [OutlineFolds.Mark]) {
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

    func writeNow() {
        pending?.cancel()
        pending = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(graphs) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
