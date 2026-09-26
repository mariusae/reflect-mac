import AppKit
import ReflectCore

/// The window: the timeline, a toolbar, and how the sync is doing in the
/// subtitle.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate, NSMenuItemValidation,
    NSToolbarItemValidation {
    let graph: Graph
    let sync: SyncController
    let timeline: TimelineViewController
    /// What the window shows: the timeline, a note, the split view.
    let workspace: WorkspaceController
    /// The graph's notes by name, for finding and following links.
    let index: NoteIndex
    private var watcher: DirectoryWatcher?
    private var notesWatcher: DirectoryWatcher?
    /// Reflect's own search index for the graph, when it keeps one.
    private lazy var searchIndex = ReflectSearchIndex(root: graph.root)
    /// The text in the graph's pictures, and what reads it.
    let pictureText: ImageTextReader
    private lazy var chooser: OpenQuickly = {
        let chooser = OpenQuickly(index: index, search: searchIndex, pictures: pictureText.index)
        chooser.onOpen = { [weak self] target, inSplit, found in self?.workspace.open(target, inSplit: inSplit, found: found) }
        return chooser
    }()
    private var statusTimer: Timer?
    /// The left column, and the split view that holds it beside the workspace.
    private(set) var sidebar: SidebarViewController!
    private let split = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!

    static let fontSizeKey = "FontSize"
    static let defaultFontSize: CGFloat = 15

    init(graph: Graph, sync: SyncController) {
        self.graph = graph
        self.sync = sync
        timeline = TimelineViewController(graph: graph, metrics: OutlineMetrics(typography: .current))
        index = NoteIndex(root: graph.root)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "ReflectMac").appendingPathComponent("PictureText")
        pictureText = ImageTextReader(index: ImageTextIndex(root: graph.root, cache: caches))
        workspace = WorkspaceController(graph: graph, timeline: timeline, index: index)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = graph.root.lastPathComponent
        window.representedURL = graph.root
        window.minSize = NSSize(width: 420, height: 300)
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        sidebar = SidebarViewController(index: index, search: ReflectSearchIndex(root: graph.root),
                                        pictures: pictureText.index, root: graph.root)
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        // Room for its four modes, with their margins.
        sidebarItem.minimumThickness = 260
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        split.addSplitViewItem(sidebarItem)
        let content = NSSplitViewItem(viewController: workspace)
        content.minimumThickness = WorkspaceController.mainMinimum
        // The main view gives way to the sidebar and the pane as the window narrows.
        content.holdingPriority = .init(rawValue: 250)
        split.addSplitViewItem(content)
        split.addSplitViewItem(workspace.sideItem)
        split.splitView.autosaveName = "MainSplit"
        window.contentViewController = split
        // A view controller's view sizes its window; the workspace has no
        // size of its own to give.
        window.setContentSize(NSSize(width: 1140, height: 820))
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        window.setFrameAutosaveName("Main")
        if !window.setFrameUsingName("Main") { window.center() }

        let saved: (NoteRef) -> Void = { [weak self] ref in
            guard let self else { return }
            sync.noteChanged()
            refreshReview()
            index.refresh(ref.path)
            pictureText.update()
            sidebarNeedsReload()
        }
        sidebar.onOpen = { [weak self] target, inSplit, found in self?.workspace.open(target, inSplit: inSplit, found: found) }
        sidebar.onPin = { [weak self] path, pinned in self?.setPinned(path, pinned) }
        sidebar.onReorder = { [weak self] pins in self?.renumberPins(pins) }
        NotificationCenter.default.addObserver(self, selector: #selector(typographyChanged(_:)), name: Typography.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged(_:)), name: NSText.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillTerminate(_:)), name: NSApplication.willTerminateNotification, object: nil)
        NotePaneController.index = index
        NotePaneController.onRetitle = { [weak self] ref, from, to in self?.retitle(ref, from: from, to: to) }
        NotePaneController.onLeave = { [weak self] ref, text in self?.leftBlank(ref, text) }
        NotePaneController.openBacklink = { [weak self] path, link, inSplit in
            self?.workspace.open(OpenQuickly.target(for: path), inSplit: inSplit, found: link.map { .words([$0]) })
        }
        sidebar.onTrash = { [weak self] path in self?.confirmTrash(path) }
        sidebar.onOpenInWindow = { [weak self] path in self?.openInWindow(path) }
        sidebar.onSetTask = { [weak self] task, done in self?.setTask(task, done: done) }
        timeline.onSave = saved
        workspace.onSave = saved
        workspace.onChange = { [weak self] in
            self?.showTitle()
            self?.showSideItems()
            self?.followFocus()
            self?.noteState()
        }
        sync.flush = { [weak self] in self?.saveAll() }
        sync.onPulled = { [weak self] _ in self?.reloadFromDisk() }
        sync.onStatus = { [weak self] status in
            if case .synced = status { self?.refreshReview() }
            self?.showStatus()
        }
        sync.onConflicts = { [weak self] paths in self?.noteConflicts(paths) }
        sync.onLargeFiles = { [weak self] files in self?.showLargeFiles(files) }
        watcher = DirectoryWatcher(url: graph.root.appendingPathComponent(GraphPaths.dailyDirectory)) { [weak self] in
            self?.reloadFromDisk()
        }
        notesWatcher = DirectoryWatcher(url: graph.root.appendingPathComponent(GraphPaths.notesDirectory)) { [weak self] in
            self?.reloadFromDisk()
        }
        rescan()
        // A `[[link]]`'s card shows the note it leads to.
        LinkCard.noteSource = { [weak self] title in
            guard let self, let path = index.resolve(title) else { return nil }
            return (NoteRef(path: path), graph.read(path: path) ?? "")
        }
        // `[[` in a note finds what the chooser finds.
        LinkCompletion.sources = SearchSources(index: index, search: searchIndex, pictures: pictureText.index)
        // "Synced 2 minutes ago" goes stale on its own.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.showStatus() }
        }
        showStatus()
        refreshReview()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Reads every note's name again, off the main thread.
    private func rescan() {
        let index = index
        Task.detached(priority: .utility) { [weak self] in
            index.scan()
            await self?.sidebarNeedsReload()
        }
        pictureText.update()
    }

    /// Takes in what changed on disk: notes on screen, and names.
    func reloadFromDisk() {
        workspace.reloadFromDisk()
        for window in noteWindows.values { window.reloadFromDisk() }
        rescan()
    }

    /// Everything open written: the window's notes, and those in windows of their own.
    func saveAll() {
        workspace.saveAll()
        for window in noteWindows.values { window.save() }
    }

    // MARK: Notes in windows of their own

    /// The notes open in windows of their own, by path.
    private(set) var noteWindows: [String: NoteWindowController] = [:]

    /// File ▸ Open in New Window: the note the keyboard is in.
    @objc func openNoteInNewWindow(_ sender: Any?) {
        guard let path = focusedNotePath else { NSSound.beep(); return }
        openInWindow(path)
    }

    /// A note in a window of its own — the one it is in already, if any.
    func openInWindow(_ path: String) {
        if let open = noteWindows[path] {
            open.show()
            return
        }
        let controller = NoteWindowController(ref: NoteRef(path: path), graph: graph, images: timeline.images, metrics: workspace.metrics)
        controller.onOpen = { [weak self] url, inSplit in
            guard let self else { return }
            window?.makeKeyAndOrderFront(nil)
            workspace.open(url, inSplit: inSplit)
        }
        controller.onSave = { [weak self] ref in
            guard let self else { return }
            sync.noteChanged()
            index.refresh(ref.path)
            sidebarNeedsReload()
            // The same note, open here too, catches up.
            workspace.reloadFromDisk()
        }
        controller.onClose = { [weak self] closed in
            guard let self, noteWindows[closed.ref.path] === closed else { return }
            noteWindows[closed.ref.path] = nil
            if !terminating { rememberNoteWindows() }
        }
        noteWindows[path] = controller
        controller.show()
        rememberNoteWindows()
    }

    private var terminating = false

    @objc private func appWillTerminate(_ notification: Notification) {
        terminating = true
        saveAll()
    }

    private func rememberNoteWindows() {
        let paths = noteWindows.keys.sorted()
        SessionState.shared.update(graph.root) { $0.noteWindows = paths }
    }

    /// A note moved — renamed — followed in its window.
    private func noteWindowMoved(from old: String, to new: String) {
        guard let window = noteWindows.removeValue(forKey: old) else { return }
        noteWindows[new] = window
        window.moved(to: NoteRef(path: new))
        rememberNoteWindows()
    }

    // MARK: The sidebar

    private var sidebarReload: DispatchWorkItem?

    /// Reads the sidebar again, once things settle.
    private func sidebarNeedsReload() {
        sidebarReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.sidebar.reload()
                self?.sidebar.refreshSearch()
                // Links may have come or gone.
                self?.sidebar.follow(self?.sidebar.linked, force: true)
                self?.workspace.refreshBacklinks()
            }
        }
        sidebarReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        split.toggleSidebar(sender)
    }

    /// View ▸ Pinned, Search, Tags: the sidebar in that mode, shown if it was not.
    @objc func showSidebarMode(_ sender: NSMenuItem) {
        if sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }
        sidebar.show(SidebarViewController.Mode(rawValue: sender.tag) ?? .notes)
    }

    /// Find ▸ Search All Notes: the sidebar's search, shown if it was not.
    @objc func searchAllNotes(_ sender: Any?) {
        if sidebarItem.isCollapsed {
            sidebarItem.animator().isCollapsed = false
        }
        sidebar.focusSearch()
    }

    // MARK: Progress

    /// The ring for a note's tasks and checklist items: shown when it has
    /// some, filled with the share done.
    func showProgress(of editor: OutlineTextView?) {
        progressEditor = editor
        let progress = editor?.checkboxProgress
        if let progress { progressRing.progress = progress }
        // In the toolbar only when there is progress to show — in a capsule
        // of its own, before the note's tools: a capsule is measured when it
        // is made, and does not grow for an item put into it afterwards.
        guard let toolbar = window?.toolbar else { return }
        let shown = toolbar.items.firstIndex { $0.itemIdentifier == Self.progressItem }
        if progress != nil, shown == nil, let note = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.noteItem }) {
            toolbar.insertItem(withItemIdentifier: .space, at: note)
            toolbar.insertItem(withItemIdentifier: Self.progressItem, at: note)
        } else if progress == nil, let shown {
            toolbar.removeItem(at: shown)
            if shown < toolbar.items.count, toolbar.items[shown].itemIdentifier == .space { toolbar.removeItem(at: shown) }
        }
    }

    @objc private func textChanged(_ notification: Notification) {
        guard let editor = notification.object as? OutlineTextView, editor.window === window else { return }
        showProgress(of: editor)
    }

    /// The ring clicked: the next task or checklist item not done.
    @objc func goToNextUnfinished(_ sender: Any?) {
        guard let editor = progressEditor ?? window?.firstResponder as? OutlineTextView else { NSSound.beep(); return }
        window?.makeFirstResponder(editor)
        if !editor.goToNextUnfinished() { NSSound.beep() }
    }

    /// The sidebar's backlinks follow the note the keyboard is in.
    private func followFocus() {
        sidebar.follow(focusedNotePath)
    }

    /// The note the keyboard is in: its path.
    private var focusedNotePath: String? {
        var view = window?.firstResponder as? NSView
        while let current = view {
            if let day = current as? DayView { return day.ref.path }
            view = current.superview
        }
        return workspace.current?.path
    }

    /// File ▸ Pin Note: pins the note the keyboard is in, or unpins it.
    @objc func togglePinned(_ sender: Any?) {
        guard let path = focusedNotePath else { NSSound.beep(); return }
        setPinned(path, index.entry(path)?.pin == nil)
    }

    /// The note the keyboard is in, shown in the Finder.
    @objc func revealNoteInFinder(_ sender: Any?) {
        guard let path = focusedNotePath, graph.exists(path: path) else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([graph.root.appendingPathComponent(path)])
    }

    /// File ▸ Move Note to Trash: the note the keyboard is in.
    @objc func trashNote(_ sender: Any?) {
        guard let path = focusedNotePath else { NSSound.beep(); return }
        confirmTrash(path)
    }

    /// Asks, then moves a note to the Trash — as Reflect deletes notes: the
    /// file is recoverable from the Trash, and gone from the graph, and so
    /// from other devices once this Mac syncs. Daily notes are not deleted.
    func confirmTrash(_ path: String) {
        guard GraphPaths.day(fromDailyPath: path) == nil, graph.exists(path: path), let window else { NSSound.beep(); return }
        let title = index.entry(path)?.title ?? path
        let alert = NSAlert()
        alert.messageText = "Move “\(title)” to the Trash?"
        alert.informativeText = "You can take it back out of the Trash. Your other devices lose it when this Mac next syncs."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                self?.trash(path)
            }
        }
    }

    func trash(_ path: String) {
        saveAll()
        workspace.forget(path)
        noteWindows[path]?.closeDiscarding()
        do {
            try FileManager.default.trashItem(at: graph.root.appendingPathComponent(path), resultingItemURL: nil)
        } catch {
            Log.shared.error("files", "Could not move \(path) to the Trash", detail: error.localizedDescription)
            presentError(error)
            return
        }
        Log.shared.info("files", "Moved \(path) to the Trash")
        index.refresh(path)
        sync.noteChanged()
        sidebar.reload()
        sidebar.refreshSearch()
    }

    // MARK: New notes

    /// Blank notes made here and not yet named.
    private var blankNotes = Set<String>()

    /// File ▸ New Note: a blank note, the caret in its title. Its file is
    /// named for its title once the title settles; left blank, it goes.
    @objc func newNote(_ sender: Any?) {
        do {
            let path = try NoteCreation.createBlank(in: graph.root)
            blankNotes.insert(path)
            index.refresh(path)
            Log.shared.info("files", "Made a new note", detail: path)
            workspace.show(NoteRef(path: path), inSplit: false)
        } catch {
            Log.shared.error("files", "Could not make a new note", detail: error.localizedDescription)
            presentError(error)
        }
    }

    /// A blank note left as it was made — no title, nothing written — is
    /// taken away again.
    private func leftBlank(_ ref: NoteRef, _ text: String) {
        guard blankNotes.contains(ref.path) else { return }
        let outline = OutlineMarkdown.parse(text)
        guard TitleRename.authoredTitle(path: ref.path, source: text) == nil, Backlinks.isEmpty(outline.rows) else { return }
        blankNotes.remove(ref.path)
        try? FileManager.default.removeItem(at: graph.root.appendingPathComponent(ref.path))
        index.refresh(ref.path)
        Log.shared.info("files", "Took away a new note left blank", detail: ref.path)
        sidebarNeedsReload()
    }

    // MARK: Renames

    /// The aliases each note's last rename added, and the title it left the
    /// note with: a rename from that title goes on the chain, and prunes them.
    private var renameChains: [String: (title: String, added: [String])] = [:]

    /// A note's title settled on a new one: as Reflect does — the links to
    /// it follow, its old title stays on as an alias, and a note Reflect
    /// manages moves to the file its title names. A note that had no title
    /// (`from` nil) only moves: nothing links to a title never had.
    func retitle(_ ref: NoteRef, from: String?, to: String) {
        // Named, a new note is kept.
        blankNotes.remove(ref.path)
        saveAll()
        var path = ref.path
        guard graph.exists(path: path) else { return }
        var changed = false
        if let from {
            let result = index.retitleLinks(to: path, from: from, to: to, read: graph.read(path:),
                                             write: { [graph] text, source in try graph.write(text, path: source) })
            changed = !result.rewritten.isEmpty
            var summary = "Renamed “\(from)” to “\(to)”"
            if !result.rewritten.isEmpty { summary += ": links in \(result.rewritten.count) \(result.rewritten.count == 1 ? "note" : "notes") follow" }
            var detail: [String] = result.rewritten
            if result.collision { detail.append("“\(from)” is another note’s now: links to it are left alone.") }
            if result.destinationBlocked { detail.append("“\(to)” is another note’s: links were not repointed; the old title keeps them here.") }
            if !result.failed.isEmpty {
                Log.shared.warning("files", "Could not update links in \(result.failed.count) notes", detail: result.failed.joined(separator: "\n"))
            }
            Log.shared.info("files", summary, detail: detail.isEmpty ? nil : detail.joined(separator: "\n"))

            // The old title, kept as an alias — unless it is another note's.
            let chain = renameChains[path]
            let previous = chain?.title == from ? chain?.added ?? [] : []
            renameChains[path] = (to, [])
            if !result.collision, let source = graph.read(path: path) {
                let current = TitleRename.aliases(in: source)
                if let aliases = TitleRename.nextAliases(current, from: from, to: to, previousAutoAliases: previous) {
                    do {
                        try graph.write(Frontmatter.setting("aliases", toList: aliases, in: source), path: path)
                        renameChains[path] = (to, TitleRename.added(current, aliases))
                        changed = true
                    } catch {
                        Log.shared.error("files", "Could not keep “\(from)” as an alias of \(path)", detail: error.localizedDescription)
                    }
                }
            }
            index.refresh(path)
        }

        // The file follows the title, for a note Reflect manages.
        if let source = graph.read(path: path), TitleRename.isManaged(path: path, source: source) {
            let destination = index.managedPath(for: to, current: path)
            if destination != path {
                do {
                    try FileManager.default.moveItem(at: graph.root.appendingPathComponent(path),
                                                     to: graph.root.appendingPathComponent(destination))
                    Log.shared.info("files", "Moved \(path) to \(destination)")
                    index.refresh(path)
                    index.refresh(destination)
                    SessionState.shared.moved(graph.root, from: NoteRef(path: path), to: NoteRef(path: destination))
                    if let chain = renameChains.removeValue(forKey: path) { renameChains[destination] = chain }
                    workspace.moved(from: path, to: destination)
                    noteWindowMoved(from: path, to: destination)
                    path = destination
                    changed = true
                } catch {
                    Log.shared.error("files", "Could not move \(path) to \(destination)", detail: error.localizedDescription)
                }
            }
        }
        guard changed else { return }
        workspace.reloadFromDisk()
        sync.noteChanged()
        sidebarNeedsReload()
    }

    /// A task ticked, or unticked, from the Tasks list: written in its note,
    /// and everything showing the note caught up.
    func setTask(_ task: NoteTask, done: Bool) {
        saveAll()
        guard let source = graph.read(path: task.notePath),
              let updated = Tasks.setting(done: done, ordinal: task.ordinal, in: source) else { NSSound.beep(); return }
        do {
            try graph.write(updated, path: task.notePath)
        } catch {
            Log.shared.error("files", "Could not tick a task in \(task.notePath)", detail: error.localizedDescription)
            presentError(error)
            return
        }
        index.refresh(task.notePath)
        workspace.reloadFromDisk()
        for window in noteWindows.values { window.reloadFromDisk() }
        sync.noteChanged()
        sidebar.refreshTasks()
    }

    /// File ▸ Topic Note: makes the note the keyboard is in a topic —
    /// `topic: true`, its backlinks shown after it — or no longer one.
    @objc func toggleTopic(_ sender: Any?) {
        guard let path = focusedNotePath else { NSSound.beep(); return }
        setFrontmatter(path, "topic", index.entry(path)?.isTopic == true ? nil : "true", verb: "Made a topic of")
        workspace.refreshBacklinks()
    }

    /// Sets or takes away a frontmatter key of a note, and has everything
    /// that shows it catch up.
    private func setFrontmatter(_ path: String, _ key: String, _ value: String?, verb: String) {
        saveAll()
        guard let source = graph.read(path: path) else { NSSound.beep(); return }
        let updated = Frontmatter.setting(key, to: value, in: source)
        guard updated != source else { return }
        do {
            try graph.write(updated, path: path)
        } catch {
            Log.shared.error("files", "Could not change \(path)", detail: error.localizedDescription)
            presentError(error)
            return
        }
        Log.shared.info("files", "\(value == nil ? "Set back" : verb) \(path)", detail: "\(key): \(value ?? "—")")
        index.refresh(path)
        workspace.reloadFromDisk()
        sync.noteChanged()
        sidebar.reload()
    }

    /// Pins a note, after every other, as Reflect does — `pinned:` in its
    /// frontmatter — or takes its pin away.
    func setPinned(_ path: String, _ pinned: Bool) {
        saveAll()
        guard let source = graph.read(path: path) else { NSSound.beep(); return }
        let updated = Frontmatter.setting("pinned", to: pinned ? String(index.nextPinOrder) : nil, in: source)
        guard updated != source else { return }
        do {
            try graph.write(updated, path: path)
        } catch {
            Log.shared.error("files", "Could not \(pinned ? "pin" : "unpin") \(path)", detail: error.localizedDescription)
            presentError(error)
            return
        }
        Log.shared.info("files", "\(pinned ? "Pinned" : "Unpinned") \(path)")
        index.refresh(path)
        workspace.reloadFromDisk()
        sync.noteChanged()
        sidebar.reload()
    }

    /// Gives pinned notes new numbers — `pinned:` in each — putting the
    /// shelf in a new order, as Reflect's sidebar does when one is dragged.
    func renumberPins(_ pins: [PinOrder.Pin]) {
        saveAll()
        for pin in pins {
            guard let order = pin.order, let source = graph.read(path: pin.path) else { continue }
            let updated = Frontmatter.setting("pinned", to: String(order), in: source)
            guard updated != source else { continue }
            do {
                try graph.write(updated, path: pin.path)
                index.refresh(pin.path)
            } catch {
                Log.shared.error("files", "Could not reorder \(pin.path)", detail: error.localizedDescription)
                presentError(error)
            }
        }
        Log.shared.info("files", "Reordered the pinned notes", detail: pins.map { "\($0.path): \($0.order ?? 0)" }.joined(separator: "\n"))
        workspace.reloadFromDisk()
        sync.noteChanged()
        sidebar.reload()
    }

    private func showTitle() {
        window?.title = workspace.noteTitle ?? graph.root.lastPathComponent
    }

    private var restored = false

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !restored else { return }
        restored = true
        // Once the window has its size, so that the day lands where it should.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let state = SessionState.shared.graph(graph.root)
            timeline.restore(state.top, focus: state.focus)
            // The note that was open, and the one in the split view.
            if let path = state.mainNote, graph.exists(path: path) { workspace.show(NoteRef(path: path), inSplit: false) }
            if let path = state.splitNote, graph.exists(path: path) {
                workspace.show(NoteRef(path: path), inSplit: true)
            } else {
                // The window's saved layout may have the pane open, with nothing for it.
                workspace.sideItem.isCollapsed = true
            }
            // The notes that were open in windows of their own.
            for path in state.noteWindows ?? [] where graph.exists(path: path) { openInWindow(path) }
            window?.makeKeyAndOrderFront(nil)
            if state.consoleOpen == true { ConsoleWindowController.shared.show(); window?.makeKeyAndOrderFront(nil) }
            timeline.onScroll = { [weak self] in self?.noteState() }
            NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)),
                                                   name: NSTextView.didChangeSelectionNotification, object: nil)
        }
    }

    @objc private func selectionChanged(_ notification: Notification) {
        guard (notification.object as? NSView)?.window === window else { return }
        if let editor = notification.object as? OutlineTextView { showProgress(of: editor) }
        noteState()
        followFocus()
    }

    private var stateTimer: Timer?

    /// Notes where the app is a moment after it stops moving.
    private func noteState() {
        stateTimer?.invalidate()
        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordState() }
        }
    }

    /// Notes where the app is, now.
    func recordState() {
        stateTimer?.invalidate()
        guard restored else { return }
        let place = timeline.place
        let focus = timeline.focusedSelection
        let consoleOpen = ConsoleWindowController.shared.window?.isVisible == true
        let mainNote = workspace.current?.path
        let splitNote = workspace.split?.ref.path
        SessionState.shared.update(graph.root) { state in
            state.top = place
            // With the keyboard elsewhere — the console, a sheet — the last
            // caret stands.
            if let focus { state.focus = focus }
            state.consoleOpen = consoleOpen
            state.mainNote = mainNote
            state.splitNote = splitNote
        }
    }

    // MARK: Status

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// The notes a merge left for review, as last looked.
    private var needingReview: [String] = []

    private func refreshReview() {
        let graph = graph
        Task.detached {
            let paths = graph.notesNeedingReview()
            await MainActor.run { [weak self] in
                self?.needingReview = paths
                self?.showStatus()
            }
        }
    }

    private func showStatus() {
        defer {
            if !needingReview.isEmpty, let subtitle = window?.subtitle {
                let count = needingReview.count == 1 ? "1 note needs review" : "\(needingReview.count) notes need review"
                window?.subtitle = subtitle.isEmpty ? count : "\(subtitle) · \(count)"
            }
        }
        switch sync.status {
        case .idle: window?.subtitle = ""
        case .syncing: window?.subtitle = "Syncing…"
        case .synced(let date):
            window?.subtitle = Date().timeIntervalSince(date) < 60
                ? "Synced just now"
                : "Synced " + Self.relative.localizedString(for: date, relativeTo: Date())
        case .failed(let message):
            // Git's own words, without the command that drew them; the
            // console has the rest.
            var reason = message.split(separator: "\n").first.map(String.init) ?? message
            if let fatal = reason.range(of: "fatal: ") { reason = String(reason[fatal.upperBound...]) }
            else if let colon = reason.range(of: ": ", options: .backwards) { reason = String(reason[colon.upperBound...]) }
            window?.subtitle = "Sync failed: \(reason)"
        case .unavailable: window?.subtitle = "Not in a git repository"
        }
        syncItem?.isEnabled = sync.git != nil
        // A failed sync turns the sync button into a warning, which opens
        // the console with what happened.
        if case .failed(let message) = sync.status {
            syncItem?.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Sync Failed")?
                .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
            syncItem?.label = "Sync Failed"
            syncItem?.toolTip = message + "\n\nClick to see the console."
            syncItem?.action = #selector(showConsole(_:))
        } else {
            syncItem?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Sync")
            syncItem?.label = "Sync"
            syncItem?.toolTip = "Sync Now"
            syncItem?.action = #selector(syncNow(_:))
        }
    }

    /// Notes a merge left for review. Nothing interrupts: each day that has
    /// one says so where it is, and the subtitle says how many there are.
    private func noteConflicts(_ paths: [String]) {
        reloadFromDisk()
        showStatus()
    }

    private func showLargeFiles(_ files: [(path: String, size: Int)]) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = files.count == 1 ? "A file is too large to back up" : "Some files are too large to back up"
        let sizes = files.map { "\($0.path) (\(ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file)))" }
        alert.informativeText = "\(sizes.joined(separator: ", ")) \(files.count == 1 ? "is" : "are") left out of the backup: files of 95 MB or more cannot be pushed. Everything else is backed up."
        alert.beginSheetModal(for: window)
    }

    // MARK: Actions

    @objc func syncNow(_ sender: Any?) { sync.sync() }

    @objc func showConsole(_ sender: Any?) { ConsoleWindowController.shared.show() }

    @objc func saveDocument(_ sender: Any?) {
        saveAll()
        sync.commitAndPush()
    }

    @objc func goToToday(_ sender: Any?) { workspace.showToday() }

    // MARK: The calendar

    private weak var calendarItem: NSToolbarItem?
    private var calendarPopover: NSPopover?

    /// Go ▸ Go to Date…, and the toolbar's calendar: a month dropped down,
    /// the days with notes dotted; a day picked is gone to.
    @objc func showCalendar(_ sender: Any?) {
        if let open = calendarPopover, open.isShown {
            open.performClose(sender)
            return
        }
        let current = workspace.current?.day ?? timeline.currentDay
        let picker = CalendarPickerView(selected: current)
        picker.marked = Set(index.all.compactMap(\.day))
        let controller = NSViewController()
        controller.view = picker
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = CalendarPickerView.size
        popover.behavior = .transient
        popover.animates = true
        picker.onPick = { [weak self, weak popover] day, inSplit in
            popover?.performClose(nil)
            self?.workspace.show(.day(day), inSplit: inSplit)
        }
        calendarPopover = popover
        if let item = calendarItem, window?.toolbar?.isVisible == true, window?.toolbar?.items.contains(item) == true {
            popover.show(relativeTo: item)
        } else if let view = window?.contentView {
            // No calendar in the toolbar: from the top of the window.
            popover.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.maxY - 60, width: 1, height: 1), of: view, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeFirstResponder(picker)
    }

    /// File ▸ Open: the chooser.
    @objc func openQuickly(_ sender: Any?) { chooser.show(over: window) }

    @objc func goBack(_ sender: Any?) { workspace.goBack(sender) }
    @objc func goForward(_ sender: Any?) { workspace.goForward(sender) }
    @objc func closeSplitView(_ sender: Any?) { workspace.closeSplit() }
    @objc func sideBack(_ sender: Any?) { workspace.side.goBack(sender) }
    @objc func sideForward(_ sender: Any?) { workspace.side.goForward(sender) }

    /// The pane's part of the toolbar: there with the pane, gone without
    /// it — its space and all, so the window's own tools keep to the right.
    private static let sidePart: [NSToolbarItem.Identifier] =
        [sideSeparator, sideBackItem, sideForwardItem, sideTitleItem, .flexibleSpace, sideCloseItem]

    private func showSideItems() {
        let open = workspace.split != nil
        if let toolbar = window?.toolbar {
            let present = toolbar.items.contains { $0.itemIdentifier == Self.sideSeparator }
            if open && !present {
                for identifier in Self.sidePart {
                    toolbar.insertItem(withItemIdentifier: identifier, at: toolbar.items.count)
                }
            } else if !open && present, let start = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.sideSeparator }) {
                for index in (start..<toolbar.items.count).reversed() { toolbar.removeItem(at: index) }
            }
            for item in toolbar.items where Self.sideItems.contains(item.itemIdentifier) { item.isHidden = !open }
        }
        sideTitle.stringValue = open ? workspace.side.noteTitle : ""
        window?.toolbar?.validateVisibleItems()
    }

    /// Go ▸ Next Note Needing Review: the next day after this one whose note
    /// carries a conflict, round to the first.
    @objc func goToNextConflict(_ sender: Any?) {
        let days = needingReview.compactMap(GraphPaths.day(fromDailyPath:)).sorted()
        guard let first = days.first else { NSSound.beep(); return }
        timeline.focus(days.first(where: { $0 > timeline.currentDay }) ?? first)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): workspace.canGoBack
        case #selector(goForward(_:)): workspace.canGoForward
        case #selector(sideBack(_:)): workspace.side.canGoBack
        case #selector(sideForward(_:)): workspace.side.canGoForward
        case #selector(syncNow(_:)): sync.git != nil
        default: true
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(goToNextConflict(_:)) {
            return needingReview.contains { GraphPaths.day(fromDailyPath: $0) != nil }
        }
        if item.action == #selector(goBack(_:)) { return workspace.canGoBack }
        if item.action == #selector(goForward(_:)) { return workspace.canGoForward }
        if item.action == #selector(closeSplitView(_:)) { return workspace.split != nil }
        if item.action == #selector(showSidebarMode(_:)) {
            item.state = !sidebarItem.isCollapsed && sidebar.mode.rawValue == item.tag ? .on : .off
        }
        if item.action == #selector(toggleSidebar(_:)) {
            item.title = sidebarItem.isCollapsed ? "Show Sidebar" : "Hide Sidebar"
        }
        if item.action == #selector(openNoteInNewWindow(_:)) {
            return focusedNotePath.map(graph.exists(path:)) ?? false
        }
        if item.action == #selector(revealNoteInFinder(_:)) {
            return focusedNotePath.map(graph.exists(path:)) ?? false
        }
        if item.action == #selector(trashNote(_:)) {
            guard let path = focusedNotePath else { return false }
            return GraphPaths.day(fromDailyPath: path) == nil && graph.exists(path: path)
        }
        if item.action == #selector(toggleTopic(_:)) {
            guard let path = focusedNotePath, graph.read(path: path) != nil else {
                item.state = .off
                return false
            }
            item.state = index.entry(path)?.isTopic == true ? .on : .off
            return true
        }
        if item.action == #selector(togglePinned(_:)) {
            guard let path = focusedNotePath, graph.read(path: path) != nil else {
                item.title = "Pin Note"
                return false
            }
            item.title = index.entry(path)?.pin == nil ? "Pin Note" : "Unpin Note"
        }
        return true
    }
    @objc func goToPreviousDay(_ sender: Any?) {
        if workspace.current != nil { workspace.showToday() }
        timeline.goToPreviousDay(sender)
    }

    @objc func goToNextDay(_ sender: Any?) {
        if workspace.current != nil { workspace.showToday() }
        timeline.goToNextDay(sender)
    }

    @objc func makeTextBigger(_ sender: Any?) { setFontSize(timeline.metrics.fontSize + 1) }
    @objc func makeTextSmaller(_ sender: Any?) { setFontSize(timeline.metrics.fontSize - 1) }
    @objc func makeTextStandardSize(_ sender: Any?) { setFontSize(Self.defaultFontSize) }

    private func setFontSize(_ size: CGFloat) {
        var typography = Typography.current
        typography.size = min(max(size, Typography.sizes.lowerBound), Typography.sizes.upperBound)
        // Told to every window, this one too.
        Typography.current = typography
    }

    @objc private func typographyChanged(_ notification: Notification) {
        workspace.metrics = OutlineMetrics(typography: .current)
        for window in noteWindows.values { window.metrics = workspace.metrics }
    }

    @objc func revealInFinder(_ sender: Any?) {
        let url = graph.url(for: workspace.current?.path ?? GraphPaths.dailyPath(for: timeline.currentDay))
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([graph.root])
        }
    }

    // MARK: NSWindowDelegate

    /// ⌘W puts the split view away first, and closes the window after.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard workspace.split == nil else {
            workspace.closeSplit()
            return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        saveAll()
    }

    // MARK: NSToolbarDelegate

    private static let todayItem = NSToolbarItem.Identifier("Today")
    private static let syncItemIdentifier = NSToolbarItem.Identifier("Sync")
    private weak var syncItem: NSToolbarItem?

    private static let backItem = NSToolbarItem.Identifier("Back")
    private static let forwardItem = NSToolbarItem.Identifier("Forward")
    private static let openItem = NSToolbarItem.Identifier("Open")
    private static let noteItem = NSToolbarItem.Identifier("Note")
    private static let progressItem = NSToolbarItem.Identifier("Progress")
    private let progressRing = ProgressRingButton()
    /// The editor last written in: the note the progress is of.
    private weak var progressEditor: OutlineTextView?
    /// Where the toolbar parts, over the split view's dividers — the
    /// sidebar's and the pane's — tied to them, so they move together.
    private static let sidebarSeparator = NSToolbarItem.Identifier("SidebarSeparator")
    private static let sideSeparator = NSToolbarItem.Identifier("SideSeparator")
    /// Over the pane on the right: its way back and forward, title, and close.
    private static let sideBackItem = NSToolbarItem.Identifier("SideBack")
    private static let sideForwardItem = NSToolbarItem.Identifier("SideForward")
    private static let sideTitleItem = NSToolbarItem.Identifier("SideTitle")
    private static let sideCloseItem = NSToolbarItem.Identifier("SideClose")
    private static let sideItems = [sideBackItem, sideForwardItem, sideTitleItem, sideCloseItem]
    private let sideTitle = NSTextField(labelWithString: "")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, Self.sidebarSeparator, Self.backItem, Self.forwardItem, .flexibleSpace, Self.noteItem, Self.openItem,
         Self.todayItem, Self.syncItemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, Self.sidebarSeparator, Self.backItem, Self.forwardItem, .flexibleSpace, .space, Self.progressItem, Self.noteItem, Self.openItem,
         Self.todayItem, Self.syncItemIdentifier, Self.sideSeparator] + Self.sideItems
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == Self.sidebarSeparator || identifier == Self.sideSeparator {
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: split.splitView,
                                                  dividerIndex: identifier == Self.sidebarSeparator ? 0 : 1)
        }
        if identifier == Self.progressItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Progress"
            item.view = progressRing
            progressRing.target = self
            progressRing.action = #selector(goToNextUnfinished(_:))
            item.isBordered = true
            item.visibilityPriority = .high
            return item
        }
        if identifier == Self.noteItem {
            // What can be done to the note the keyboard is in.
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = "Note"
            item.toolTip = "Pin, Make a Topic, or Delete This Note"
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Note")
            item.showsIndicator = false
            let menu = NSMenu()
            menu.addItem(withTitle: "Pin Note", action: #selector(togglePinned(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Topic Note", action: #selector(toggleTopic(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Open in New Window", action: #selector(openNoteInNewWindow(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Show in Finder", action: #selector(revealNoteInFinder(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Move Note to Trash…", action: #selector(trashNote(_:)), keyEquivalent: "")
            for entry in menu.items { entry.target = self }
            item.menu = menu
            return item
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.isBordered = true
        if Self.sideItems.contains(identifier) {
            item.isHidden = workspace.split == nil
        }
        switch identifier {
        case Self.sideBackItem, Self.sideForwardItem:
            let isBack = identifier == Self.sideBackItem
            item.label = isBack ? "Back" : "Forward"
            item.toolTip = isBack ? "Back in the Split View" : "Forward in the Split View"
            item.image = NSImage(systemSymbolName: isBack ? "chevron.left" : "chevron.right", accessibilityDescription: item.label)
            item.action = isBack ? #selector(sideBack(_:)) : #selector(sideForward(_:))
        case Self.sideTitleItem:
            sideTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            sideTitle.lineBreakMode = .byTruncatingTail
            sideTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            item.view = sideTitle
            item.label = "Title"
            item.isBordered = false
            // It takes what room the pane's toolbar has.
            item.visibilityPriority = .low
            return item
        case Self.sideCloseItem:
            item.label = "Close"
            item.toolTip = "Close Split View"
            item.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Split View")
            item.action = #selector(closeSplitView(_:))
        case Self.backItem, Self.forwardItem:
            let isBack = identifier == Self.backItem
            item.label = isBack ? "Back" : "Forward"
            item.toolTip = isBack ? "Back (⌘[)" : "Forward (⌘])"
            item.image = NSImage(systemSymbolName: isBack ? "chevron.left" : "chevron.right", accessibilityDescription: item.label)
            item.action = isBack ? #selector(goBack(_:)) : #selector(goForward(_:))
            item.isNavigational = true
        case Self.openItem:
            item.label = "Open"
            item.toolTip = "Open a Note or a Day (⌘O)"
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Open")
            item.action = #selector(openQuickly(_:))
        case Self.todayItem:
            item.label = "Calendar"
            item.toolTip = "Go to a Day (⇧⌘T)"
            item.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Calendar")
            item.action = #selector(showCalendar(_:))
            calendarItem = item
        case Self.syncItemIdentifier:
            item.label = "Sync"
            item.toolTip = "Sync Now"
            item.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Sync")
            item.action = #selector(syncNow(_:))
            syncItem = item
        default:
            return nil
        }
        item.target = self
        return item
    }
}

/// Calls back when files come and go in a directory — which is how an
/// atomic save by another app, or a checkout, shows itself.
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            self?.pending?.cancel()
            let work = DispatchWorkItem { MainActor.assumeIsolated { onChange() } }
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}
