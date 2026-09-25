import AppKit
import ReflectCore

/// The window: the timeline, a toolbar, and how the sync is doing in the
/// subtitle.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate, NSMenuItemValidation {
    let graph: Graph
    let sync: SyncController
    let timeline: TimelineViewController
    private var watcher: DirectoryWatcher?
    private var statusTimer: Timer?

    static let fontSizeKey = "FontSize"
    static let defaultFontSize: CGFloat = 15

    init(graph: Graph, sync: SyncController) {
        self.graph = graph
        self.sync = sync
        let stored = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        let size = stored > 0 ? CGFloat(stored) : Self.defaultFontSize
        timeline = TimelineViewController(graph: graph, metrics: OutlineMetrics(fontSize: size))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = graph.root.lastPathComponent
        window.representedURL = graph.root
        window.minSize = NSSize(width: 420, height: 300)
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.contentViewController = timeline
        // A view controller's view sizes its window; the timeline has no
        // size of its own to give.
        window.setContentSize(NSSize(width: 900, height: 820))
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        window.setFrameAutosaveName("Main")
        if !window.setFrameUsingName("Main") { window.center() }

        timeline.onSave = { [weak self] in
            self?.sync.noteChanged()
            self?.refreshReview()
        }
        sync.flush = { [weak timeline] in timeline?.saveAll() }
        sync.onPulled = { [weak timeline] _ in timeline?.reloadFromDisk() }
        sync.onStatus = { [weak self] status in
            if case .synced = status { self?.refreshReview() }
            self?.showStatus()
        }
        sync.onConflicts = { [weak self] paths in self?.noteConflicts(paths) }
        sync.onLargeFiles = { [weak self] files in self?.showLargeFiles(files) }
        watcher = DirectoryWatcher(url: graph.root.appendingPathComponent(GraphPaths.dailyDirectory)) { [weak timeline] in
            timeline?.reloadFromDisk()
        }
        // "Synced 2 minutes ago" goes stale on its own.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.showStatus() }
        }
        showStatus()
        refreshReview()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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
            if state.consoleOpen == true { ConsoleWindowController.shared.show(); window?.makeKeyAndOrderFront(nil) }
            timeline.onScroll = { [weak self] in self?.noteState() }
            NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)),
                                                   name: NSTextView.didChangeSelectionNotification, object: nil)
        }
    }

    @objc private func selectionChanged(_ notification: Notification) {
        guard (notification.object as? NSView)?.window === window else { return }
        noteState()
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
        SessionState.shared.update(graph.root) { state in
            state.top = place
            // With the keyboard elsewhere — the console, a sheet — the last
            // caret stands.
            if let focus { state.focus = focus }
            state.consoleOpen = consoleOpen
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
        timeline.reloadFromDisk()
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
        timeline.saveAll()
        sync.commitAndPush()
    }

    @objc func goToToday(_ sender: Any?) { timeline.goToToday(sender) }

    /// Go ▸ Next Note Needing Review: the next day after this one whose note
    /// carries a conflict, round to the first.
    @objc func goToNextConflict(_ sender: Any?) {
        let days = needingReview.compactMap(GraphPaths.day(fromDailyPath:)).sorted()
        guard let first = days.first else { NSSound.beep(); return }
        timeline.focus(days.first(where: { $0 > timeline.currentDay }) ?? first)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(goToNextConflict(_:)) {
            return needingReview.contains { GraphPaths.day(fromDailyPath: $0) != nil }
        }
        return true
    }
    @objc func goToPreviousDay(_ sender: Any?) { timeline.goToPreviousDay(sender) }
    @objc func goToNextDay(_ sender: Any?) { timeline.goToNextDay(sender) }

    @objc func makeTextBigger(_ sender: Any?) { setFontSize(timeline.metrics.fontSize + 1) }
    @objc func makeTextSmaller(_ sender: Any?) { setFontSize(timeline.metrics.fontSize - 1) }
    @objc func makeTextStandardSize(_ sender: Any?) { setFontSize(Self.defaultFontSize) }

    private func setFontSize(_ size: CGFloat) {
        let size = min(max(size, 10), 32)
        UserDefaults.standard.set(Double(size), forKey: Self.fontSizeKey)
        timeline.metrics = OutlineMetrics(fontSize: size)
    }

    @objc func revealInFinder(_ sender: Any?) {
        let url = graph.url(for: timeline.currentDay)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([graph.root])
        }
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        timeline.saveAll()
    }

    // MARK: NSToolbarDelegate

    private static let todayItem = NSToolbarItem.Identifier("Today")
    private static let syncItemIdentifier = NSToolbarItem.Identifier("Sync")
    private weak var syncItem: NSToolbarItem?

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.todayItem, Self.syncItemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .space, Self.todayItem, Self.syncItemIdentifier]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.isBordered = true
        switch identifier {
        case Self.todayItem:
            item.label = "Today"
            item.toolTip = "Go to Today"
            item.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Today")
            item.action = #selector(goToToday(_:))
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
