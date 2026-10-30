import AppKit
import WebKit
import ReflectCore
import ReflectUI
import PrismCore

/// A window on the graph: the list the lens chosen gathers, on glass at its
/// left, the lenses along its top — or, put away, on a capsule at the foot —
/// and the note, the whole height, its controls floating over its top — or
/// two side by side, the second opened with ⌘ held. As many windows as
/// wanted, each its own.
final class PrismWindow: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// What a window was left showing, to show again.
    struct State: Codable {
        var lens: Lens = .daily
        var listShown = true
        var panes: [PaneHistory] = [PaneHistory(PanePlace(.day(.today)))]
        var active = 0
        var frame: String?
        var query: String?
        /// The link note whose page is read beside it.
        var reader: String?
    }

    let session: Session
    private let root = WindowRoot()
    private let lenses = LensSwitcher()
    /// By the window's buttons: the list out, or put away.
    private let sidebarButton = CloseButton(symbol: "sidebar.left", pointSize: 14, toolTip: "Show or Hide the List (⌥⌘L)")
    /// Under it, the list put away: glass, as the panes' controls have.
    private let sidebarGlass = GlassCapsule()
    /// Behind the list: glass, inset from the window's edges.
    private let listGlass = NSGlassEffectView()
    private let list = LensList()
    private var panes: [NotePane] = []
    /// A link note's page, read in a column at its pane's right.
    private var reader: ReaderPane?
    private weak var readerOwner: NotePane?
    private var activeIndex = 0
    private(set) var lens: Lens = .daily
    private var listShown = true
    private let commandBar = Finder()
    /// The note whose headings ⌘K's `#` lists.
    private weak var headingPane: NotePane?
    private var responderWatch: NSKeyValueObservation?
    /// A mouse's back and forward buttons, over this window.
    private var mouseButtons: Any?
    private var searchQuery = ""

    private var activePane: NotePane { panes[min(activeIndex, panes.count - 1)] }

    init(session: Session, state: State?) {
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Ink.paper
        window.minSize = NSSize(width: 560, height: 360)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = root
        root.layoutHandler = { [weak self] in self?.layoutWindow() }
        root.addSubview(listGlass)
        root.addSubview(list)
        root.addSubview(lenses)
        root.addSubview(sidebarGlass)
        root.addSubview(sidebarButton)
        sidebarButton.contentTintColor = Ink.text
        sidebarButton.target = self
        sidebarButton.action = #selector(toggleList(_:))

        let state = state ?? State()
        lens = state.lens
        listShown = state.listShown
        searchQuery = state.query ?? ""
        list.query = searchQuery
        for history in state.panes.prefix(2) {
            let pane = makePane(history.current)
            pane.restore(history)
        }
        if panes.isEmpty { _ = makePane(PanePlace(.day(.today))) }
        activeIndex = min(max(0, state.active), panes.count - 1)
        if let path = state.reader {
            openReader(path, beside: panes.first { $0.place.path == path } ?? activePane, focus: false)
        }
        if let frame = state.frame {
            window.setFrame(NSRectFromString(frame), display: false)
        } else if let front = session.frontWindow?.window, front !== window {
            window.setFrame(front.frame.offsetBy(dx: 28, dy: -28), display: false)
        } else {
            window.center()
        }

        lenses.onLens = { [weak self] lens in self?.choose(lens) }
        list.face = session.face
        list.typography = session.face.typography()
        list.onChoose = { [weak self] item, beside in self?.open(item.path, beside: beside, fromList: true) }
        list.onCheck = { [weak self] item in self?.check(item) }
        list.onSearch = { [weak self] query in
            self?.searchQuery = query
            self?.refreshList()
            self?.session.writeWindows()
        }
        list.onEnter = { [weak self] in self?.activePane.focusNote() }
        list.onDay = { [weak self] day in self?.showDay(day) }
        list.onWeek = { [weak self] week in self?.open(GraphPaths.weeklyPath(for: week)) }
        commandBar.placeholder = "Go to a note, a day, or # a heading"
        commandBar.hintText = "↩ Open   ⌘↩ Beside"
        commandBar.search = { [weak self] query in self?.commandResults(query) ?? [] }
        commandBar.onChoose = { [weak self] place, beside in
            self?.closeCommandBar()
            self?.go(to: place, beside: beside)
        }
        commandBar.onClose = { [weak self] in self?.closeCommandBar() }

        mouseButtons = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self, event.window === self.window, [3, 4].contains(event.buttonNumber) else { return event }
            self.mouseStep(event.buttonNumber == 3 ? -1 : 1, at: event.locationInWindow)
            return nil
        }
        responderWatch = window.observe(\.firstResponder) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self, let view = window.firstResponder as? NSView else { return }
                // In the reader: its note's pane the one worked in.
                let pane = self.reader.flatMap { view.isDescendant(of: $0) ? self.readerOwner : nil }
                guard let index = self.panes.firstIndex(where: { $0 === pane || view.isDescendant(of: $0) }) else { return }
                self.activate(index)
            }
        }
        lenses.lens = lens
        lenses.inboxCount = session.index.inbox.count
        showStatus()
        tick(session.now)
        updatePanes()
        refreshList()
        layoutWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var state: State {
        State(lens: lens, listShown: listShown, panes: panes.map(\.history), active: activeIndex,
              frame: window.map { NSStringFromRect($0.frame) }, query: searchQuery.isEmpty ? nil : searchQuery, reader: reader?.notePath)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        activePane.focusNote()
    }

    func windowWillClose(_ notification: Notification) {
        if let mouseButtons { NSEvent.removeMonitor(mouseButtons) }
        mouseButtons = nil
        session.windowClosed(self)
    }

    func windowDidResize(_ notification: Notification) { placeWindowButtons() }
    func windowDidMove(_ notification: Notification) { session.writeWindows() }
    func windowDidEndLiveResize(_ notification: Notification) { session.writeWindows() }

    // MARK: Panes

    private func makePane(_ place: PanePlace) -> NotePane {
        let pane = NotePane(session: session, place: place)
        pane.onActivate = { [weak self] pane in
            guard let self, let index = panes.firstIndex(where: { $0 === pane }) else { return }
            activate(index)
        }
        pane.onMoved = { [weak self] pane in
            self?.followReader(pane)
            self?.updatePanes()
            self?.refreshList()
            self?.session.writeWindows()
        }
        pane.onOpenURL = { [weak self] url, pane, beside in self?.follow(url, from: pane, beside: beside) }
        pane.onOpenPath = { [weak self] path, pane, beside in
            guard let self, let index = panes.firstIndex(where: { $0 === pane }) else { return }
            activate(index)
            open(path, beside: beside)
        }
        pane.onClose = { [weak self] pane in self?.closePane(pane) }
        pane.onGoTo = { [weak self] pane, view in self?.openCommandBar("", from: view) }
        pane.onStatus = { [weak self] view in self?.showStatusMenu(from: view) }
        pane.onRead = { [weak self] pane in self?.toggleReader(beside: pane) }
        root.addSubview(pane, positioned: .below, relativeTo: listGlass)
        panes.append(pane)
        return pane
    }

    private func activate(_ index: Int) {
        guard index != activeIndex, panes.indices.contains(index) else { return }
        activeIndex = index
        updatePanes()
        refreshList()
        showStatus()
        tick(session.now)
    }

    private func updatePanes() {
        for (i, pane) in panes.enumerated() {
            pane.isActive = i == activeIndex
            pane.closable = panes.count > 1
            pane.reading = reader != nil && readerOwner === pane
        }
        list.selected = activePane.place.path
        window?.title = NotePane.name(of: activePane.ref, session: session).0
    }

    /// A note opened: in the pane worked in — or, `beside`, in the other,
    /// a second made for it when there is one only.
    func open(_ path: String, beside: Bool = false, fromList: Bool = false) {
        let place = PanePlace(path: path)
        if beside {
            if panes.count == 1 {
                let pane = makePane(place)
                activeIndex = panes.count - 1
                layoutWindow()
                pane.focusNote()
            } else {
                activeIndex = activeIndex == 0 ? 1 : 0
                activePane.go(place)
            }
        } else {
            activePane.go(place)
        }
        updatePanes()
        refreshList()
        session.writeWindows()
        // From the list: the keyboard stays there, to go on down it.
        if fromList { window?.makeFirstResponder(list) } else { activePane.focusNote() }
    }

    private func closePane(_ pane: NotePane) {
        guard panes.count > 1, let index = panes.firstIndex(where: { $0 === pane }) else { return }
        pane.saveNotes()
        if readerOwner === pane { closeReader() }
        pane.removeFromSuperview()
        panes.remove(at: index)
        activeIndex = 0
        updatePanes()
        layoutWindow()
        activePane.focusNote()
        refreshList()
        session.writeWindows()
    }

    /// Follows a link: a note by title — made, when there is none by that
    /// name — a file in the graph, or the web.
    private func follow(_ url: URL, from pane: NotePane, beside: Bool) {
        if let index = panes.firstIndex(where: { $0 === pane }) { activate(index) }
        switch url.scheme {
        case "reflect-note":
            guard let title = url.wikiTarget, let path = session.note(titled: title) else { return NSSound.beep() }
            open(path, beside: beside)
        case nil, "":
            let path = url.path.removingPercentEncoding ?? url.path
            guard path.hasPrefix("assets/"), !path.contains("..") else { return NSSound.beep() }
            NSWorkspace.shared.open(session.graph.root.appendingPathComponent(path))
        default:
            NSWorkspace.shared.open(url)
        }
    }

    func shows(_ ref: NoteRef) -> Bool { panes.contains { $0.shows(ref) } }

    // MARK: The reader

    /// A link note's page read beside its pane — or, read there already, closed.
    private func toggleReader(beside pane: NotePane) {
        if let reader, readerOwner === pane, reader.notePath == pane.place.path { return closeReader() }
        guard openReader(pane.place.path, beside: pane, focus: true) else { return NSSound.beep() }
    }

    /// A link note's page, in a column at the right of the pane it is shown in.
    @discardableResult
    private func openReader(_ path: String, beside pane: NotePane, focus: Bool) -> Bool {
        let sources = ReaderPane.sources(of: path, session: session)
        guard !sources.isEmpty else { return false }
        if let reader { dismissReader(reader) }
        let reader = ReaderPane(session: session, notePath: path, sources: sources)
        reader.onClose = { [weak self] _ in self?.closeReader() }
        root.addSubview(reader, positioned: .below, relativeTo: listGlass)
        self.reader = reader
        readerOwner = pane
        updatePanes()
        layoutWindow()
        if focus { reader.focus() }
        session.writeWindows()
        return true
    }

    private func closeReader() {
        guard let reader else { return }
        dismissReader(reader)
        self.reader = nil
        readerOwner = nil
        updatePanes()
        layoutWindow()
        activePane.focusNote()
        session.writeWindows()
    }

    private func dismissReader(_ reader: ReaderPane) {
        reader.savePlace()
        reader.removeFromSuperview()
    }

    /// The reader's pane gone to another link note: its page read instead.
    private func followReader(_ pane: NotePane) {
        guard let reader, readerOwner === pane, pane.place.path != reader.notePath,
              !ReaderPane.sources(of: pane.place.path, session: session).isEmpty else { return }
        openReader(pane.place.path, beside: pane, focus: false)
    }

    // MARK: The lens, and its list

    /// A lens chosen in the rail: its list shown — chosen again, hidden.
    /// A lens chosen: its list shown — out, if it was put away.
    private func choose(_ lens: Lens, keepShown: Bool = true) {
        self.lens = lens
        listShown = true
        lenses.lens = lens
        refreshList()
        layoutWindow()
        if listShown, lens == .search { list.focusSearch() }
        session.writeWindows()
    }

    /// The list, as the lens gathers it now.
    func refreshList() {
        lenses.inboxCount = session.index.inbox.count
        guard listShown else { return }
        list.selected = activePane.place.path
        switch lens {
        case .daily:
            let shown = activePane.ref.day ?? .today
            let month = (NoteCalendar.Month(shown), NoteCalendar.marks(graph: session.graph, index: session.index),
                         NoteCalendar.weeksWithNotes(index: session.index))
            if activePane.place.face == .schedule, activePane.ref.day != nil {
                list.show(.daily, sections: taskSections(blockable: true), month: month)
            } else {
                list.show(.daily, sections: [ListSection(title: "Days", items: recentDays())], month: month)
            }
        case .inbox:
            list.show(.inbox, sections: [ListSection(title: nil, items: session.index.inbox.map { noteItem($0, checkable: true) })])
        case .pinned:
            list.show(.pinned, sections: [ListSection(title: nil, items: session.index.pinned.map { noteItem($0) })])
        case .tasks:
            list.show(.tasks, sections: taskSections(blockable: false))
        case .search:
            list.show(.search, sections: [ListSection(title: nil, items: searchItems(searchQuery))])
        }
    }

    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// What a note says first: its first rows, plain, as a line or two.
    private func snippet(_ path: String) -> String? {
        guard let body = session.index.body(path) else { return nil }
        let rows = OutlineMarkdown.parse(body).rows.filter { row in
            if case .heading(1) = row.kind { return false }
            return !row.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let text = rows.prefix(3).map { InlineMarkup.plainText($0.text) }.joined(separator: " · ")
        return text.isEmpty ? nil : String(text.prefix(220))
    }

    private func noteItem(_ entry: NoteEntry, checkable: Bool = false) -> ListItem {
        ListItem(path: entry.path, title: session.name(of: entry.path).title,
                 detail: entry.day == nil ? CardSurface.ago(entry.modified) : nil, snippet: snippet(entry.path), checkable: checkable)
    }

    /// The days lately written in, the newest first — today among them, written in or not.
    private func recentDays() -> [ListItem] {
        var days = Set(session.graph.dailyNoteFiles().keys)
        days.insert(.today)
        return days.sorted(by: >).prefix(60).map { day in
            let path = GraphPaths.dailyPath(for: day)
            let detail = day == .today ? "Today" : day == Day.today.adding(-1) ? "Yesterday" : nil
            return ListItem(path: path, title: OpenQuickly.dayTitle(day), detail: detail, snippet: snippet(path))
        }
    }

    /// The tasks still to do, in Reflect's groups — but, to block, not those
    /// on a day's hours already.
    private func taskSections(blockable: Bool) -> [ListSection] {
        let tasks = session.index.tasks()
        var blocked: [String: Set<Int>] = [:]
        if blockable {
            for path in Set(tasks.filter { $0.day != nil }.map(\.notePath)) {
                blocked[path] = DayBlocks.blockedTasks(in: session.graph.read(path: path) ?? "")
            }
        }
        let open = tasks.filter { !(blocked[$0.notePath]?.contains($0.ordinal) ?? false) }
        return Tasks.group(open, today: .today).map { group in
            ListSection(title: blockable ? "To schedule · " + group.label : group.label, items: group.tasks.map { task in
                let note = task.day.map(OpenQuickly.dayTitle) ?? task.noteTitle
                return ListItem(path: task.notePath, title: InlineMarkup.plainText(task.text), detail: nil,
                                snippet: group.kind == .note ? nil : note, checkable: true, task: task)
            })
        }
    }

    /// Notes named by the words first, then those with the words in them.
    private func searchItems(_ query: String) -> [ListItem] {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return [] }
        var seen: Set<String> = []
        var items: [ListItem] = []
        for match in session.index.matches(words, limit: 12) where seen.insert(match.entry.path).inserted {
            items.append(ListItem(path: match.entry.path, title: session.name(of: match.entry.path).title,
                                  detail: CardSurface.ago(match.entry.modified), snippet: snippet(match.entry.path)))
        }
        for found in session.index.containing(words, limit: 40) where seen.insert(found.path).inserted {
            items.append(ListItem(path: found.path, title: session.name(of: found.path).title,
                                  detail: session.index.entry(found.path).map { CardSurface.ago($0.modified) }, snippet: found.snippet))
        }
        return items
    }

    /// A row's circle ticked: a task done; a note out of the inbox.
    private func check(_ item: ListItem) {
        if let task = item.task {
            session.change(task.notePath) { Tasks.setting(done: true, ordinal: task.ordinal, in: $0) }
        } else if lens == .inbox {
            session.setFrontmatter(item.path, "inbox", nil)
        }
    }

    private func showDay(_ day: Day) {
        let face = activePane.ref.day != nil ? activePane.place.face : .outline
        activePane.go(PanePlace(.day(day), face: face))
    }

    private func showToday(face: DayFace) {
        activePane.go(PanePlace(.day(.today), face: face))
    }

    // MARK: ⌘K

    private func commandResults(_ query: String) -> [Place] {
        guard query.hasPrefix("#") else { return session.find(query) }
        guard let pane = headingPane, let note = pane.note else { return [] }
        let rows = note.editor.rows
        let words = query.dropFirst().lowercased().split(whereSeparator: \.isWhitespace)
        var found: [Place] = []
        var levels: [Int] = []
        for (index, row) in rows.enumerated() {
            var level: Int?
            if case .heading(let l) = row.kind { level = l }
            guard level != nil || row.depth == 0 else { continue }
            let depth: Int
            if let level {
                while let last = levels.last, last >= level { levels.removeLast() }
                depth = levels.count + row.depth
                levels.append(level)
            } else {
                depth = levels.count
            }
            let text = InlineMarkup.plainText(row.text.components(separatedBy: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, words.allSatisfy({ text.lowercased().contains($0) }) else { continue }
            found.append(Place(title: String(repeating: "    ", count: min(depth, 6)) + text, path: note.ref.path, row: index))
        }
        return found
    }

    @objc func showCommandBar(_ sender: Any?) { openCommandBar("") }

    /// Go ▸ Move to Heading (⌘\): ⌘K on the note's headings.
    @objc func moveToHeading(_ sender: Any?) { openCommandBar("#") }

    /// ⌘K: dropped from the name of the pane worked in, as an address bar's.
    private func openCommandBar(_ query: String, from view: NSView? = nil) {
        session.save()
        headingPane = activePane
        if commandBar.superview == nil {
            commandBar.frame = root.bounds
            root.addSubview(commandBar)
        }
        root.layoutSubtreeIfNeeded()
        let source = view ?? activePane.titleAnchor
        let frame = commandBar.convert(source.bounds, from: source)
        commandBar.anchor = NSPoint(x: frame.midX, y: (commandBar.isFlipped ? frame.minY : frame.maxY) + 0)
        commandBar.open(face: session.face, query: query)
    }

    private func closeCommandBar() {
        commandBar.removeFromSuperview()
        activePane.focusNote()
    }

    /// A place ⌘K found: a note, a row lately written, a heading.
    private func go(to place: Place, beside: Bool) {
        if let row = place.row, let note = headingPane?.note {
            let editor = note.editor
            guard row < editor.paragraphRanges.count else { return }
            window?.makeFirstResponder(editor)
            editor.editText(inRow: row)
            editor.showFindIndicator(for: editor.paragraphRanges[row])
            return
        }
        open(place.path, beside: beside)
        guard let edit = place.edit else { return }
        let ref = NoteRef(path: edit.path)
        DispatchQueue.main.async { [weak self] in
            guard let self, let note = panes.first(where: { $0.shows(ref) })?.note,
                  let target = RecentEdits.locate(edit, in: session.graph.read(path: edit.path) ?? "") else { return }
            let editor = note.editor
            guard let row = editor.showRow(unfolded: target) else { return }
            window?.makeFirstResponder(editor)
            editor.editText(inRow: row)
            editor.showFindIndicator(for: editor.paragraphRanges[row])
        }
    }

    // MARK: Keeping up

    func notesChanged(_ paths: Set<String>) {
        panes.forEach { $0.notesChanged(paths) }
        // The reader's note written to: a link added, or taken out, among what it reads.
        if let reader, paths.contains(reader.notePath) { reader.refresh(ReaderPane.sources(of: reader.notePath, session: session)) }
        refreshList()
        updatePanes()
    }

    func typographyChanged() {
        panes.forEach { $0.typographyChanged() }
        list.face = session.face
        list.typography = session.face.typography()
        refreshList()
    }

    func saveNotes() { panes.forEach { $0.saveNotes() } }
    func noteMoved(from old: String, to new: String) { panes.forEach { $0.noteMoved(from: old, to: new) } }
    func discard(_ path: String) { panes.forEach { $0.discard(path) } }
    func noteTrashed(_ path: String) { panes.forEach { $0.noteTrashed(path) } }
    func showSync(_ status: SyncController.Status) { showStatus() }
    func showReview(_ paths: [String]) { showStatus() }

    /// Something to look at — the sync gone wrong, notes to review — said
    /// by a warning on the pane worked in; nothing, said by nothing.
    private func showStatus() {
        var lines: [String] = []
        if case .failed(let message) = session.syncStatus { lines.append("Sync failed: " + message) }
        if !session.toReview.isEmpty { lines.append("\(session.toReview.count) \(session.toReview.count == 1 ? "note" : "notes") to review") }
        let status = lines.isEmpty ? nil : lines.joined(separator: " · ")
        for (i, pane) in panes.enumerated() { pane.status = i == activeIndex ? status : nil }
    }

    /// The block it is now: a ring about the Daily lens, running down.
    func tick(_ now: NowPill.Now?) {
        lenses.now = now
        panes.forEach { $0.tick() }
    }

    private func showStatusMenu(from view: NSView) {
        let menu = NSMenu()
        if case .failed(let message) = session.syncStatus {
            let failed = NSMenuItem(title: "Sync failed: " + message, action: nil, keyEquivalent: "")
            failed.isEnabled = false
            menu.addItem(failed)
            menu.addItem(ClosureMenuItem(title: "Sync Now") { [weak self] in self?.session.syncNow() })
            menu.addItem(ClosureMenuItem(title: "Sync Status…") { [weak self] in self?.session.openSyncStatus().showWindow(nil) })
        }
        if !session.toReview.isEmpty {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            let head = NSMenuItem(title: "Notes to Review", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            for path in session.toReview {
                menu.addItem(ClosureMenuItem(title: session.name(of: path).title) { [weak self] in self?.open(path) })
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    // MARK: Layout

    /// Never narrower than its top row: the window's buttons, the sidebar's, the lenses.
    private var listWidth: CGFloat {
        let least = Self.buttonsEnd + 28 + 6 + LensSwitcher.width + 14 - Self.inset
        return listShown ? min(max(340, least), max(least, (window?.frame.width ?? 1000) * 0.28)) : 0
    }
    /// Between the list's glass and the window's edges.
    private static let inset: CGFloat = 8
    /// Where the window's buttons end: the sidebar's button after them, then the rest.
    private static let buttonsEnd: CGFloat = 78
    /// The middle of the window's top row: its buttons, the sidebar's, the lenses, every pane's controls.
    static let barMiddle: CGFloat = 30

    private func layoutWindow() {
        let bounds = root.bounds
        let inset = Self.inset
        list.isHidden = !listShown
        listGlass.isHidden = !listShown
        listGlass.frame = listShown ? NSRect(x: inset, y: inset, width: listWidth, height: bounds.height - 2 * inset) : .zero
        listGlass.cornerRadius = 16
        list.frame = NSRect(x: inset, y: inset, width: listWidth, height: bounds.height - 2 * inset)
        // The lenses: along the list's top, past the window's buttons — or, it put away, floating at the foot.
        lenses.floats = !listShown
        let middle = Self.barMiddle
        sidebarGlass.isHidden = listShown
        sidebarButton.frame = NSRect(x: Self.buttonsEnd, y: middle - 14, width: 28, height: 28)
        sidebarGlass.frame = listShown ? .zero : sidebarButton.frame.insetBy(dx: -4, dy: -4)
        if listShown {
            lenses.frame = NSRect(x: sidebarButton.frame.maxX + 6, y: middle - LensSwitcher.side / 2,
                                  width: LensSwitcher.width, height: LensSwitcher.side)
        } else {
            let size = lenses.preferredSize
            lenses.frame = NSRect(x: 16, y: bounds.height - 16 - size.height, width: size.width, height: size.height)
        }
        let left = listShown ? listGlass.frame.maxX + inset / 2 : 0
        // The columns side by side, evenly: the panes, the reader at its pane's right.
        var columns: [NSView] = []
        for pane in panes {
            columns.append(pane)
            if let reader, readerOwner === pane { columns.append(reader) }
        }
        // Each its share of the width: even, till a divider is dragged.
        if shares.count != columns.count { shares = Self.savedShares(columns.count) }
        let available = bounds.width - left
        var x = left
        for (i, column) in columns.enumerated() {
            let end = i == columns.count - 1 ? bounds.width : (x + shares[i] * available).rounded()
            column.frame = NSRect(x: x.rounded(), y: 0, width: end - x.rounded(), height: bounds.height)
            x = end
        }
        placeDividers(between: columns)
        for (i, pane) in panes.enumerated() {
            pane.ruledLeft = i > 0
            // The first, with nothing at its left: clear of the window's buttons.
            pane.leading = i == 0 && !listShown ? sidebarButton.frame.maxX + 12 : 0
        }
        commandBar.frame = bounds
        placeWindowButtons()
    }

    // MARK: Column widths

    /// The columns' shares of the width, left to right, summing to one.
    private var shares: [CGFloat] = []
    private var dividers: [ColumnDivider] = []
    /// The shares as a drag began: the two either side moved from them.
    private var dragStart: [CGFloat] = []
    private static let columnLeast: CGFloat = 300

    /// The widths last dragged to, for so many columns; else even.
    private static func savedShares(_ count: Int) -> [CGFloat] {
        let even = Array(repeating: 1 / CGFloat(count), count: count)
        guard let saved = UserDefaults.standard.array(forKey: "Columns.\(count)") as? [Double], saved.count == count,
              abs(saved.reduce(0, +) - 1) < 0.01 else { return even }
        return saved.map { CGFloat($0) }
    }

    /// A divider on each boundary between columns, over them, to drag.
    private func placeDividers(between columns: [NSView]) {
        while dividers.count < columns.count - 1 {
            let divider = ColumnDivider()
            let index = dividers.count
            divider.onBegin = { [weak self] in self?.dragStart = self?.shares ?? [] }
            divider.onDrag = { [weak self] dx in self?.dragDivider(index, by: dx) }
            divider.onEnd = { [weak self] in self?.saveShares() }
            divider.onReset = { [weak self] in self?.evenColumns() }
            dividers.append(divider)
        }
        while dividers.count > max(0, columns.count - 1) { dividers.removeLast().removeFromSuperview() }
        for (i, divider) in dividers.enumerated() {
            // Over the panes and the reader, under the list and the command bar.
            if divider.superview == nil || root.subviews.firstIndex(of: divider)! < root.subviews.firstIndex(of: columns[i + 1])! {
                root.addSubview(divider, positioned: .above, relativeTo: columns[i + 1])
            }
            divider.frame = NSRect(x: columns[i].frame.maxX - ColumnDivider.width / 2, y: 0, width: ColumnDivider.width, height: root.bounds.height)
        }
    }

    /// The boundary after column `index` moved: that column and the next
    /// share the width between them, each kept to its least.
    private func dragDivider(_ index: Int, by dx: CGFloat) {
        guard dragStart.count == shares.count, index + 1 < shares.count else { return }
        let available = root.bounds.width - (listShown ? listGlass.frame.maxX + Self.inset / 2 : 0)
        guard available > 0 else { return }
        let pair = dragStart[index] + dragStart[index + 1]
        let least = min(Self.columnLeast / available, pair / 2)
        let left = min(max(dragStart[index] + dx / available, least), pair - least)
        shares[index] = left
        shares[index + 1] = pair - left
        layoutWindow()
    }

    private func saveShares() {
        UserDefaults.standard.set(shares.map(Double.init), forKey: "Columns.\(shares.count)")
    }

    /// A divider double-clicked: the columns even again.
    private func evenColumns() {
        shares = Array(repeating: 1 / CGFloat(shares.count), count: shares.count)
        UserDefaults.standard.removeObject(forKey: "Columns.\(shares.count)")
        layoutWindow()
    }

    /// Close, minimise and zoom in line with the bars' middles.
    private func placeWindowButtons() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        guard let bar = buttons.first?.superview, let container = bar.superview else { return }
        let height = PaneChrome.height
        let frame = NSRect(x: container.frame.minX, y: window.frame.height - height, width: container.frame.width, height: height)
        if container.frame != frame { container.frame = frame }
        for button in buttons {
            let y = ((height - button.frame.height) / 2).rounded()
            if button.frame.minY != y { button.setFrameOrigin(NSPoint(x: button.frame.minX, y: y)) }
        }
    }

    // MARK: Commands

    @objc func showLens(_ sender: NSMenuItem) {
        guard Lens.allCases.indices.contains(sender.tag) else { return }
        choose(Lens.allCases[sender.tag], keepShown: true)
    }

    /// The list out, or put away: ⌥⌘L, or the sidebar's button by the window's.
    @objc func toggleList(_ sender: Any?) {
        listShown.toggle()
        refreshList()
        layoutWindow()
        if listShown, lens == .search { list.focusSearch() }
        session.writeWindows()
    }

    /// A mouse's back or forward button: in what the pointer is over —
    /// a pane, or the page beside one, through the pages it has been to.
    private func mouseStep(_ by: Int, at point: NSPoint) {
        let local = root.convert(point, from: nil)
        if let reader, reader.frame.contains(local) {
            if !reader.step(by) { NSSound.beep() }
            return
        }
        let pane = panes.first { $0.frame.contains(local) } ?? activePane
        if let index = panes.firstIndex(where: { $0 === pane }) { activate(index) }
        if by < 0 { pane.goBack() } else { pane.goForward() }
    }

    @objc func goBack(_ sender: Any?) { activePane.goBack() }
    @objc func goForward(_ sender: Any?) { activePane.goForward() }

    /// ⌘D: today, its face as the day shown has it.
    @objc func goToday(_ sender: Any?) {
        showToday(face: activePane.ref.day != nil ? activePane.place.face : .outline)
    }

    @objc func goThisWeek(_ sender: Any?) { open(GraphPaths.weeklyPath(for: .current)) }

    @objc func previousDay(_ sender: Any?) { activePane.stepDay(-1) }
    @objc func nextDay(_ sender: Any?) { activePane.stepDay(1) }

    @objc func showOutline(_ sender: Any?) {
        if activePane.ref.day == nil { return showToday(face: .outline) }
        activePane.setFace(.outline)
    }

    @objc func showSchedule(_ sender: Any?) {
        if activePane.ref.day == nil { return showToday(face: .schedule) }
        activePane.setFace(.schedule)
    }

    /// ⌘F: the Search lens, its field.
    @objc func find(_ sender: Any?) {
        choose(.search, keepShown: true)
        list.focusSearch()
    }

    @objc func findInNote(_ sender: Any?) {
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        (window?.firstResponder as? NSTextView)?.performFindPanelAction(item)
    }

    /// ⌥⌘N: a note with no name yet, its title to type first.
    @objc func newNote(_ sender: Any?) {
        guard let path = session.newBlankNote() else { return }
        open(path)
        if let editor = activePane.note?.editor {
            window?.makeFirstResponder(editor)
            editor.enter(from: .top, x: .greatestFiniteMagnitude, scrolling: false)
        }
    }

    /// ⌘N: a new row at the top of today — under its title, if it has one.
    @objc func writeToday(_ sender: Any?) {
        showToday(face: .outline)
        DispatchQueue.main.async { [weak self] in
            guard let self, let note = activePane.note, note.ref == .day(.today) else { return NSSound.beep() }
            let editor = note.editor
            let rows = editor.rows
            window?.makeFirstResponder(editor)
            let at = rows.first.map { if case .heading(1) = $0.kind { 1 } else { 0 } } ?? 0
            if rows.indices.contains(at), rows[at].text.isEmpty {
                editor.editText(inRow: at)
                return
            }
            var after = rows
            after.insert(.blank, at: at)
            editor.replace(rows, with: after, actionName: "New Row")
            editor.editText(inRow: at)
        }
    }

    /// ⌘W: the pane worked in, beside another; else the window.
    @objc func closePaneOrWindow(_ sender: Any?) {
        // In the reader: the reader.
        if let reader, let view = window?.firstResponder as? NSView, view.isDescendant(of: reader) { return closeReader() }
        if panes.count > 1 { closePane(activePane) } else { window?.performClose(sender) }
    }

    @objc func syncNow(_ sender: Any?) { session.syncNow() }

    /// ⇧⌘R: the note's page, open beside it — or closed.
    @objc func readPage(_ sender: Any?) { toggleReader(beside: activePane) }

    /// ⇧⌘E: the page read beside, its words alone — or as the site has it.
    @objc func toggleReaderMode(_ sender: Any?) {
        guard let reader else { return NSSound.beep() }
        reader.toggleReading()
    }

    /// ⇧⌘H: the passage chosen in the reader, into its note's Highlights.
    @objc func highlightPassage(_ sender: Any?) { reader?.highlightSelection() }

    /// ⌥⌘← ⌥⌘→: what the reader's note links to before, or next.
    @objc func previousSource(_ sender: Any?) { reader?.turn(-1) }
    @objc func nextSource(_ sender: Any?) { reader?.turn(1) }

    // MARK: The note's own

    private var menuNote: NoteEntry? { session.entry(activePane.ref.path) }

    @objc func toggleInbox(_ sender: Any?) {
        guard let note = menuNote else { return NSSound.beep() }
        session.setFrontmatter(note.path, "inbox", note.isInInbox ? nil : "true")
    }

    @objc func togglePinned(_ sender: Any?) {
        guard let note = menuNote, note.day == nil else { return NSSound.beep() }
        session.setFrontmatter(note.path, "pinned", note.pin == nil ? String(session.index.nextPinOrder) : nil)
    }

    @objc func toggleTopic(_ sender: Any?) {
        guard let note = menuNote, note.day == nil else { return NSSound.beep() }
        session.setFrontmatter(note.path, "topic", note.isTopic ? nil : "true")
    }

    @objc func togglePrivate(_ sender: Any?) {
        guard let note = menuNote else { return NSSound.beep() }
        session.setFrontmatter(note.path, "private", note.isPrivate ? nil : "true")
    }

    @objc func addCover(_ sender: Any?) {
        guard let note = menuNote, note.day == nil, let window else { return NSSound.beep() }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture for the cover of “\(note.title)”."
        panel.prompt = "Use as Cover"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            session.setCover(of: note.path, from: url)
        }
    }

    @objc func removeCover(_ sender: Any?) {
        guard let note = menuNote, note.cover != nil else { return NSSound.beep() }
        session.setFrontmatter(note.path, NoteCover.key, nil)
    }

    @objc func copyNoteLink(_ sender: Any?) {
        guard let note = menuNote else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("[[\(note.day?.description ?? note.title)]]", forType: .string)
    }

    @objc func revealNoteInFinder(_ sender: Any?) {
        guard let note = menuNote, session.graph.exists(path: note.path) else { return NSSound.beep() }
        NSWorkspace.shared.activateFileViewerSelecting([session.graph.url(for: note.path)])
    }

    @objc func trashNote(_ sender: Any?) {
        guard let note = menuNote, note.day == nil, session.graph.exists(path: note.path), let window else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = "Move “\(note.title)” to the Trash?"
        alert.informativeText = "You can take it back out of the Trash. Your other devices lose it when this Mac next syncs."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                self?.session.trash(note.path)
            }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let note = menuNote
        switch item.action {
        case #selector(showLens(_:)):
            item.state = Lens.allCases.indices.contains(item.tag) && Lens.allCases[item.tag] == lens && listShown ? .on : .off
        case #selector(toggleList(_:)):
            item.title = listShown ? "Hide List" : "Show List"
        case #selector(goBack(_:)): return activePane.history.canGoBack
        case #selector(goForward(_:)): return activePane.history.canGoForward
        case #selector(showOutline(_:)): item.state = activePane.ref.day != nil && activePane.place.face == .outline ? .on : .off
        case #selector(showSchedule(_:)): item.state = activePane.ref.day != nil && activePane.place.face == .schedule ? .on : .off
        case #selector(previousDay(_:)), #selector(nextDay(_:)):
            return activePane.ref.day != nil || GraphPaths.week(fromWeeklyPath: activePane.place.path) != nil
        case #selector(toggleInbox(_:)):
            item.title = note?.isInInbox == true ? "Remove from Inbox" : "Add to Inbox"
            return note != nil
        case #selector(togglePinned(_:)):
            item.title = note?.pin != nil ? "Unpin" : "Pin"
            return note?.day == nil && note != nil
        case #selector(toggleTopic(_:)):
            item.state = note?.isTopic == true ? .on : .off
            return note?.day == nil && note != nil
        case #selector(togglePrivate(_:)):
            item.state = note?.isPrivate == true ? .on : .off
            return note != nil
        case #selector(addCover(_:)): return note?.day == nil && note != nil
        case #selector(removeCover(_:)): return note?.cover != nil
        case #selector(trashNote(_:)): return note?.day == nil && note != nil
        case #selector(readPage(_:)):
            let reading = reader != nil && readerOwner === activePane && reader?.notePath == activePane.place.path
            item.title = reading ? "Close Reader" : "Read Note"
            return reading || !ReaderPane.sources(of: activePane.place.path, session: session).isEmpty
        case #selector(previousSource(_:)): return (reader?.index ?? 0) > 0
        case #selector(nextSource(_:)): return reader.map { $0.index < $0.sources.count - 1 } ?? false
        case #selector(highlightPassage(_:)): return reader != nil
        case #selector(toggleReaderMode(_:)):
            item.state = reader?.reading == true ? .on : .off
            return reader != nil
        case #selector(closePaneOrWindow(_:)):
            let inReader = reader.map { reader in (window?.firstResponder as? NSView)?.isDescendant(of: reader) == true } ?? false
            item.title = inReader ? "Close Reader" : panes.count > 1 ? "Close Pane" : "Close Window"
        default: break
        }
        return true
    }

    // MARK: Scripts

    /// The window drawn to a picture, its reader's page and all.
    func snapshot(to url: URL, done: @escaping () -> Void = {}) {
        guard let view = window?.contentView else { return done() }
        ReaderSnapshot.take(view, reader: reader, to: url, done: done)
    }

    func chooseForScript(_ lens: Lens) { choose(lens, keepShown: true) }
    func searchForScript(_ query: String) {
        searchQuery = query
        list.query = query
        refreshList()
    }
    func stepListForScript(_ steps: Int) {
        window?.makeFirstResponder(list)
        for _ in 0..<steps {
            if let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                                           context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125) {
                list.keyDown(with: down)
            }
        }
    }
    var activePaneForScript: NotePane { activePane }
    var readerForScript: ReaderPane? { reader }
    func nowCardForScript() {
        layoutWindow()
        lenses.showNowCardForScript()
    }
    func commandBarForScript(_ query: String) { openCommandBar(query) }
}

/// Between two columns, over the rule there: dragged, the widths either
/// side; double-clicked, the columns even again.
final class ColumnDivider: NSView {
    static let width: CGFloat = 9
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var onReset: (() -> Void)?
    private var startX: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .columnResize)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { return onReset?() ?? () }
        startX = event.locationInWindow.x
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x - startX)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount < 2 { onEnd?() }
    }
}

/// The window's own view.
final class WindowRoot: NSView {
    var layoutHandler: (() -> Void)?
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layoutHandler?()
    }

    override func draw(_ dirtyRect: NSRect) {
        Ink.paper.setFill()
        bounds.fill()
    }
}
