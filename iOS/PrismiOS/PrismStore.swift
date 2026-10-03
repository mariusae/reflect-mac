import Foundation
import Observation
import ReflectCore
import ReflectGit2
import PrismCore

/// The graph Prism shows, its index, and its sync with GitHub.
///
/// Where the graph is: `-GraphPath <folder>` on the command line — for a
/// simulator pointed at a checkout — else `Graph` in the app's Documents,
/// cloned there from GitHub.
@MainActor
@Observable
final class PrismStore {
    static let graphPathKey = "GraphPath"

    private(set) var graph: Graph?
    private(set) var index: NoteIndex?
    /// Bumped whenever notes change — written here, or brought in by a
    /// sync — for every view of them to follow.
    private(set) var revision = 0
    /// The notes that changed with the last bump, when known: those shown
    /// are read again, the rest left be.
    private(set) var changed: Set<String> = []
    private(set) var isLoading = false

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
        let (graph, index) = await Task.detached(priority: .userInitiated) {
            let graph = Graph(root: root, git: nil)
            let index = NoteIndex(root: root)
            index.scan()
            return (graph, index)
        }.value
        self.graph = graph
        self.index = index
        changed = []
        revision += 1
        if git == nil, let backend = LibGit2Backend(root: root) {
            let token = account.currentToken
            backend.credentials = { token.credentials }
            if let identity = account.user?.identity { backend.identity = identity }
            git = Git(backend: backend)
        }
    }

    // MARK: Reading and writing

    func text(_ path: String) -> String { graph?.read(path: path) ?? "" }

    /// Writes a note, and has everything showing it follow.
    func write(_ text: String, path: String) {
        guard let graph else { return }
        guard graph.read(path: path) != text else { return }
        do {
            try graph.write(text, path: path)
        } catch {
            syncError = error.localizedDescription
            return
        }
        index?.refresh(path)
        changed = [path]
        revision += 1
        written()
    }

    /// Notes changed underneath — by a sync — taken in.
    func noteChanged(_ paths: [String]) {
        paths.forEach { index?.refresh($0) }
        changed = Set(paths)
        revision += 1
    }

    /// Called whenever something was written: a sync is due soon. Set by
    /// the sync scheduler.
    var written: () -> Void = {}

    // MARK: Syncing

    /// Commit what is written, take in what other devices wrote, send it
    /// all: the full round. The notes it brought are taken in.
    func sync() async {
        guard let git, account.isSignedIn, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            _ = try await account.validAccessToken()
            let report = try await git.sync(.full)
            lastSynced = Date()
            syncError = nil
            if report.pulled { noteChanged(report.changed) }
        } catch {
            syncError = error.localizedDescription
        }
    }

    /// Commits and pushes what is written here, nothing more.
    func push() async {
        guard let git, account.isSignedIn, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            _ = try await account.validAccessToken()
            _ = try await git.sync(.push)
            lastSynced = Date()
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
    }

    /// Brings a repository down into the graph's place, then reads it.
    func clone(_ repository: GitHubRepository) async throws {
        try await GraphClone.clone(repository, account: account, into: root)
        await load()
        lastSynced = Date()
    }
}
