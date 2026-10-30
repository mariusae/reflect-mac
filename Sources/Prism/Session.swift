import AppKit
import ReflectCore
import PrismCore
import ReflectGit2
import ReflectUI

/// A graph open in Prism: its notes, their index, the sync that keeps them
/// in step, and what is shared by every window showing them — the type,
/// titles settling, edits lately made. Windows show; the session writes.
@MainActor
final class Session {
    let graph: Graph
    let index: NoteIndex
    let images: ImageStore
    private(set) var windows: [PrismWindow] = []
    /// The reading queue's window, when open: one — two would read the same link.
    private(set) var readingQueue: ReadingQueueWindow?

    var face: Typeface {
        didSet { typographyChanged() }
    }
    var size: CGFloat {
        get { CGFloat(face.settings.size) }
        set {
            var settings = face.settings
            settings.size = Double(newValue)
            face.settings = settings
            typographyChanged()
        }
    }
    var metrics: OutlineMetrics { OutlineMetrics(typography: face.typography()) }

    private var watcher: GraphWatcher?
    private(set) var recent: RecentEdits
    /// What each note shown said when last read or written: the edits are what changed from it.
    private var lastText: [String: String] = [:]

    private lazy var sync: SyncController = {
        let sync = SyncController(git: graph.git)
        sync.flush = { [weak self] in self?.save() }
        sync.onPulled = { [weak self] paths in self?.notesChanged(Set(paths)) }
        sync.onStatus = { [weak self] status in self?.showSync(status) }
        sync.onConflicts = { [weak self] _ in self?.refreshReview() }
        return sync
    }()

    init(graph: Graph) {
        self.graph = graph
        index = NoteIndex(root: graph.root)
        images = ImageStore(root: graph.root)
        Place.coverImage = { [images] in images.image($0) }
        let defaults = UserDefaults.standard
        let ideal = Typeface.available.contains(.ideal)
        if ideal, !defaults.bool(forKey: "Typeface.idealAdopted"), !Session.scripted {
            defaults.set(true, forKey: "Typeface.idealAdopted")
            defaults.set(Typeface.ideal.rawValue, forKey: "Typeface")
        }
        face = defaults.string(forKey: "Typeface").flatMap(Typeface.init(rawValue:)).flatMap { Typeface.available.contains($0) ? $0 : nil }
            ?? (ideal ? .ideal : .lato)
        recent = Self.loadRecent(graph.root)
        index.scan()
        applyHistory()
        refreshReview()
        watcher = GraphWatcher(root: graph.root) { [weak self] paths in
            self?.notesChanged(paths)
            if self?.ownsSync == true { self?.sync.noteChanged() }
        }
        LinkCompletion.sources = SearchSources(index: index)
        LinkCard.noteSource = { [weak self] title in
            guard let self, let path = index.resolve(title) else { return nil }
            return (NoteRef(path: path), graph.read(path: path) ?? "")
        }
        startNow()
    }

    static var scripted: Bool { ProcessInfo.processInfo.environment["PRISM_SNAP"] != nil }

    // MARK: Windows

    /// A new window: as one was left, or on today.
    @discardableResult
    func newWindow(_ state: PrismWindow.State? = nil) -> PrismWindow {
        let window = PrismWindow(session: self, state: state)
        windows.append(window)
        return window
    }

    func windowClosed(_ window: PrismWindow) {
        window.saveNotes()
        // The last one's place kept, to open as it was.
        if windows.count == 1 { writeWindows() }
        windows.removeAll { $0 === window }
        if windows.isEmpty == false { writeWindows() }
    }

    /// The windows as they were left — at least one.
    func restoreWindows() {
        let saved = SessionState.shared.graph(graph.root).prismWindows
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([PrismWindow.State].self, from: $0) } ?? []
        if saved.isEmpty {
            newWindow()
        } else {
            saved.forEach { newWindow($0) }
        }
        restored = true
    }

    /// The reading queue's window, brought forward — opened, if it is not.
    @discardableResult
    func openReadingQueue() -> ReadingQueueWindow {
        let queue = readingQueue ?? ReadingQueueWindow(session: self)
        readingQueue = queue
        if !Self.scripted { UserDefaults.standard.set(true, forKey: "Queue.open") }
        return queue
    }

    func readingQueueClosed(_ queue: ReadingQueueWindow) {
        guard queue === readingQueue else { return }
        readingQueue = nil
        // Closed by hand: not open again next time. Quitting leaves it to open again.
        if !Self.quitting { UserDefaults.standard.set(false, forKey: "Queue.open") }
    }

    // MARK: Sync status

    /// Graph ▸ Sync Status: how syncing goes, brought forward — opened, if it is not.
    private(set) var syncWindow: SyncStatusWindow?

    @discardableResult
    func openSyncStatus() -> SyncStatusWindow {
        let window = syncWindow ?? SyncStatusWindow(session: self)
        syncWindow = window
        return window
    }

    func syncStatusClosed(_ window: SyncStatusWindow) {
        if window === syncWindow { syncWindow = nil }
    }

    /// Told of pushes elsewhere, when there is a relay: Prism's own clone's.
    var relay: SyncRelayListener? {
        didSet { relay?.onState = { [weak self] _ in self?.syncWindow?.refresh() } }
    }
    var syncRecord: SyncController.Record { sync.record }
    var syncStats: SyncController.Stats { sync.stats }
    var syncRunning: Git.Mode? { sync.runningMode }
    /// How the repository stands, after any cycle under way.
    func syncHealth() async -> SyncHealth? { await graph.git?.health() }

    /// Whether the reading queue was open when Prism was last left.
    var readingQueueWasOpen: Bool { UserDefaults.standard.bool(forKey: "Queue.open") }

    /// Set as Prism quits: windows closed then were open when it was left.
    static var quitting = false

    /// Whether the windows have been put back: till then, nothing is noted over what was left.
    private var restored = false

    func writeWindows() {
        guard restored, let data = try? JSONEncoder().encode(windows.map(\.state)), let text = String(data: data, encoding: .utf8) else { return }
        SessionState.shared.update(graph.root) { $0.prismWindows = text }
    }

    /// The window worked in: the key one, else the first.
    var frontWindow: PrismWindow? {
        windows.first { $0.window?.isKeyWindow == true } ?? windows.first { $0.window?.isMainWindow == true } ?? windows.first
    }

    /// Writes every note with unsaved writing, and where things were left.
    func save() {
        windows.forEach { $0.saveNotes() }
        writeWindows()
        SessionState.shared.writeNow()
    }

    func typographyChanged() {
        if !Self.scripted { UserDefaults.standard.set(face.rawValue, forKey: "Typeface") }
        NotificationCenter.default.post(name: .prismTypographyChanged, object: self)
        windows.forEach { $0.typographyChanged() }
    }

    // MARK: Keeping up

    /// Notes changed on disk — written here, by a sync, by another app.
    func notesChanged(_ paths: Set<String>) {
        if paths.count > 40 { index.scan() } else { paths.forEach(index.refresh) }
        freshBacklinks = []
        windows.forEach { $0.notesChanged(paths) }
        readingQueue?.notesChanged(paths)
        refreshReview()
        refreshNow()
    }

    /// Notes written whole, and everything caught up.
    func write(_ writes: [(path: String, source: String)]) {
        do {
            for write in writes { try graph.write(write.source, path: write.path) }
        } catch {
            NSAlert(error: error).runModal()
        }
        notesChanged(Set(writes.map(\.path)))
        if ownsSync { sync.noteChanged() }
    }

    /// A note read, changed, written — when it changed.
    func change(_ path: String, _ transform: (String) -> String?) {
        save()
        let source = graph.read(path: path) ?? ""
        guard let updated = transform(source), updated != source else { return }
        write([(path, updated)])
    }

    /// Sets or takes away a frontmatter key of a note — `inbox`, `pinned`, `topic`, `private`, `cover`.
    func setFrontmatter(_ path: String, _ key: String, _ value: String?) {
        change(path) { Frontmatter.setting(key, to: value, in: $0) }
    }

    func entry(_ path: String) -> NoteEntry? {
        index.entry(path) ?? (graph.exists(path: path) ? NoteIndex.entry(path: path, source: graph.read(path: path) ?? "") : nil)
    }

    // MARK: What links to a note

    private var backlinks: [String: [BacklinkSource]] = [:]
    private var freshBacklinks: Set<String> = []
    private var lookingForBacklinks: [String: [([BacklinkSource]) -> Void]] = [:]

    /// What links to a note: as last found, at once — nil, the first time —
    /// and, when not fresh, looked for again off the main thread and told.
    func backlinks(to path: String, _ found: @escaping ([BacklinkSource]) -> Void) -> [BacklinkSource]? {
        let known = backlinks[path]
        guard !freshBacklinks.contains(path) else { return known }
        let first = lookingForBacklinks[path] == nil
        lookingForBacklinks[path, default: []].append(found)
        guard first else { return known }
        let index = index
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sources = index.backlinks(to: path)
            DispatchQueue.main.async {
                guard let self else { return }
                let waiting = self.lookingForBacklinks.removeValue(forKey: path) ?? []
                self.freshBacklinks.insert(path)
                guard sources != self.backlinks[path] else { return }
                self.backlinks[path] = sources
                waiting.forEach { $0(sources) }
            }
        }
        return known
    }

    /// What a note is called where it is listed: a day by its date.
    func name(of path: String) -> (title: String, detail: String?) {
        if let day = GraphPaths.day(fromDailyPath: path) { return (OpenQuickly.dayTitle(day), day == .today ? "Today" : nil) }
        if let week = GraphPaths.week(fromWeeklyPath: path) { return ("Week \(week.week)", OpenQuickly.weekRange(week)) }
        return (index.entry(path)?.title ?? (path as NSString).deletingPathExtension.components(separatedBy: "/").last ?? path, nil)
    }

    // MARK: New notes, and their titles

    /// Notes made here and not yet named: taken away again if left blank.
    private var blankNotes: Set<String> = []
    private var settledTitles: [String: String] = [:]
    private var pendingTitles: [String: String] = [:]
    private var retitleTimers: [String: Timer] = [:]
    private var renameChains: [String: (title: String, added: [String])] = [:]
    private static let retitleDelay: TimeInterval = 5

    /// A note with no name yet: its title to type first. Named, its file is
    /// named after it; left blank, it goes again.
    func newBlankNote() -> String? {
        save()
        do {
            let path = try NoteCreation.createBlank(in: graph.root)
            blankNotes.insert(path)
            index.refresh(path)
            return path
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    /// A note by its title — made, if there is none by that name.
    func note(titled title: String) -> String? {
        if let path = index.resolve(title) { return path }
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty, let path = try? NoteCreation.create(title: title, in: graph.root) else { return nil }
        index.refresh(path)
        return path
    }

    private func title(of view: DayView) -> String? {
        view.ref.day == nil ? TitleRename.authoredTitle(path: view.ref.path, source: view.savedText) : nil
    }

    func noteShown(_ view: DayView) {
        if view.ref.day == nil {
            view.editor.onMakeCover = { [weak self, weak view] source in
                guard let self, let view else { return }
                setFrontmatter(view.ref.path, NoteCover.key, NoteCover.quoted(source))
            }
        }
        if lastText[view.ref.path] == nil { lastText[view.ref.path] = graph.read(path: view.ref.path) ?? "" }
        guard view.ref.day == nil, settledTitles[view.ref.path] == nil, let title = title(of: view) else { return }
        settledTitles[view.ref.path] = title
    }

    /// A note written: a title typed in it waits to settle, then is taken.
    func noteSaved(_ view: DayView) {
        let path = view.ref.path
        noteEdits(path)
        guard let title = title(of: view), title != settledTitles[path] else {
            retitleTimers.removeValue(forKey: path)?.invalidate()
            pendingTitles[path] = nil
            return
        }
        pendingTitles[path] = title
        retitleTimers[path]?.invalidate()
        retitleTimers[path] = Timer.scheduledTimer(withTimeInterval: Self.retitleDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleTitle(path) }
        }
    }

    /// A note no longer shown: its title settled now; a new one left blank, taken away.
    func noteLeft(_ view: DayView) {
        let path = view.ref.path
        if pendingTitles[path] != nil { settleTitle(path) }
        guard blankNotes.contains(path) else { return }
        DispatchQueue.main.async { [weak self] in self?.dropIfBlank(view.ref) }
    }

    private func dropIfBlank(_ ref: NoteRef) {
        let path = ref.path
        guard blankNotes.contains(path), graph.exists(path: path), !windows.contains(where: { $0.shows(ref) }) else { return }
        let text = graph.read(path: path) ?? ""
        guard TitleRename.authoredTitle(path: path, source: text) == nil, Backlinks.isEmpty(OutlineMarkdown.parse(text).rows) else { return }
        blankNotes.remove(path)
        try? FileManager.default.removeItem(at: graph.url(for: path))
        notesChanged([path])
    }

    private func settleTitle(_ path: String) {
        retitleTimers.removeValue(forKey: path)?.invalidate()
        guard let to = pendingTitles.removeValue(forKey: path) else { return }
        let from = settledTitles[path]
        settledTitles[path] = to
        retitle(path, from: from, to: to)
    }

    /// A note's title settled on a new one, as Reflect does it: the links to
    /// it follow, its old title stays on as an alias, and a note Reflect
    /// manages moves to the file its title names.
    private func retitle(_ path: String, from: String?, to: String) {
        blankNotes.remove(path)
        save()
        guard graph.exists(path: path) else { return }
        var changed: Set<String> = [path]
        if let from {
            let result = index.retitleLinks(to: path, from: from, to: to, read: graph.read(path:),
                                             write: { [graph] text, source in try graph.write(text, path: source) })
            let chain = renameChains[path]
            let previous = chain?.title == from ? chain?.added ?? [] : []
            renameChains[path] = (to, [])
            if !result.collision, let source = graph.read(path: path) {
                let current = TitleRename.aliases(in: source)
                if let aliases = TitleRename.nextAliases(current, from: from, to: to, previousAutoAliases: previous) {
                    try? graph.write(Frontmatter.setting("aliases", toList: aliases, in: source), path: path)
                    renameChains[path] = (to, TitleRename.added(current, aliases))
                }
            }
            changed.formUnion(result.rewritten)
        }
        defer { notesChanged(changed) }
        guard let source = graph.read(path: path), TitleRename.isManaged(path: path, source: source) else { return }
        let destination = index.managedPath(for: to, current: path)
        guard destination != path else { return }
        do {
            try FileManager.default.moveItem(at: graph.url(for: path), to: graph.url(for: destination))
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        index.refresh(path)
        index.refresh(destination)
        changed.insert(destination)
        SessionState.shared.moved(graph.root, from: NoteRef(path: path), to: NoteRef(path: destination))
        if let title = settledTitles.removeValue(forKey: path) { settledTitles[destination] = title }
        if let chain = renameChains.removeValue(forKey: path) { renameChains[destination] = chain }
        windows.forEach { $0.noteMoved(from: path, to: destination) }
    }

    // MARK: Deleting

    /// A note to the Trash: no longer written by anything showing it, gone
    /// from every pane's way back, and everything listing it caught up.
    func trash(_ path: String) {
        save()
        windows.forEach { $0.discard(path) }
        do {
            try FileManager.default.trashItem(at: graph.url(for: path), resultingItemURL: nil)
        } catch {
            Log.shared.error("files", "Could not move \(path) to the Trash", detail: error.localizedDescription)
            NSAlert(error: error).runModal()
            return
        }
        Log.shared.info("files", "Moved \(path) to the Trash")
        windows.forEach { $0.noteTrashed(path) }
        notesChanged([path])
        if ownsSync { sync.noteChanged() }
    }

    /// A picture file made a note's cover: copied into the graph first.
    func setCover(of path: String, from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let added = try Assets.add(data, named: Assets.fileName(for: url.lastPathComponent), to: graph.root)
            Log.shared.info("files", "Added \(added)", detail: "the cover of \(path)")
            setFrontmatter(path, NoteCover.key, NoteCover.quoted(added))
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Recent edits

    private func noteEdits(_ path: String) {
        let now = graph.read(path: path) ?? ""
        let before = lastText[path] ?? now
        lastText[path] = now
        guard before != now else { return }
        recent.note(path, from: before, to: now)
        saveRecent()
    }

    private static func recentURL(_ root: URL) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Prism")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let name = String(root.standardizedFileURL.path.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
        return support.appendingPathComponent("Recent edits\(scripted ? " (scripts)" : "") \(name.suffix(60)).json")
    }

    private static func loadRecent(_ root: URL) -> RecentEdits {
        guard let data = try? Data(contentsOf: recentURL(root)) else { return RecentEdits() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(RecentEdits.self, from: data)) ?? RecentEdits()
    }

    private var recentSaving = false

    private func saveRecent() {
        guard !recentSaving else { return }
        recentSaving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            recentSaving = false
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            if let data = try? encoder.encode(recent) { try? data.write(to: Self.recentURL(graph.root), options: .atomic) }
        }
    }

    // MARK: Finding

    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// ⌘K: notes and days found by what is typed; nothing typed, the rows
    /// lately written in.
    func find(_ query: String) -> [Place] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return recentPlaces("") }
        var places: [Place] = []
        if "today".hasPrefix(trimmed.lowercased()) {
            places.append(Place(title: "Today", path: GraphPaths.dailyPath(for: .today), detail: OpenQuickly.dayTitle(.today)))
        }
        if let day = DayQuery.day(trimmed), !(day == .today && !places.isEmpty) {
            let path = GraphPaths.dailyPath(for: day)
            let relative = day == .today ? "Today" : day == Day.today.adding(-1) ? "Yesterday" : day == Day.today.adding(1) ? "Tomorrow" : "Day"
            places.append(Place(title: OpenQuickly.dayTitle(day), path: path, detail: graph.exists(path: path) ? relative : relative + " · no note yet"))
        }
        places += index.matches(trimmed, limit: 20).map {
            Place(title: $0.entry.title, path: $0.entry.path,
                  detail: $0.alias.map { "as \($0)" } ?? Self.ago.localizedString(for: $0.entry.modified, relativeTo: Date()),
                  flags: NoteFlags($0.entry), cover: $0.entry.cover)
        }
        return places
    }

    /// The rows lately written in, found by their words or their parents'.
    func recentPlaces(_ query: String) -> [Place] {
        recent.matching(query, title: { [weak self] in self?.name(of: $0).title ?? $0 }).prefix(20).compactMap { edit in
            guard graph.exists(path: edit.path) else { return nil }
            let name = self.name(of: edit.path).title
            let trail = ([name] + edit.ancestors.map { InlineMarkup.plainText($0) }).joined(separator: "  ›  ")
            let text = InlineMarkup.plainText(edit.text)
            return Place(title: text.isEmpty ? "(empty)" : text, path: edit.path, detail: Self.ago.localizedString(for: edit.date, relativeTo: Date()),
                         trail: trail, edit: edit)
        }
    }

    // MARK: Quick notes

    /// A few words at the top of today — typed or said in the quick note's
    /// panel — what is open written first, and shown as it is after.
    func addToToday(_ text: String) throws {
        save()
        guard let path = try QuickNote.add(text, in: graph, index: index) else { return }
        notesChanged([path])
        if ownsSync { sync.noteChanged() }
    }

    /// ⌃⌥Space: the quick note's panel, and its hot key — while the graph is open.
    private(set) var quickNote: QuickNoteController?

    func startQuickNote() {
        if quickNote == nil { quickNote = QuickNoteController(session: self) }
    }

    func endQuickNote() {
        quickNote?.end()
        quickNote = nil
    }

    // MARK: Pages captured in a browser

    func capture(_ page: WebCapture.Page, screenshot: Data?) throws -> (path: String, title: String) {
        save()
        if page.destination == .today {
            let path = try WebCapture.saveToDay(page, in: graph, index: index)
            notesChanged([path])
            if ownsSync { sync.noteChanged() }
            return (path, "Today")
        }
        var page = page
        if let screenshot {
            let name = "screenshot-" + Assets.slug(WebCapture.title(page.title, url: page.url)).prefix(40) + "-"
                + Assets.pastedName(extension: "png").replacingOccurrences(of: "pasted-", with: "")
            page.screenshot = try Assets.add(screenshot, named: name, to: graph.root)
        }
        let isNew = WebCapture.existingNote(for: page.url, in: graph, index: index) == nil
        let path = try WebCapture.save(page, in: graph, index: index)
        notesChanged([path, GraphPaths.dailyPath(for: .today)])
        if ownsSync { sync.noteChanged() }
        if isNew {
            let root = graph.root
            Task { [weak self] in
                guard let cover = await CaptureCover.choose(image: page.image, title: page.title, screenshot: page.screenshot, in: root),
                      let self, graph.exists(path: path), NoteCover.source(in: graph.read(path: path) ?? "") == nil else { return }
                setFrontmatter(path, NoteCover.key, NoteCover.quoted(cover))
            }
        }
        return (path, index.entry(path)?.title ?? WebCapture.title(page.title, url: page.url))
    }

    /// A captured page's note, opened from the browser, in the window worked in.
    func openCaptured(_ path: String) {
        NSApp.activate()
        let window = frontWindow ?? newWindow()
        window.showWindow(nil)
        window.open(path)
    }

    // MARK: Syncing

    /// Whether Prism keeps this graph in step itself: its own clone.
    private(set) var ownsSync = false
    private var roundTimer: Timer?
    private static let roundInterval: TimeInterval = 5 * 60
    /// What the sync last said, for the windows' rails.
    private(set) var syncStatus: SyncController.Status = .idle

    func ownSync(prepare: @escaping () async throws -> Void) {
        ownsSync = true
        sync.prepare = prepare
        sync.idle = 10
        sync.sync()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.ownsSync else { return }
                self.sync.sync(becauseActivated: true)
                self.startRounds()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.roundTimer?.invalidate()
                self?.roundTimer = nil
            }
        }
        startRounds()
    }

    private func startRounds() {
        roundTimer?.invalidate()
        roundTimer = Timer.scheduledTimer(withTimeInterval: Self.roundInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync.sync() }
        }
    }

    func syncForPush() {
        guard ownsSync else { return }
        sync.sync()
    }

    func endSync() {
        ownsSync = false
        roundTimer?.invalidate()
        roundTimer = nil
    }

    func finishSync() async {
        roundTimer?.invalidate()
        await sync.finish()
    }

    func syncNow() {
        guard graph.git != nil else { return showSync(.failed("This graph is not in a git repository")) }
        sync.sync()
    }

    private func applyHistory() {
        let index = index
        DispatchQueue.global(qos: .utility).async { [weak self] in
            ChangeHistory.apply(to: index)
            DispatchQueue.main.async { self?.windows.forEach { $0.refreshList() } }
        }
    }

    private func showSync(_ status: SyncController.Status) {
        syncStatus = status
        if case .synced = status { applyHistory() }
        windows.forEach { $0.showSync(status) }
        syncWindow?.syncChanged(status)
    }

    // MARK: Notes to review

    /// The notes holding both sides of a sync's conflict.
    private(set) var toReview: [String] = []

    func refreshReview() {
        let index = index
        Task.detached(priority: .utility) {
            let paths = index.conflicted()
            await MainActor.run { [weak self] in
                guard let self, paths != toReview else { return }
                toReview = paths
                windows.forEach { $0.showReview(paths) }
            }
        }
    }

    // MARK: The block it is now

    private var nowTimer: Timer?
    /// Today's note, as last read: what is on now is found in it each second.
    private var todaySource: (day: Day, source: String)?
    /// The block of today's on now, and how long is left of it.
    private(set) var now: NowPill.Now?

    private func startNow() {
        refreshNow()
        nowTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickNow() }
        }
    }

    private func refreshNow() {
        todaySource = (.today, graph.read(.today) ?? "")
        tickNow()
    }

    private func tickNow() {
        if todaySource?.day != .today { todaySource = (.today, graph.read(.today) ?? "") }
        now = todaySource.flatMap { TimeBlocksPage.current(in: $0.source) }.map { NowPill.Now(block: $0.block, remaining: $0.remaining) }
        windows.forEach { $0.tick(now) }
    }
}

extension Notification.Name {
    /// The face, or how it is set, changed.
    static let prismTypographyChanged = Notification.Name("PrismTypographyChanged")
}
