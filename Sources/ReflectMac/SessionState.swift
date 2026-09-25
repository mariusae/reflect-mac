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

    func folds(_ root: URL, _ day: Day) -> [OutlineFolds.Mark] {
        graph(root).folds[day.description] ?? []
    }

    /// Notes a day's folds, writing only when they changed.
    func setFolds(_ root: URL, _ day: Day, _ marks: [OutlineFolds.Mark]) {
        guard folds(root, day) != marks else { return }
        update(root) { $0.folds[day.description] = marks.isEmpty ? nil : marks }
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
