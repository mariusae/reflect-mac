import AppKit
import ReflectCore
import ReflectUI
import PrismCore

/// A window on the graph: the rail of lenses down its left, the list the
/// lens chosen gathers, and the note — or two side by side, the second
/// opened with ⌘ held. As many windows as wanted, each its own.
final class PrismWindow: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// What a window was left showing, to show again.
    struct State: Codable {
        var lens: Lens = .daily
        var listShown = true
        var panes: [PaneHistory] = [PaneHistory(PanePlace(.day(.today)))]
        var active = 0
        var frame: String?
        var query: String?
    }

    let session: Session
    private let root = WindowRoot()
    private let rail = Rail()
    private let list = LensList()
    private var panes: [NotePane] = []
    private var activeIndex = 0
    private(set) var lens: Lens = .daily
    private var listShown = true
    private let commandBar = Finder()
    /// The note whose headings ⌘K's `#` lists.
    private weak var headingPane: NotePane?
    private var responderWatch: NSKeyValueObservation?
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
        root.addSubview(list)
        root.addSubview(rail)

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
        if let frame = state.frame {
            window.setFrame(NSRectFromString(frame), display: false)
        } else if let front = session.frontWindow?.window, front !== window {
            window.setFrame(front.frame.offsetBy(dx: 28, dy: -28), display: false)
        } else {
            window.center()
        }

        rail.onLens = { [weak self] lens in self?.choose(lens) }
        rail.onNow = { [weak self] in self?.showToday(face: .schedule) }
        rail.onReview = { [weak self] view in self?.showReview(from: view) }
        rail.onSync = { [weak self] in self?.session.syncNow() }
        rail.onNewNote = { [weak self] in self?.newNote(nil) }
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

        responderWatch = window.observe(\.firstResponder) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self, let view = window.firstResponder as? NSView,
                      let index = self.panes.firstIndex(where: { view.isDescendant(of: $0) }) else { return }
                self.activate(index)
            }
        }
        rail.lens = lens
        rail.listShown = listShown
        rail.inboxCount = session.index.inbox.count
        rail.toReview = session.toReview
        rail.now = session.now
        updatePanes()
        refreshList()
        layoutWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var state: State {
        State(lens: lens, listShown: listShown, panes: panes.map(\.history), active: activeIndex,
              frame: window.map { NSStringFromRect($0.frame) }, query: searchQuery.isEmpty ? nil : searchQuery)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        activePane.focusNote()
    }

    func windowWillClose(_ notification: Notification) {
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
        pane.onMoved = { [weak self] _ in
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
        pane.onShowDays = { [weak self] in self?.choose(.daily, keepShown: true) }
        root.addSubview(pane, positioned: .below, relativeTo: list)
        panes.append(pane)
        return pane
    }

    private func activate(_ index: Int) {
        guard index != activeIndex, panes.indices.contains(index) else { return }
        activeIndex = index
        updatePanes()
        refreshList()
    }

    private func updatePanes() {
        for (i, pane) in panes.enumerated() {
            pane.isActive = i == activeIndex
            pane.closable = panes.count > 1
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

    // MARK: The lens, and its list

    /// A lens chosen in the rail: its list shown — chosen again, hidden.
    private func choose(_ lens: Lens, keepShown: Bool = false) {
        if lens == self.lens, listShown, !keepShown {
            listShown = false
        } else {
            self.lens = lens
            listShown = true
        }
        rail.lens = lens
        rail.listShown = listShown
        refreshList()
        layoutWindow()
        if listShown, lens == .search { list.focusSearch() }
        session.writeWindows()
    }

    /// The list, as the lens gathers it now.
    func refreshList() {
        rail.inboxCount = session.index.inbox.count
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

    private func openCommandBar(_ query: String) {
        session.save()
        headingPane = activePane
        if commandBar.superview == nil {
            commandBar.frame = root.bounds
            root.addSubview(commandBar)
        }
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
    func showSync(_ status: SyncController.Status) { rail.showSync(status) }
    func showReview(_ paths: [String]) { rail.toReview = paths }

    func tick(_ now: NowPill.Now?) {
        rail.now = now
        panes.forEach { $0.tick() }
    }

    private func showReview(from view: NSView) {
        let menu = NSMenu()
        for path in session.toReview {
            let item = ClosureMenuItem(title: session.name(of: path).title) { [weak self] in self?.open(path) }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX + 4, y: 0), in: view)
    }

    // MARK: Layout

    private var listWidth: CGFloat { listShown ? min(340, max(260, ((window?.frame.width ?? 1000) - Rail.width) * 0.3)) : 0 }

    private func layoutWindow() {
        let bounds = root.bounds
        rail.frame = NSRect(x: 0, y: 0, width: Rail.width, height: bounds.height)
        list.isHidden = !listShown
        list.frame = NSRect(x: Rail.width, y: 0, width: listWidth, height: bounds.height)
        let left = Rail.width + listWidth
        let width = (bounds.width - left) / CGFloat(panes.count)
        for (i, pane) in panes.enumerated() {
            pane.frame = NSRect(x: (left + CGFloat(i) * width).rounded(), y: 0, width: (i == panes.count - 1 ? bounds.width - left - CGFloat(i) * width : width).rounded(),
                                height: bounds.height)
        }
        for (i, pane) in panes.enumerated() {
            pane.ruledLeft = i > 0
            pane.showsWeek = !(listShown && lens == .daily)
        }
        commandBar.frame = bounds
        placeWindowButtons()
    }

    /// Close, minimise and zoom in line with the bars' middles.
    private func placeWindowButtons() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        guard let bar = buttons.first?.superview, let container = bar.superview else { return }
        let height = PaneBar.height
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

    @objc func toggleList(_ sender: Any?) { choose(lens) }

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
        if panes.count > 1 { closePane(activePane) } else { window?.performClose(sender) }
    }

    @objc func syncNow(_ sender: Any?) { session.syncNow() }

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
        case #selector(closePaneOrWindow(_:)): item.title = panes.count > 1 ? "Close Pane" : "Close Window"
        default: break
        }
        return true
    }

    // MARK: Scripts

    func snapshot(to url: URL) {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
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
    func commandBarForScript(_ query: String) { openCommandBar(query) }
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
