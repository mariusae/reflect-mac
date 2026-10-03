import Foundation
import Observation
import ReflectCore
import ReflectGit2

/// The graph the app shows, and its index, read in the background.
///
/// Where the graph is: `-GraphPath <folder>` on the command line, as on the
/// Mac — for a simulator pointed at a checkout — else `Graph` in the app's
/// Documents: cloned there from GitHub, or put there through Files.
///
/// A graph in a repository is kept in step with GitHub by the same sync the
/// Mac runs, its steps done by libgit2.
@MainActor
@Observable
final class GraphStore {
    static let graphPathKey = "GraphPath"

    private(set) var graph: Graph?
    private(set) var index: NoteIndex?
    /// Every day with a note, newest first; today among them, written or not.
    private(set) var days: [Day] = []
    private(set) var isLoading = false
    /// Bumped whenever the notes are read again, for views to follow.
    private(set) var revision = 0

    /// The sync, when the graph is in a repository.
    private(set) var git: Git?
    private(set) var isSyncing = false
    private(set) var lastSynced: Date?
    private(set) var syncError: String?

    let root: URL
    let account: GitHubAccount

    init(account: GitHubAccount) {
        self.account = account
        if let path = UserDefaults.standard.string(forKey: Self.graphPathKey) {
            root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            root = URL.documentsDirectory.appendingPathComponent("Graph", isDirectory: true)
        }
    }

    /// Whether there is a graph there: a folder with notes or days in it.
    var hasGraph: Bool {
        NoteIndex.directories.contains { name in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
        }
    }

    func load() async {
        guard hasGraph, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let root = root
        let (graph, index, days) = await Task.detached(priority: .userInitiated) {
            let graph = Graph(root: root, git: nil)
            let index = NoteIndex(root: root)
            index.scan()
            let today = Day.today
            let days = Set(graph.dailyNotes().keys).union([today]).filter { $0 <= today }.sorted(by: >)
            return (graph, index, days)
        }.value
        self.graph = graph
        self.index = index
        self.days = days
        revision += 1
        if git == nil, let backend = LibGit2Backend(root: root) {
            let token = account.currentToken
            backend.credentials = { token.credentials }
            if let identity = account.user?.identity { backend.identity = identity }
            git = Git(backend: backend)
        }
    }

    // MARK: Syncing

    /// Takes in what other devices wrote, and sends what was written here;
    /// reads the notes again when anything came in.
    func sync() async {
        guard let git, account.isSignedIn, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            _ = try await account.validAccessToken()
            let report = try await git.sync(.full)
            lastSynced = Date()
            syncError = nil
            if report.pulled { await load() }
        } catch {
            syncError = error.localizedDescription
        }
    }

    /// Pulled down: sync, and read the notes again.
    func refresh() async {
        await sync()
        await load()
    }

    /// Clones a repository into the graph's place — only its latest commit —
    /// then reads it. Nothing is left behind when it fails.
    func clone(_ repository: GitHubRepository) async throws {
        try await GraphClone.clone(repository, account: account, into: root)
        UserDefaults.standard.set(repository.fullName, forKey: Self.repositoryKey)
        await load()
        lastSynced = Date()
    }

    static let repositoryKey = "GitHubRepository"

    /// The repository the graph was cloned from, by name.
    var repositoryName: String? { UserDefaults.standard.string(forKey: Self.repositoryKey) }

    // MARK: Reading

    func text(_ path: String) -> String? {
        index?.body(path) ?? graph?.read(path: path)
    }

    func title(_ path: String) -> String {
        if let day = GraphPaths.day(fromDailyPath: path) { return DayTitle.long(day) }
        return index?.entry(path)?.title ?? (path as NSString).lastPathComponent
    }

    /// Where a link leads: a note's path, or nil when there is no such note.
    func resolve(_ target: String) -> String? {
        guard let path = index?.resolve(target) else { return nil }
        // A day not written yet is still a place to go.
        if GraphPaths.day(fromDailyPath: path) != nil { return path }
        return index?.entry(path) == nil ? nil : path
    }
}

enum DayTitle {
    private static let sameYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter
    }()

    private static let otherYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMdyyyy")
        return formatter
    }()

    /// "Saturday, September 26", with the year when it is not this one.
    static func long(_ day: Day) -> String {
        guard let date = day.date else { return day.description }
        return (day.year == Day.today.year ? sameYear : otherYear).string(from: date)
    }

    /// "Today", "Yesterday", or the date.
    static func relative(_ day: Day) -> String {
        let today = Day.today
        if day == today { return "Today" }
        if day == today.adding(-1) { return "Yesterday" }
        return long(day)
    }
}
