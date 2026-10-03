import Foundation
import UIKit
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

    /// Sets or takes away a frontmatter key of a note — `inbox`, `topic`,
    /// `pinned` — and has everything showing it follow.
    func setFrontmatter(_ path: String, _ key: String, _ value: String?) {
        let source = text(path)
        let updated = Frontmatter.setting(key, to: value, in: source)
        guard updated != source else { return }
        write(updated, path: path)
    }

    // MARK: New notes

    /// Notes made blank here, not yet named: those left blank go again.
    private var blankNotes: Set<String> = []

    /// A blank note, to type its title in.
    func newNote() -> String? {
        guard let graph else { return nil }
        do {
            let path = try NoteCreation.createBlank(in: graph.root)
            blankNotes.insert(path)
            noteChanged([path])
            return path
        } catch {
            syncError = error.localizedDescription
            return nil
        }
    }

    /// A note made here, left: gone, when nothing was written in it; else
    /// moved to the file its title names — nothing links to it yet. Says
    /// where it is now.
    @discardableResult
    func settleNewNote(_ path: String) -> String? {
        guard blankNotes.contains(path), let graph, let index else { return path }
        let source = text(path)
        guard let title = TitleRename.authoredTitle(path: path, source: source) else {
            guard Backlinks.isEmpty(OutlineMarkdown.parse(source).rows) else { return path }
            blankNotes.remove(path)
            try? FileManager.default.removeItem(at: graph.url(for: path))
            noteChanged([path])
            return nil
        }
        blankNotes.remove(path)
        guard TitleRename.isManaged(path: path, source: source) else { return path }
        let destination = index.managedPath(for: title, current: path)
        guard destination != path else { return path }
        do {
            try FileManager.default.moveItem(at: graph.url(for: path), to: graph.url(for: destination))
        } catch {
            return path
        }
        noteChanged([path, destination])
        written()
        return destination
    }

    /// Called whenever something was written: a sync is due soon. Set by
    /// the sync scheduler.
    var written: () -> Void = {}

    // MARK: Syncing

    /// Commit what is written, take in what other devices wrote, send it
    /// all: the full round. The notes it brought are taken in.
    func sync() async {
        guard let git, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            // Signed out, a remote that asks for nothing still syncs.
            if account.isSignedIn { _ = try await account.validAccessToken() }
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
        guard let git, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            if account.isSignedIn { _ = try await account.validAccessToken() }
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

/// When Prism syncs, while it is open: what is written, sent a few seconds
/// after writing stops; everything, on coming to the front and every few
/// minutes after; what is written, once more, on going to the back.
@MainActor
final class SyncScheduler {
    private let store: PrismStore
    private var pushTimer: Timer?
    private var roundTimer: Timer?
    /// Called before each sync: what is typed, written first.
    var beforeSync: () -> Void = {}
    static let pushDelay: TimeInterval = 5
    static let roundInterval: TimeInterval = 120

    init(store: PrismStore) {
        self.store = store
        store.written = { [weak self] in self?.wrote() }
    }

    private func wrote() {
        pushTimer?.invalidate()
        pushTimer = Timer.scheduledTimer(withTimeInterval: Self.pushDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.push() }
        }
    }

    private func push() {
        pushTimer?.invalidate()
        pushTimer = nil
        beforeSync()
        Task { await store.push() }
    }

    private func round() {
        beforeSync()
        Task { await store.sync() }
    }

    func becameActive() {
        round()
        roundTimer?.invalidate()
        roundTimer = Timer.scheduledTimer(withTimeInterval: Self.roundInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.round() }
        }
    }

    /// Gone to the back: what is written sent, in the time the system gives.
    func wentToBackground() {
        roundTimer?.invalidate()
        roundTimer = nil
        pushTimer?.invalidate()
        pushTimer = nil
        beforeSync()
        let task = UIApplication.shared.beginBackgroundTask(withName: "Push")
        Task {
            await store.push()
            UIApplication.shared.endBackgroundTask(task)
        }
    }
}
