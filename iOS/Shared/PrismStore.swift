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
    private(set) var isSyncing = false { didSet { if isSyncing != oldValue { syncStateChanged() } } }
    private(set) var lastSynced: Date?
    /// How long the last sync took, and where: "1.8 s, most of it fetching (1.2 s)".
    private(set) var lastSyncTook: String?
    private(set) var syncError: String? { didSet { if syncError != oldValue { syncStateChanged() } } }
    /// The notes holding sync conflicts, to be settled.
    private(set) var conflicted: [String] = [] { didSet { if conflicted != oldValue { syncStateChanged() } } }

    /// How syncing goes, for the dot on the bars: told as it changes.
    enum SyncMark { case fine, syncing, failed, conflicted }
    var syncMark: SyncMark { isSyncing ? .syncing : !conflicted.isEmpty ? .conflicted : syncError != nil ? .failed : .fine }

    private func syncStateChanged() {
        let mark = syncMark
        DispatchQueue.main.async { NotificationCenter.default.post(name: .prismSyncChanged, object: mark) }
    }

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
        StallWatch.mark("load begun")
        let (graph, index, conflicted) = await Task.detached(priority: .userInitiated) {
            let graph = Graph(root: root, git: nil)
            let index = NoteIndex(root: root)
            index.scan()
            return (graph, index, index.conflicted())
        }.value
        await Typeface.registration.value
        StallWatch.mark("index scanned")
        self.graph = graph
        PhoneImages.root = root
        self.conflicted = conflicted
        self.index = index
        changed = []
        revision += 1
        prepareGit()
        applyHistory()
    }

    /// Every note's last change taken from the graph's history, off the main
    /// thread — a clone or a sync sets files' own times to when it wrote
    /// them — and what shows them told.
    private func applyHistory() {
        guard let index else { return }
        Task {
            await Task.detached(priority: .utility) { ChangeHistory.apply(to: index) }.value
            changed = []
            revision += 1
        }
    }

    /// The repository, ready to sync — without the notes read in: a push
    /// woke the app in the background, and the sync is all it needs.
    func prepareGit() {
        guard git == nil, hasGraph, let backend = LibGit2Backend(root: root) else { return }
        let token = account.currentToken
        backend.credentials = { token.credentials }
        if let identity = account.user?.identity { backend.identity = identity }
        git = Git(backend: backend)
    }

    /// The GitHub repository the graph is a clone of: `owner/name`.
    var repositoryName: String? {
        SyncRelay.repository(fromRemote: (git?.backend as? LibGit2Backend)?.remoteURL())
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
        if conflicted.contains(path), !ConflictMarkers.detect(text) { conflicted.removeAll { $0 == path } }
        // The index read again away from the typing — a long note's links
        // and names take a while — and what shows it told after.
        let index = self.index
        Self.indexing.async {
            index?.refresh(path)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.changed = [path]
                self.revision += 1
                self.written()
            }
        }
    }

    /// A note deleted: its file out of the graph — kept in the graph's
    /// history, once synced — and gone from other devices at their next sync.
    func delete(_ path: String) {
        guard let graph else { return }
        do {
            try FileManager.default.removeItem(at: graph.url(for: path))
        } catch {
            syncError = error.localizedDescription
            return
        }
        let index = self.index
        Self.indexing.async {
            index?.refresh(path)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.changed = [path]
                self.revision += 1
                self.written()
            }
        }
    }

    /// Where notes written are read into the index again, one at a time.
    private static let indexing = DispatchQueue(label: "PrismStore.indexing", qos: .userInitiated)

    /// Days with no note shown in the timeline all the same, to write in:
    /// opened from a gap, or gone to. Written in, they are notes like any.
    private(set) var revealedDays: Set<Day> = Set((UserDefaults.standard.stringArray(forKey: "RevealedDays") ?? []).compactMap { Day($0) }) {
        didSet { UserDefaults.standard.set(revealedDays.map(\.description).sorted(), forKey: "RevealedDays") }
    }

    /// Some days shown in every timeline, empty till written in.
    func reveal(_ days: [Day]) {
        let new = Set(days).subtracting(revealedDays)
        guard !new.isEmpty else { return }
        revealedDays.formUnion(new)
        changed = Set(new.map { GraphPaths.dailyPath(for: $0) })
        revision += 1
    }

    /// Notes changed underneath — by a sync — taken in.
    func noteChanged(_ paths: [String]) {
        paths.forEach { index?.refresh($0) }
        changed = Set(paths)
        revision += 1
    }

    /// A note's cover — a picture's source — set, or taken off for nil.
    func setCover(_ path: String, _ source: String?) {
        let text = text(path)
        let updated = NoteCover.setting(source, in: text)
        guard updated != text else { return }
        write(updated, path: path)
    }

    /// A picture kept in the graph's `assets/`, as pasted ones are, and made
    /// a note's cover.
    func setCover(_ path: String, picture data: Data, extension ext: String) throws {
        guard let graph else { return }
        let added = try Assets.add(data, named: Assets.pastedName(extension: ext), to: graph.root)
        setCover(path, added)
    }

    /// Sets or takes away a frontmatter key of a note — `inbox`, `topic`,
    /// `pinned` — and has everything showing it follow.
    func setFrontmatter(_ path: String, _ key: String, _ value: String?, undoName: String? = nil) {
        let source = text(path)
        let updated = Frontmatter.setting(key, to: value, in: source)
        guard updated != source else { return }
        write(updated, path: path)
        if let undoName { registerUndo(undoName, path: path, from: updated, back: source) }
    }

    /// A note's text changed outside its editor — its mentions made links —
    /// offered to undo for a moment.
    func change(_ path: String, undoName: String, _ transform: (String) -> String?) {
        let before = text(path)
        guard let after = transform(before), after != before else { return }
        write(after, path: path)
        registerRevert(path, from: after, to: before, undo: undo)
        undo.setActionName(undoName)
        NotificationCenter.default.post(name: .prismUndoable, object: self, userInfo: ["name": undoName, "undo": undo])
    }

    /// Rows put in another note — a day's top, any other's end — undone
    /// with `undo`: the note as it was, gone again if it was not there.
    func add(_ rows: [Row], to path: String, undo: UndoManager) {
        guard let graph else { return }
        let existed = graph.exists(path: path)
        let before = text(path)
        let after = RowMove.adding(rows, to: before, path: path)
        write(after, path: path)
        registerRevert(path, from: after, to: existed ? before : nil, undo: undo)
    }

    private func registerRevert(_ path: String, from now: String, to then: String?, undo: UndoManager) {
        undo.registerUndo(withTarget: self) { store in
            // Changed since: not undone over it.
            guard let graph = store.graph, store.text(path) == now else { return }
            if let then {
                store.write(then, path: path)
            } else {
                try? FileManager.default.removeItem(at: graph.url(for: path))
                store.noteChanged([path])
            }
            store.registerRevert(path, from: then ?? "", to: now, undo: undo)
        }
    }

    /// What was done to notes outside their editors — a note out of the
    /// inbox, pinned — to undo: offered for a moment, over the page.
    let undo = UndoManager()

    private func registerUndo(_ name: String, path: String, from updated: String, back source: String) {
        undo.registerUndo(withTarget: self) { store in
            // Changed since: not undone over it.
            guard store.text(path) == updated else { return }
            store.write(source, path: path)
            store.registerUndo(name, path: path, from: source, back: updated)
        }
        undo.setActionName(name)
        if !undo.isUndoing, !undo.isRedoing {
            NotificationCenter.default.post(name: .prismUndoable, object: self, userInfo: ["name": name, "undo": undo])
        }
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

    /// A note by its title, followed to by a link — made, if there is none:
    /// made so, it goes again when it is left as it was made.
    func note(titled title: String) -> String? {
        if let path = index?.resolve(title) { return path }
        guard let graph, !title.trimmingCharacters(in: .whitespaces).isEmpty,
              let path = try? NoteCreation.create(title: title, in: graph.root) else { return nil }
        linkMade[path] = text(path)
        noteChanged([path])
        return path
    }

    /// Notes made by following a link to them, as they were made.
    private var linkMade: [String: String] = [:]

    /// A note made here, left: gone, when nothing was written in it; else
    /// moved to the file its title names — nothing links to it yet. Says
    /// where it is now.
    @discardableResult
    func settleNewNote(_ path: String) -> String? {
        // Made by a link, left as it was: gone again.
        if let made = linkMade.removeValue(forKey: path), let graph {
            guard text(path) == made else { return path }
            try? FileManager.default.removeItem(at: graph.url(for: path))
            noteChanged([path])
            return nil
        }
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

    // MARK: Pages shared from other apps

    private var takingShared = false

    /// Pages the share extension left, made link notes as the Mac's capture
    /// makes them — linked from the day they were shared — then gone from
    /// the queue. A page with no title has it read from the page.
    func takeShared() async {
        guard let graph, let index, !takingShared else { return }
        let pending = ShareQueue.pending()
        guard !pending.isEmpty else { return }
        takingShared = true
        defer { takingShared = false }
        var paths: [String] = []
        for (item, file) in pending {
            let day = Day(item.shared)
            // Words, or a picture: into the day, or a note of their own in the inbox.
            if item.text != nil || item.picture != nil {
                if let saved = takeShared(item, on: day, in: graph, index: index) {
                    paths += saved
                    ShareQueue.remove(file)
                    if let picture = item.picture, let folder = ShareQueue.folder { ShareQueue.remove(folder.appendingPathComponent(picture)) }
                }
                continue
            }
            var page = WebCapture.Page(url: item.url, title: item.title, description: item.description, highlights: item.highlights)
            page.image = item.image
            let toDay = item.destination == "today"
            if page.title.isEmpty || page.description.isEmpty || (page.image == nil && !toDay), let read = await Self.readPage(item.url) {
                if page.title.isEmpty { page.title = read.title }
                if page.description.isEmpty { page.description = read.description }
                if page.image == nil { page.image = read.image }
            }
            let isNew = !toDay && WebCapture.existingNote(for: page.url, in: graph, index: index) == nil
            let saved = await Task.detached(priority: .userInitiated) {
                toDay ? try? WebCapture.saveToDay(page, in: graph, index: index, on: day)
                    : try? WebCapture.save(page, in: graph, index: index, on: day)
            }.value
            guard let saved else { continue }
            paths += [saved, GraphPaths.dailyPath(for: day)]
            ShareQueue.remove(file)
            // A new note's cover: the page's own picture, when it is a good one.
            if isNew, let cover = await CaptureCover.choose(image: page.image, title: page.title, screenshot: nil, in: graph.root),
               NoteCover.source(in: text(saved)) == nil {
                write(NoteCover.setting(cover, in: text(saved)), path: saved)
            }
        }
        guard !paths.isEmpty else { return }
        noteChanged(paths)
        written()
    }

    /// Shared words, or a picture, put in: the paths written.
    private func takeShared(_ item: ShareQueue.Item, on day: Day, in graph: Graph, index: NoteIndex) -> [String]? {
        do {
            if let name = item.picture, let folder = ShareQueue.folder {
                let data = try Data(contentsOf: folder.appendingPathComponent(name))
                let path = try Assets.add(data, named: "shared-" + name, to: graph.root)
                let dayPath = GraphPaths.dailyPath(for: day)
                try graph.write(QuickNote.prepending([Row(kind: .bullet, text: "![](\(path))")], toDay: graph.read(path: dayPath) ?? ""), path: dayPath)
                return [dayPath]
            }
            guard let text = item.text else { return nil }
            if item.destination == "today" {
                return try QuickNote.add(text, in: graph, index: index, on: day).map { [$0] }
            }
            // A note of its own, in the inbox: its first line its title, the rest its rows.
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let first = lines.first else { return nil }
            let path = try NoteCreation.create(title: String(first.prefix(80)), in: graph.root)
            var source = Frontmatter.setting("inbox", to: "true", in: graph.read(path: path) ?? "")
            let rows = QuickNote.rows(lines.dropFirst().joined(separator: "\n"))
            if !rows.isEmpty { source = RowMove.adding(rows, to: source, path: path) }
            try graph.write(source, path: path)
            index.refresh(path)
            return [path]
        } catch {
            return nil
        }
    }

    /// A page's title, description and picture, as its HTML gives them.
    private nonisolated static func readPage(_ address: String) async -> (title: String, description: String, image: String?)? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let html = String(decoding: data.prefix(400_000), as: UTF8.self)
        func meta(_ name: String) -> String? {
            for pattern in ["<meta[^>]+(?:property|name)=[\"']\(name)[\"'][^>]+content=[\"']([^\"']*)[\"']",
                            "<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+(?:property|name)=[\"']\(name)[\"']"] {
                if let range = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
                   let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                   let match = regex.firstMatch(in: String(html[range]), range: NSRange(location: 0, length: html[range].utf16.count)),
                   let value = Range(match.range(at: 1), in: String(html[range])) {
                    return String(String(html[range])[value])
                }
            }
            return nil
        }
        var title = meta("og:title") ?? ""
        if title.isEmpty, let range = html.range(of: "<title[^>]*>[^<]*</title>", options: [.regularExpression, .caseInsensitive]) {
            title = String(html[range]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        let decode = { (text: String) -> String in
            guard let data = text.data(using: .utf8),
                  let decoded = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                               .characterEncoding: String.Encoding.utf8.rawValue],
                                                        documentAttributes: nil).string else { return text }
            return decoded
        }
        let description = meta("og:description") ?? meta("description") ?? ""
        // The page's picture, made whole against its address.
        let image = (meta("og:image") ?? meta("og:image:url") ?? meta("twitter:image"))
            .flatMap { URL(string: $0.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: url)?.absoluteString }
        let found = title
        return await MainActor.run {
            (decode(found).trimmingCharacters(in: .whitespacesAndNewlines), decode(description).trimmingCharacters(in: .whitespacesAndNewlines), image)
        }
    }

    /// Called whenever something was written: a sync is due soon. Set by
    /// the sync scheduler.
    var written: () -> Void = {}

    // MARK: Syncing

    /// Commit what is written, take in what other devices wrote, send it
    /// all: the full round. The notes it brought are taken in.
    func sync() async { await run(.full) }

    /// Commits and pushes what is written here, nothing more.
    func push() async { await run(.push) }

    /// Asked of a sync under way, when the system takes the app's time in
    /// the background back: stop at the next safe point, to go on next time.
    func stopSyncing() { git?.stop() }

    /// A sync asked for while one runs, done after it — a full one if any
    /// was asked for — never dropped: whoever asked waits for it.
    private var pending: Git.Mode?
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func run(_ mode: Git.Mode) async {
        guard git != nil else { return }
        if isSyncing {
            pending = pending == .full || mode == .full ? .full : .push
            await withCheckedContinuation { waiting.append($0) }
            return
        }
        isSyncing = true
        var next: Git.Mode? = mode
        while let mode = next {
            pending = nil
            await cycle(mode)
            next = pending
        }
        isSyncing = false
        let waited = waiting
        waiting = []
        waited.forEach { $0.resume() }
    }

    private func cycle(_ mode: Git.Mode) async {
        guard let git else { return }
        do {
            // Signed out, a remote that asks for nothing still syncs.
            if account.isSignedIn { _ = try await account.validAccessToken() }
            StallWatch.mark("sync begun")
            let report = try await git.sync(mode)
            StallWatch.mark("sync done, pulled \(report.pulled)")
            lastSynced = Date()
            lastSyncTook = report.timingSummary
            syncError = nil
            if report.pulled {
                // What came in read into the index off the main thread.
                let paths = report.changed
                if let index { await Task.detached(priority: .userInitiated) { paths.forEach(index.refresh) }.value }
                changed = Set(paths)
                revision += 1
            }
            // Only what came in can bring a conflict: found in the texts
            // the index holds, not every file read again each sync.
            if report.pulled, let index {
                conflicted = await Task.detached(priority: .utility) { index.conflicted() }.value
            }
            // What was committed and pulled: their last changes, by the history.
            applyHistory()
        } catch is SyncStopped {
            // Asked to stop — the system wanted its time back — not a failure:
            // the next sync goes on from here.
            Log.shared.info("sync", "Stopped at a safe point, to go on next time")
        } catch {
            syncError = describe(error)
        }
    }

    /// What went wrong, said so the person knows what to do: a remote that
    /// wants a sign-in there is none of, said as that — not as libgit2 says it.
    private func describe(_ error: Error) -> String {
        let message = error.localizedDescription
        if !account.isSignedIn, message.localizedCaseInsensitiveContains("authentication") {
            return "Signed out of GitHub. Choose Sign In to GitHub in the menu to sync again."
        }
        return message
    }

    /// Brings a repository down into the graph's place, then reads it.
    func clone(_ repository: GitHubRepository) async throws {
        try await GraphClone.clone(repository, account: account, into: root)
        await load()
        lastSynced = Date()
        PushRelay.shared.register()
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

    /// A push from the relay: another device wrote. Synced now, in the
    /// thirty seconds or so the system gives — stopped safely before then.
    func syncForPush(_ completion: @escaping (UIBackgroundFetchResult) -> Void) {
        store.prepareGit()
        let before = store.revision
        var task = UIBackgroundTaskIdentifier.invalid
        var done = false
        let finish = { [store] in
            guard !done else { return }
            done = true
            completion(store.revision != before ? .newData : .noData)
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
        task = UIApplication.shared.beginBackgroundTask(withName: "Pushed") { [weak store] in
            MainActor.assumeIsolated {
                store?.stopSyncing()
                finish()
            }
        }
        let limit = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak store] _ in
            MainActor.assumeIsolated { store?.stopSyncing() }
        }
        Task {
            beforeSync()
            await store.sync()
            limit.invalidate()
            finish()
        }
    }

    func becameActive() {
        PushRelay.shared.register()
        // Pages shared while away, made notes first, then the round sends them.
        Task {
            await store.takeShared()
            round()
        }
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
        // When the system wants its time back, the sync is asked to stop at
        // its next safe point; what it committed stays, and the next sync
        // goes on — the background task is never left running out.
        var task = UIBackgroundTaskIdentifier.invalid
        let end = {
            guard task != .invalid else { return }
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        task = UIApplication.shared.beginBackgroundTask(withName: "Push") { [weak store] in
            MainActor.assumeIsolated {
                store?.stopSyncing()
                end()
            }
        }
        Task {
            await store.push()
            end()
        }
    }
}
