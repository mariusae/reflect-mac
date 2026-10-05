import AppKit
import ReflectCore
import PrismCore
import ReflectUI

/// The window: columns of notes, side by side — the first the days, the
/// others notes opened beside them — and nothing else until asked for.
@MainActor
final class PrismWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let graph: Graph
    let index: NoteIndex
    private let images: ImageStore
    private let page = PageView()
    private var columns: [Column] = []
    private var dividers: [ColumnDivider] = []
    /// Under the column the keyboard is in, when there are more than one.
    private let activeBar = NSView()
    private var responderWatch: NSKeyValueObservation?
    private let sidebar = Sidebar()
    private let finder = Finder()
    /// ⌘Y: the rows lately written in, to go back to.
    private let recentFinder = Finder()
    private var recent = RecentEdits()
    /// What each note shown said when last read or written: the edits are
    /// what changed from it.
    private var lastText: [String: String] = [:]
    private let heading = PassThroughLabel(labelWithString: "")
    /// What a sync is doing, at the window's foot, for a moment.
    private let syncStatus = NSTextField(labelWithString: "")
    /// The graph's repository kept in step — only when asked, with ⌘S:
    /// Reflect, or Reflect Mac, keeps it in step otherwise.
    private lazy var sync: SyncController = {
        let sync = SyncController(git: graph.git)
        sync.flush = { [weak self] in self?.save() }
        sync.onPulled = { [weak self] paths in self?.notesChanged(Set(paths)) }
        sync.onStatus = { [weak self] status in self?.showSync(status) }
        sync.onConflicts = { [weak self] paths in
            guard let self, let window else { return }
            let alert = NSAlert()
            alert.messageText = "The sync left \(paths.count) \(paths.count == 1 ? "note" : "notes") to review"
            alert.informativeText = paths.joined(separator: "\n") + "\n\nReflect Mac shows what each side wrote, to choose between."
            alert.beginSheetModal(for: window)
        }
        return sync
    }()
    /// The column the finder, Today and the sidebar open in.
    private weak var active: Column? {
        didSet {
            guard active !== oldValue else { return }
            page.needsLayout = true
            // The bar of sheets to add, on the focused column alone.
            for column in columns { column.isFocused = column === active }
        }
    }


    var face: Typeface {
        didSet { typographyChanged() }
    }
    /// The size the face is set at: its own, as set for it.
    var size: CGFloat {
        get { CGFloat(face.settings.size) }
        set {
            var settings = face.settings
            settings.size = Double(newValue)
            face.settings = settings
            typographyChanged()
        }
    }
    private var metrics: OutlineMetrics { OutlineMetrics(typography: face.typography()) }

    var sidebarPinned = UserDefaults.standard.bool(forKey: "SidebarPinned") {
        didSet {
            UserDefaults.standard.set(sidebarPinned, forKey: "SidebarPinned")
            sidebar.pinned = sidebarPinned
            setSidebar(shown: sidebarPinned, animated: true)
        }
    }
    private var sidebarShown = false

    init(graph: Graph) {
        self.graph = graph
        index = NoteIndex(root: graph.root)
        images = ImageStore(root: graph.root)
        let defaults = UserDefaults.standard
        face = defaults.string(forKey: "Typeface").flatMap(Typeface.init(rawValue:)) ?? .mona

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Ink.page
        window.minSize = NSSize(width: 420, height: 320)
        window.setFrameAutosaveName("Prism")
        if !window.setFrameUsingName("Prism") { window.center() }
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        page.frame = window.contentLayoutRect
        window.contentView = page
        heading.lineBreakMode = .byTruncatingTail
        page.addSubview(heading)
        activeBar.wantsLayer = true
        activeBar.layer?.cornerRadius = 1
        page.addSubview(activeBar)
        syncStatus.alphaValue = 0
        syncStatus.lineBreakMode = .byTruncatingTail
        page.addSubview(syncStatus)
        page.addSubview(sidebar)
        sidebar.pinned = sidebarPinned
        page.onLayout = { [weak self] in self?.layoutPage() }
        page.onMouseMoved = { [weak self] point in self?.mouseMoved(to: point) }

        sidebar.onOpen = { [weak self] place in self?.open(place.path) }
        finder.search = { [weak self] query in self?.find(query) ?? [] }
        finder.onChoose = { [weak self] place, newColumn in
            self?.closeFinder()
            self?.open(place.path, newColumn: newColumn)
        }
        finder.onClose = { [weak self] in self?.closeFinder() }
        recentFinder.placeholder = "Go to a recent edit"
        recentFinder.search = { [weak self] query in self?.findRecent(query) ?? [] }
        recentFinder.onChoose = { [weak self] place, newColumn in
            guard let self else { return }
            closeRecent()
            if let edit = place.edit { goTo(edit, newColumn: newColumn) }
        }
        recentFinder.onClose = { [weak self] in self?.closeRecent() }
        recent = Self.loadRecent(graph.root)

        // The column the keyboard goes into is the one marked, and the one
        // commands act on.
        responderWatch = window.observe(\.firstResponder) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self, let view = window.firstResponder as? NSView,
                      let column = self.columns.first(where: { view.isDescendant(of: $0) }) else { return }
                self.active = column
            }
        }
        index.scan()
        watcher = GraphWatcher(root: graph.root) { [weak self] paths in self?.notesChanged(paths) }
        LinkCompletion.sources = SearchSources(index: index)
        // A `[[link]]`'s card shows the note it leads to.
        LinkCard.noteSource = { [weak self] title in
            guard let self, let path = index.resolve(title) else { return nil }
            return (NoteRef(path: path), graph.read(path: path) ?? "")
        }
        Column.titles = { [index] path in index.entry(path)?.title }
        Column.modified = { [index] path in index.entry(path)?.modified }
        Column.flags = { [index] path in NoteFlags(index.entry(path)) }
        Column.linkPage = { [index] path in
            guard let body = index.body(path), body.contains("URL:") else { return nil }
            return WebCapture.url(in: body).flatMap(URL.init(string:))
        }
        NoteFlags.isEmptyTopic = { [weak self] entry in self?.isEmptyTopic(entry) ?? false }
        let first = makeColumn()
        columns = [first]
        page.addSubview(first, positioned: .below, relativeTo: heading)
        active = first
        page.layoutSubtreeIfNeeded()
        restoreLayout()
        setSidebar(shown: sidebarPinned, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The face, or how it is set, changed: everything set again.
    func typographyChanged() {
        if ProcessInfo.processInfo.environment["PRISM_SNAP"] == nil {
            UserDefaults.standard.set(face.rawValue, forKey: "Typeface")
        }
        NotificationCenter.default.post(name: .prismTypographyChanged, object: self)
        for column in columns {
            column.face = face
            column.metrics = metrics
        }
        refreshSidebar()
        showHeading()
        refreshBacklinks()
    }

    // MARK: Columns

    private func makeColumn() -> Column {
        let column = Column(graph: graph, images: images, metrics: metrics)
        column.face = face
        column.onOpen = { [weak self] url, column, newColumn in self?.follow(url, from: column, newColumn: newColumn) }
        column.onCurrent = { [weak self] _ in self?.showHeading() }
        column.onClose = { [weak self] column in self?.close(column) }
        column.onAddSheet = { [weak self] column, choice in self?.addSheet(choice, on: column) }
        column.onOpenPath = { [weak self] path, column, newColumn in self?.open(path, newColumn: newColumn, from: column) }
        column.onScroll = { [weak self] _ in self?.saveLayout() }
        column.onViewMade = { [weak self] view in self?.noteShown(view) }
        column.onViewGone = { [weak self] view in self?.noteLeft(view) }
        column.onSave = { [weak self] view in self?.noteSaved(view) }
        column.onRevealGap = { [weak self] gap in self?.reveal(gap) }
        column.onSliceEdit = { [weak self] editor, column in self?.writeBack(editor, in: column) }
        column.onSliceLeave = { [weak self] _ in
            self?.refreshBacklinks()
            self?.refreshSearches()
        }
        column.onSearch = { [weak self] query, column in
            self?.search(query, in: column)
            self?.saveLayout()
        }
        column.onRaise = { [weak self] column, index in self?.raise(index, in: column) }
        column.onForward = { [weak self] column, index in self?.forward(index, in: column) }
        column.onPinSheet = { [weak self] column, index in self?.togglePinnedSheet(index, in: column) }
        column.onOpenAlone = { [weak self] ref, column, newColumn in self?.openAlone(ref, from: column, newColumn: newColumn) }
        column.onDragSheet = { [weak self] column, index, event in self?.drag(index, from: column, event: event) }
        column.onRemoveFromInbox = { [weak self] ref in self?.setFrontmatter(ref.path, "inbox", nil) }
        column.onNoteMenu = { [weak self] view, button in self?.showNoteMenu(for: view, from: button) }
        column.onNeedPicture = { [weak self] sheet, size in self?.picture(of: sheet, size: size) }
        column.onOpenPage = { [weak self] ref, column in self?.openPage(of: ref, beside: column) }
        column.onHighlight = { [weak self] ref, passage in self?.highlight(passage, in: ref) }
        column.onLivePeek = { [weak self] sheet, size in self?.livePeek(of: sheet, size: size) }
        column.onUnfold = { [weak self] column in self?.setCollapsed(false, column) }
        column.onFold = { [weak self] column in self?.setCollapsed(true, column) }
        column.onStripHover = { [weak self] column, inside in self?.showStripPicture(of: column, inside) }
        return column
    }

    /// A sheet drawn out of sight, in a column of its own made for it, at a
    /// size: its picture, for one beneath that has none.
    private func picture(of sheet: Sheet, size: NSSize) -> NSImage? {
        guard let column = sheetColumn(sheet, size: size) else { return nil }
        column.displayIfNeeded()
        let image = column.snapshot()
        column.removeFromSuperview()
        return image
    }

    /// A column made for a sheet alone, out of sight, at a size, laid out
    /// where the sheet was read to: none of the window's columns.
    private func sheetColumn(_ sheet: Sheet, size: NSSize) -> Column? {
        guard size.width > 0, size.height > 0 else { return nil }
        let column = Column(graph: graph, images: images, metrics: metrics)
        column.face = face
        column.frame = NSRect(x: -size.width - 4000, y: 0, width: size.width, height: size.height)
        page.addSubview(column, positioned: .below, relativeTo: nil)
        column.layoutSubtreeIfNeeded()
        let was = active
        materialize(sheet, in: column, remember: false)
        active = was
        column.layoutSubtreeIfNeeded()
        // Where it was read to, again, now that its notes are laid out.
        if let place = sheet.place { column.restore(place, key: place.ref) }
        column.layoutSubtreeIfNeeded()
        return column
    }

    /// A sheet live, to peek at with ⌥ held: read, scrolled, copied from,
    /// not written in — it is looked at, not gone to.
    private func livePeek(of sheet: Sheet, size: NSSize) -> Column? {
        guard let column = sheetColumn(sheet, size: size) else { return nil }
        column.removeFromSuperview()
        for view in column.views { view.editor.isEditable = false }
        for editor in column.sliceEditors { editor.view.isEditable = false }
        return column
    }

    // MARK: Folding columns away

    /// The column the keyboard is in folded to a strip at its side, or opened.
    @objc func toggleCollapsed(_ sender: Any?) {
        let column = focusedColumn
        setCollapsed(!column.isCollapsed, column)
    }

    private func setCollapsed(_ collapsed: Bool, _ column: Column) {
        // One always left open, to read in.
        guard !collapsed || columns.contains(where: { $0 !== column && !$0.isCollapsed }) else { return NSSound.beep() }
        showStripPicture(of: column, false)
        if collapsed {
            column.saveAll()
            column.foldedPicture = column.snapshot()
        }
        column.isCollapsed = collapsed
        // Folded, to the right, out of the sidebar's way; opened, back where it was.
        if let i = columns.firstIndex(where: { $0 === column }) {
            columns.remove(at: i)
            if collapsed {
                column.unfoldedIndex = i
                columns.append(column)
            } else {
                let open = columns.filter { !$0.isCollapsed }.count
                columns.insert(column, at: min(column.unfoldedIndex ?? open, open))
                column.unfoldedIndex = nil
            }
            columnsChanged()
        }
        page.needsLayout = true
        if collapsed {
            // The keyboard to the nearest open one.
            let index = columns.firstIndex { $0 === column } ?? 0
            let open = columns.indices.filter { !columns[$0].isCollapsed }
            let next = open.min { abs($0 - index) < abs($1 - index) }.map { columns[$0] }
            active = next
            if let view = next?.current { window?.makeFirstResponder(view.editor) }
        } else {
            active = column
            if let view = column.current { window?.makeFirstResponder(view.editor) }
        }
        saveLayout()
    }

    private let stripPicture = NSImageView()

    /// A folded column, hovered: what is in it, beside its strip.
    private func showStripPicture(of column: Column, _ shown: Bool) {
        guard shown, let image = column.foldedPicture else {
            stripPicture.removeFromSuperview()
            return
        }
        stripPicture.image = image
        stripPicture.imageScaling = .scaleProportionallyUpOrDown
        stripPicture.wantsLayer = true
        stripPicture.layer?.cornerRadius = 8
        stripPicture.layer?.masksToBounds = true
        stripPicture.layer?.borderWidth = 1
        page.effectiveAppearance.performAsCurrentDrawingAppearance {
            stripPicture.layer?.borderColor = Ink.rule.cgColor
            stripPicture.layer?.backgroundColor = Ink.paper.cgColor
        }
        let width = min(360, page.bounds.width * 0.4)
        let height = width * image.size.height / max(image.size.width, 1)
        let strip = column.frame
        // Beside the strip, on the side with room.
        let x = strip.maxX + width + 12 <= page.bounds.width ? strip.maxX + 8 : strip.minX - 8 - width
        stripPicture.frame = NSRect(x: x, y: page.bounds.height - 60 - height, width: width, height: height)
        page.addSubview(stripPicture)
    }

    /// A new column, right of another.
    /// Whether what is being done asks for a column of its own, always: ⇧
    /// held, with ⌘ — a click, ↩, a menu's key.
    private var wantsNewColumn: Bool { NSApp.currentEvent?.modifierFlags.contains(.shift) == true }

    /// Where something opened beside a column goes: the column to its right,
    /// when there is one — on its stack, what was there beneath — else a new
    /// one; a new one always, with ⇧. Says whether it is new.
    private func columnBeside(_ column: Column) -> (column: Column, isNew: Bool) {
        if !wantsNewColumn, let i = columns.firstIndex(where: { $0 === column }), i + 1 < columns.count, !columns[i + 1].isWeb {
            return (columns[i + 1], false)
        }
        return (addColumn(after: column), true)
    }

    private func addColumn(after column: Column) -> Column {
        insertColumn(at: (columns.firstIndex { $0 === column } ?? columns.count - 1) + 1)
    }

    /// A new column, at a place among them.
    private func insertColumn(at index: Int) -> Column {
        let new = makeColumn()
        columns.insert(new, at: min(max(index, 0), columns.count))
        page.addSubview(new, positioned: .below, relativeTo: heading)
        columnsChanged()
        // Laid out at its width now, so what it is shown is placed there.
        page.layoutSubtreeIfNeeded()
        return new
    }

    private func close(_ column: Column) {
        guard columns.count > 1, let index = columns.firstIndex(where: { $0 === column }) else { return }
        column.saveAll()
        column.removeFromSuperview()
        columns.remove(at: index)
        if active === column { active = columns[max(0, index - 1)] }
        columnsChanged()
        if let view = active?.current { window?.makeFirstResponder(view.editor) }
    }

    private func columnsChanged() {
        page.needsLayout = true
        saveLayout()
        for column in columns { column.closable = columns.count > 1 }
        dividers.forEach { $0.removeFromSuperview() }
        dividers = columns.indices.dropFirst().map { i in
            let divider = ColumnDivider()
            divider.onDrag = { [weak self] x in self?.dragDivider(i, to: x) }
            divider.onEnd = { [weak self] in self?.saveLayout() }
            divider.onReset = { [weak self] in
                guard let self else { return }
                columns.forEach { $0.share = 1 }
                page.needsLayout = true
                saveLayout()
            }
            page.addSubview(divider, positioned: .below, relativeTo: heading)
            return divider
        }
        layoutPage()
    }

    /// The column the keyboard is in, else the last one it was in.
    private var focusedColumn: Column {
        if let view = window?.firstResponder as? NSView, let column = columns.first(where: { view.isDescendant(of: $0) }) {
            active = column
        }
        return active ?? columns[0]
    }

    // MARK: Where things were left

    private var layoutTimer: Timer?

    /// Notes the columns — what each shows, and where it is scrolled — and
    /// the note the keyboard is in, a moment after they change.
    private func saveLayout() {
        guard restored else { return }
        layoutTimer?.invalidate()
        layoutTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeLayout() }
        }
    }

    /// A sheet as the session keeps it.
    private func columnPlace(_ sheet: Sheet, beneath: [Sheet] = []) -> SessionState.ColumnPlace {
        var place: SessionState.ColumnPlace = switch sheet.kind {
        case .timeline: .init(kind: "timeline", note: nil, top: sheet.place?.ref.path, offset: Double(sheet.place?.offset ?? 0))
        case .note(let ref): .init(kind: "note", note: ref.path, top: ref.path, offset: Double(sheet.place?.offset ?? 0))
        case .backlinks(let ref): .init(kind: "backlinks", note: ref.path, top: nil, offset: Double(sheet.offset))
        case .inbox: .init(kind: "inbox", note: nil, top: sheet.place?.ref.path, offset: Double(sheet.place?.offset ?? 0))
        case .tasks: .init(kind: "tasks", note: nil, top: nil, offset: Double(sheet.offset))
        case .search(let query): .init(kind: "search", note: query, top: nil, offset: Double(sheet.offset))
        case .web(let ref): .init(kind: "web", note: ref.path, top: nil, offset: 0)
        }
        if !beneath.isEmpty { place.beneath = beneath.map { columnPlace($0) } }
        if sheet.pinned { place.pinned = true }
        place.seen = sheet.seen.timeIntervalSince1970.rounded()
        return place
    }

    /// A sheet from what the session kept: no picture of it, till it is seen again.
    private func sheet(_ place: SessionState.ColumnPlace) -> Sheet? {
        let kind: Column.Kind
        switch place.kind {
        case "note":
            guard let note = place.note else { return nil }
            kind = .note(NoteRef(path: note))
        case "backlinks":
            guard let note = place.note else { return nil }
            kind = .backlinks(NoteRef(path: note))
        case "inbox": kind = .inbox
        case "tasks": kind = .tasks
        case "search": kind = .search(place.note ?? "")
        case "web":
            guard let note = place.note else { return nil }
            kind = .web(NoteRef(path: note))
        default: kind = .timeline
        }
        let top = place.top.map(NoteRef.init(path:))
        var spot = top.map { Column.Place(ref: $0, offset: CGFloat(place.offset)) }
        // A note kept before sheets were, by how far down it was scrolled.
        if case .note(let ref) = kind, top == nil { spot = Column.Place(ref: ref, offset: CGFloat(place.offset) - 40) }
        return Sheet(kind: kind, place: spot, offset: CGFloat(place.offset), title: Column.title(of: kind, top: top), snapshot: nil,
                     pinned: place.pinned == true, seen: place.seen.map(Date.init(timeIntervalSince1970:)) ?? Date())
    }

    private func writeLayout() {
        let places = columns.map { column in
            var place = columnPlace(Sheet(kind: column.kind, place: column.place, offset: column.scrollOffset, title: "", snapshot: nil,
                                          pinned: column.isPinned),
                                    beneath: column.beneath)
            if !column.ahead.isEmpty { place.ahead = column.ahead.map { columnPlace($0) } }
            if column.isCollapsed { place.collapsed = true }
            place.width = column.share == 1 ? nil : Double(column.share)
            return place
        }
        let activeIndex = active.flatMap { active in columns.firstIndex { $0 === active } }
        let key = (window?.firstResponder as? OutlineTextView).flatMap { editor in
            columns.lazy.flatMap(\.views).first { $0.editor === editor }?.ref.path
        }
        SessionState.shared.update(graph.root) { state in
            state.columns = places
            state.activeColumn = activeIndex
            if let key { state.keyNote = key }
        }
    }

    /// Whether the columns have been put back as they were left: till then,
    /// nothing is noted, so what was left is not written over.
    private var restored = false

    /// Puts the columns back as they were left — their stacks of sheets too,
    /// after a restart too — or, with none noted, shows today.
    private func restoreLayout() {
        defer {
            restored = true
            saveLayout()
        }
        let state = SessionState.shared.graph(graph.root)
        guard let places = state.columns, !places.isEmpty else {
            open(GraphPaths.dailyPath(for: .today), remember: false)
            return
        }
        let key = state.keyNote.map(NoteRef.init(path:))
        for (i, place) in places.enumerated() {
            guard let top = sheet(place) else { continue }
            let column = i == 0 ? columns[0] : addColumn(after: columns[i - 1])
            column.beneath = (place.beneath ?? []).compactMap(sheet)
            column.ahead = (place.ahead ?? []).compactMap(sheet)
            column.share = place.width.map { CGFloat($0) } ?? 1
            materialize(top, in: column, key: key)
            if place.collapsed == true { column.isCollapsed = true }
        }
        // Never all folded away.
        if columns.allSatisfy(\.isCollapsed) { columns.first?.isCollapsed = false }
        if let index = state.activeColumn, columns.indices.contains(index), !columns[index].isCollapsed { active = columns[index] }
        if window?.firstResponder is OutlineTextView == false, let view = active?.current {
            window?.makeFirstResponder(view.editor)
            _ = view.restoreSelection()
        }
        showHeading()
    }

    // MARK: Sheets

    /// Puts what a column shows on its stack, under what comes next. The
    /// stack is kept to so many; the oldest are put away.
    private func push(_ column: Column, keepingAhead: Bool = false) {
        guard !column.blocks.isEmpty else { return }
        column.beneath.append(column.currentSheet)
        if column.beneath.count > 24 { column.beneath.removeFirst(column.beneath.count - 24) }
        // What comes next is a sheet of its own: not pinned for the one before it.
        column.isPinned = false
        // Somewhere new: the way forward is another way now.
        if !keepingAhead { column.ahead = [] }
    }

    /// Shows a sheet in a column, as it was left.
    private func materialize(_ sheet: Sheet, in column: Column, key: NoteRef? = nil, remember: Bool = true) {
        active = column
        column.isPinned = sheet.pinned
        switch sheet.kind {
        case .timeline:
            let ref = sheet.place?.ref ?? .day(.today)
            column.showTimeline(timelineEntries(including: ref), around: ref)
            column.restore(sheet.place ?? Column.Place(ref: ref, offset: -12), key: key ?? ref)
        case .note(let ref):
            column.showNote(ref)
            refreshTopic(column)
            column.restore(sheet.place ?? Column.Place(ref: ref, offset: 0), key: key ?? ref)
        case .backlinks(let ref):
            column.pendingOffset = sheet.offset
            findBacklinks(ref, in: column)
        case .inbox:
            refreshInbox(column)
            if let place = sheet.place { column.restore(place, key: key) }
        case .tasks:
            refreshTasks(column, force: true)
            column.scroll(toY: sheet.offset + 12, animated: false)
        case .search(let query):
            search(query, in: column, offset: sheet.offset)
        case .web(let ref):
            showPage(of: ref, in: column)
        }
        column.updateSheetBar()
        guard remember else { return }
        showHeading()
        refreshSidebar()
        saveLayout()
    }

    /// Brings a sheet beneath to the top, what was there going beneath it.
    /// Back down the stack to a sheet beneath: those over it taken off — a
    /// stack is only gone back down, as Back goes.
    private func raise(_ index: Int, in column: Column) {
        guard column.beneath.indices.contains(index) else { return }
        column.saveAll()
        let sheet = column.beneath[index]
        // Those gone back past, the nearest first: pinned ones kept on the
        // stack, just under where it goes back to; the rest the way forward.
        let passed = Array(column.beneath[(index + 1)...]) + [column.currentSheet]
        column.beneath = Array(column.beneath[..<index]) + passed.filter(\.pinned)
        column.ahead = passed.filter { !$0.pinned } + column.ahead
        materialize(sheet, in: column)
        saveLayout()
    }

    /// Forward along the way gone back from, to a sheet on it, by its place
    /// (0 the nearest): those before it go back on the stack, as they were.
    private func forward(_ index: Int, in column: Column) {
        guard column.ahead.indices.contains(index) else { return NSSound.beep() }
        column.saveAll()
        let sheet = column.ahead[index]
        let before = Array(column.ahead[..<index])
        column.ahead.removeSubrange(...index)
        push(column, keepingAhead: true)
        column.beneath += before
        materialize(sheet, in: column)
        saveLayout()
    }

    /// Pins or unpins a sheet: the column's own, for nil; else one beneath.
    private func togglePinnedSheet(_ index: Int?, in column: Column) {
        if let index {
            guard column.beneath.indices.contains(index) else { return }
            column.beneath[index].pinned.toggle()
        } else {
            column.isPinned.toggle()
        }
        saveLayout()
    }

    /// Takes the top sheet off, back to the one beneath.
    private func pop(_ column: Column) {
        guard !column.beneath.isEmpty else { return NSSound.beep() }
        raise(column.beneath.count - 1, in: column)
    }

    // MARK: Dragging sheets

    /// Where a dragged sheet lands: on a column's stack, or as a new column
    /// at a place among them.
    enum Drop: Equatable {
        case stack(Column)
        case newColumn(Int)
    }

    private let dropMarker = DropMarker()

    /// Drags a sheet — the top of a column, for nil; else one beneath — a
    /// card of it following the pointer, where it would land marked, till
    /// the mouse comes up.
    private func drag(_ index: Int?, from source: Column, event: NSEvent) {
        guard let window else { return }
        let sheet = index.map { source.beneath[$0] } ?? source.currentSheet
        let size = source.bounds.size
        let card = SwitcherCard(sheet: sheet, contentSize: size, face: face)
        let width: CGFloat = min(240, size.width * 0.5)
        let height = SwitcherCard.headerHeight + size.height * width / max(size.width, 1) * 0.5
        card.alphaValue = 0.94
        page.addSubview(dropMarker)
        page.addSubview(card)
        NSCursor.closedHand.push()
        var drop: Drop?
        var current: NSEvent? = event
        while let event = current {
            let point = page.convert(event.locationInWindow, from: nil)
            card.frame = cardFrame(at: point, width: width, height: height)
            card.layoutSubtreeIfNeeded()
            drop = self.drop(at: point, from: source, index: index)
            showMarker(for: drop)
            if event.type == .leftMouseUp { break }
            current = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
        }
        NSCursor.pop()
        card.removeFromSuperview()
        dropMarker.removeFromSuperview()
        if let drop { move(index, from: source, to: drop) }
    }

    /// Where a sheet let go at a point lands: by a column's side, a new
    /// column there; in its middle, on its stack. Nil where that would
    /// change nothing.
    private func drop(at point: NSPoint, from source: Column, index: Int?) -> Drop? {
        guard let i = columns.firstIndex(where: { $0.frame.minX <= point.x && point.x < $0.frame.maxX }),
              page.bounds.contains(point) else { return nil }
        let column = columns[i]
        let side = min(110, column.frame.width * 0.2)
        let drop: Drop = point.x < column.frame.minX + side ? .newColumn(i)
            : point.x > column.frame.maxX - side ? .newColumn(i + 1) : .stack(column)
        // A page's column takes no sheets, nor is its page a sheet to move.
        if case .stack(let target) = drop, target.isWeb { return nil }
        if source.isWeb, index == nil { return nil }
        let at = columns.firstIndex { $0 === source } ?? -1
        switch drop {
        // The top sheet onto its own stack.
        case .stack(let target) where target === source && index == nil: return nil
        // A sheet alone, beside where it already is.
        case .newColumn(let place) where index == nil && source.beneath.isEmpty && (place == at || place == at + 1): return nil
        default: return drop
        }
    }

    /// The dragged card, hanging from the pointer, kept inside the window.
    private func cardFrame(at point: NSPoint, width: CGFloat, height: CGFloat) -> NSRect {
        let bounds = page.bounds.insetBy(dx: 6, dy: 6)
        return NSRect(x: min(max(point.x - width / 2, bounds.minX), bounds.maxX - width),
                      y: min(max(point.y - height + 10, bounds.minY), bounds.maxY - height), width: width, height: height)
    }

    private func showMarker(for drop: Drop?) {
        let isNew = if case .newColumn = drop { true } else { false }
        dropMarker.show(drop.map(markFrame), newColumn: isNew)
    }

    /// Where the marker for a drop goes: the column, or the band at the
    /// place for the new one.
    private func markFrame(_ drop: Drop) -> NSRect {
        switch drop {
        case .stack(let column):
            return column.frame.insetBy(dx: 10, dy: 10)
        case .newColumn(let place):
            let x = place < columns.count ? columns[place].frame.minX : (columns.last?.frame.maxX ?? page.bounds.maxX)
            let width: CGFloat = 120
            let left = min(max(x - width / 2, 4), page.bounds.maxX - width - 4)
            return NSRect(x: left, y: 10, width: width, height: page.bounds.height - 20)
        }
    }

    /// Moves a sheet: off its column — the one beneath it showing then, or,
    /// with none, the column closed — and onto a stack, or into a new column.
    private func move(_ index: Int?, from source: Column, to drop: Drop) {
        source.saveAll()
        let sheet: Sheet
        var emptied = false
        if let index {
            sheet = source.beneath.remove(at: index)
        } else {
            sheet = source.currentSheet
            if let below = source.beneath.popLast() { materialize(below, in: source) } else { emptied = true }
        }
        switch drop {
        case .stack(let target):
            push(target)
            materialize(sheet, in: target)
        case .newColumn(let place):
            materialize(sheet, in: insertColumn(at: place))
        }
        if emptied { close(source) }
        if let view = active?.current { window?.makeFirstResponder(view.editor) }
        saveLayout()
    }

    /// ⌘E: the focused column's sheets as cards, or the next one down.
    @objc func switchSheets(_ sender: Any?) { cycleSheets(backward: false) }
    /// ⇧⌘E: from the bottom up, or the next one up.
    @objc func switchSheetsBackward(_ sender: Any?) { cycleSheets(backward: true) }

    private var switcherColumn: Column?
    private var switcherMonitor: Any?

    private func cycleSheets(backward: Bool) {
        if let column = switcherColumn, column.switcherSelection != nil {
            column.moveSwitcher(backward ? 1 : -1)
            return
        }
        let column = focusedColumn
        guard !column.beneath.isEmpty else { return NSSound.beep() }
        column.openSwitcher(backward: backward)
        switcherColumn = column
        // Letting go of ⌘ takes the one chosen; Escape, none.
        switcherMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self, let column = self.switcherColumn else { return event }
            if event.type == .flagsChanged, !event.modifierFlags.contains(.command) {
                self.endSwitcher(choosing: column.switcherSelection)
                return event
            }
            if event.type == .keyDown, event.keyCode == 53 {
                self.endSwitcher(choosing: nil)
                return nil
            }
            // Typed, ⌘ held: a sheet found by its name. E steps along till
            // something has been typed; then it is typed too.
            if event.type == .keyDown {
                var typed = column.switcherQuery ?? ""
                if event.keyCode == 51 {
                    guard !typed.isEmpty else { return nil }
                    typed.removeLast()
                    column.findInSwitcher(typed)
                    return nil
                }
                guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1,
                      let character = characters.first, character.isLetter || character.isNumber || character == " " else { return event }
                if character == "e", typed.isEmpty { return event }
                column.findInSwitcher(typed + String(character))
                return nil
            }
            return event
        }
    }

    private func endSwitcher(choosing index: Int?) {
        if let monitor = switcherMonitor { NSEvent.removeMonitor(monitor) }
        switcherMonitor = nil
        switcherColumn?.closeSwitcher(choosing: index)
        switcherColumn = nil
    }

    /// A divider dragged: the columns either side of it shared out anew,
    /// neither narrower than a column can be read in.
    private func dragDivider(_ index: Int, to x: CGFloat) {
        guard columns.indices.contains(index), index > 0 else { return }
        let left = columns[index - 1], right = columns[index]
        let span = left.frame.width + right.frame.width
        let least: CGFloat = 280
        let leftWidth = min(max(page.convert(NSPoint(x: x, y: 0), from: nil).x - left.frame.minX, least), span - least)
        let shares = left.share + right.share
        left.share = shares * leftWidth / span
        right.share = shares - left.share
        page.needsLayout = true
        page.layoutSubtreeIfNeeded()
    }

    // MARK: Layout

    private func layoutPage() {
        let bounds = page.bounds
        let left = sidebarPinned ? Sidebar.width + 16 : 0
        // Each column its share of the width; a folded one, a strip's.
        let open = columns.filter { !$0.isCollapsed }
        let folded = CGFloat(columns.count - open.count) * CollapsedStrip.width
        let total = open.reduce(0) { $0 + $1.share }
        let last = open.last
        var x = left
        for column in columns {
            let after = CGFloat(columns.drop { $0 !== column }.dropFirst().count) * CollapsedStrip.width
            let width = column.isCollapsed ? CollapsedStrip.width
                : column === last ? bounds.width - x - after
                : round((bounds.width - left - folded) * column.share / max(total, 0.01))
            column.frame = NSRect(x: round(x), y: 0, width: width, height: bounds.height)
            x += width
        }
        for (i, divider) in dividers.enumerated() {
            divider.frame = NSRect(x: columns[i + 1].frame.minX - ColumnDivider.reach, y: 0, width: 2 * ColumnDivider.reach,
                                   height: bounds.height)
        }
        // The column the keyboard is in, marked at its foot.
        if columns.count > 1, let active, columns.contains(where: { $0 === active }) {
            activeBar.isHidden = false
            activeBar.frame = NSRect(x: active.frame.minX + 24, y: 0, width: max(0, active.frame.width - 48), height: 2)
            page.effectiveAppearance.performAsCurrentDrawingAppearance {
                activeBar.layer?.backgroundColor = Ink.accent.withAlphaComponent(0.55).cgColor
            }
        } else {
            activeBar.isHidden = true
        }
        let height = ceil(heading.intrinsicContentSize.height)
        let first = columns.first?.frame ?? bounds
        heading.frame = NSRect(x: first.minX + 80, y: bounds.height - 26 - height / 2, width: first.width - 160, height: height)
        let statusSize = syncStatus.attributedStringValue.size()
        let statusWidth = min(ceil(statusSize.width) + 6, bounds.width / 2)
        syncStatus.frame = NSRect(x: bounds.width - statusWidth - 16, y: 10, width: statusWidth, height: ceil(statusSize.height) + 2)
        let sidebarX = sidebarShown ? 8 : -Sidebar.width - 24
        sidebar.frame = NSRect(x: sidebarX, y: 8, width: Sidebar.width, height: bounds.height - 16)
        finder.frame = bounds
    }

    private func setSidebar(shown: Bool, animated: Bool) {
        guard shown != sidebarShown || !animated else { return }
        sidebarShown = shown
        if !shown { sidebar.clearHover() }
        if shown { refreshSidebar() }
        let x: CGFloat = shown ? 8 : -Sidebar.width - 24
        let frame = NSRect(x: x, y: 8, width: Sidebar.width, height: page.bounds.height - 16)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                sidebar.animator().frame = frame
            }
            page.needsLayout = true
        } else {
            sidebar.frame = frame
        }
    }

    private func mouseMoved(to point: NSPoint) {
        guard !sidebarPinned, finder.superview == nil else { return }
        if !sidebarShown, point.x < 4, point.y < page.bounds.height - 40 {
            setSidebar(shown: true, animated: true)
        } else if sidebarShown, point.x > Sidebar.width + 40 {
            setSidebar(shown: false, animated: true)
        }
    }

    // MARK: Notes

    /// The timeline: every day and week there is a note for, today, and
    /// `including`, in order — a week before the days it covers.
    private func timelineEntries(including ref: NoteRef? = nil) -> [NoteRef] {
        Timeline.entries(graph: graph, index: index, including: ref, revealed: revealedDays)
    }

    /// Days with no note shown in the timeline all the same, to write in:
    /// opened from a gap, or gone to. Written in, they are notes like any.
    private var revealedDays: Set<Day> = []

    /// A gap's last few days, shown empty in every timeline.
    private func reveal(_ gap: TimelineGap) {
        revealedDays.formUnion(Timeline.reveal(gap))
        let entries = timelineEntries()
        columns.forEach { $0.updateTimeline(entries) }
    }

    /// The day a note is placed at in the timeline, when it has a place there.
    private func day(of ref: NoteRef) -> Day? { Timeline.day(of: ref) }

    /// Where a column is: the note at its top.
    private func location(of column: Column) -> String? { column.current?.ref.path }

    /// Opens a note in the column the keyboard is in, or in a new one.
    func open(_ path: String, remember: Bool = true, newColumn: Bool = false, from source: Column? = nil) {
        var column = notesColumn(source ?? focusedColumn)
        var fresh = false
        if newColumn { (column, fresh) = columnBeside(column) }
        if remember, !fresh {
            // Where the column was goes on its stack — but a day of the
            // timeline shown is gone to by scrolling, not a sheet of its own.
            let ref = NoteRef(path: path)
            let scrolls = day(of: ref) != nil && column.isTimeline
            if !scrolls, column.kind != .note(ref) { push(column) }
        }
        show(path, in: column)
    }

    private func show(_ path: String, in column: Column) {
        active = column
        let ref = NoteRef(path: path)
        if day(of: ref) != nil {
            // A day gone to that has no note yet stays in the timeline, empty, to write in.
            if let day = ref.day, !graph.exists(path: path) { revealedDays.insert(day) }
            if !column.shows(ref) { column.showTimeline(timelineEntries(including: ref), around: ref) }
            // A day as it was left: read to where it was, the caret where it was.
            if let offset = SessionState.shared.place(graph.root, ref)?.offset {
                column.restore(Column.Place(ref: ref, offset: CGFloat(offset)), key: ref)
            } else {
                column.reveal(ref, animated: false)
            }
        } else {
            showAlone(ref, in: column)
        }
        showHeading()
        refreshSidebar()
        saveLayout()
    }

    /// A note on its own in a column, where it was left: as far down, the
    /// caret where it was.
    private func showAlone(_ ref: NoteRef, in column: Column) {
        column.showNote(ref)
        refreshTopic(column)
        // Where it was read to, from its top, and where the caret was.
        let offset = SessionState.shared.place(graph.root, ref)?.offset ?? 0
        column.restore(Column.Place(ref: ref, offset: CGFloat(offset)), key: ref)
        if column.view(for: ref)?.restoreSelection() == false {
            column.view(for: ref)?.editor.enter(from: .top, x: 0, scrolling: false)
        }
    }

    /// A note opened on its own — a day too, out of the timeline — on the
    /// column's stack, or in a column of its own.
    private func openAlone(_ ref: NoteRef, from source: Column, newColumn: Bool) {
        var column = source
        var fresh = false
        if newColumn { (column, fresh) = columnBeside(source) }
        if !fresh { push(column) }
        active = column
        showAlone(ref, in: column)
        showHeading()
        refreshSidebar()
        saveLayout()
    }

    /// Clicks a note's header in the first column, as from the mouse.
    func openAloneForScript(_ path: String) {
        guard let column = columns.first, column.view(for: NoteRef(path: path)) != nil else { return }
        openAlone(NoteRef(path: path), from: column, newColumn: false)
    }

    private func showHeading() {
        var text = ""
        if let column = columns.first, column.isTimeline, column.currentNameHidden, let current = column.current {
            text = Column.name(of: current.ref).title
        }
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        heading.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: face.font(size: 12.5, weight: .medium), .foregroundColor: Ink.faint, .kern: 0.2,
            .paragraphStyle: centred,
        ])
        if let path = active.flatMap(location(of:)) {
            window?.title = index.entry(path)?.title ?? path
        }
        page.needsLayout = true
    }

    /// Follows a link from a column: a note by title — made, when there is
    /// none by that name — a file in the graph, or the web.
    private func follow(_ url: URL, from column: Column, newColumn: Bool) {
        switch url.scheme {
        case "reflect-note":
            guard let title = url.wikiTarget else { return NSSound.beep() }
            if let path = index.resolve(title) {
                open(path, newColumn: newColumn, from: column)
            } else if !title.trimmingCharacters(in: .whitespaces).isEmpty,
                      let path = try? NoteCreation.create(title: title, in: graph.root) {
                index.refresh(path)
                open(path, newColumn: newColumn, from: column)
            } else {
                NSSound.beep()
            }
        case nil, "":
            let path = url.path.removingPercentEncoding ?? url.path
            guard path.hasPrefix("assets/"), !path.contains("..") else { return NSSound.beep() }
            NSWorkspace.shared.open(graph.root.appendingPathComponent(path))
        default:
            NSWorkspace.shared.open(url)
        }
    }

    /// Writes every note with unsaved writing, and where things were left.
    func save() {
        columns.forEach { $0.saveAll() }
        if restored { writeLayout() }
        SessionState.shared.writeNow()
    }

    /// The day it was when the timeline was last set out.
    private var lastDay = Day.today

    /// Switched back to: nothing to read again — the graph is watched, so
    /// what changed meanwhile, in the background too, is already shown. Only
    /// a new day, which has no file till it is written in, is put in.
    func windowDidBecomeKey(_ notification: Notification) {
        guard Day.today != lastDay else { return }
        lastDay = .today
        let entries = timelineEntries()
        columns.forEach { $0.updateTimeline(entries) }
        refreshSidebar()
        showHeading()
    }

    // MARK: Backlinks

    /// The note the keyboard is in, else the one at the top of the column.
    private var focusedNote: NoteRef? {
        if let editor = window?.firstResponder as? OutlineTextView,
           let view = columns.lazy.flatMap(\.views).first(where: { $0.editor === editor }) {
            return view.ref
        }
        if case .backlinks(let ref) = focusedColumn.kind { return ref }
        return focusedColumn.current?.ref
    }

    /// Opens a column, right of this one, of what links to the note the
    /// keyboard is in — or goes to the one already open.
    // MARK: New notes, and their titles

    /// Notes made here and not yet named: taken away again if left blank.
    private var blankNotes: Set<String> = []
    /// Each note's title as last settled, by path: a new one is told by it.
    private var settledTitles: [String: String] = [:]
    /// A title typed and waiting to settle, by path.
    private var pendingTitles: [String: String] = [:]
    private var retitleTimers: [String: Timer] = [:]
    /// The aliases each note's last rename added, and the title it left the
    /// note with: a rename from that title goes on the chain, and prunes them.
    private var renameChains: [String: (title: String, added: [String])] = [:]
    /// How long a title typed waits before the note takes it.
    private static let retitleDelay: TimeInterval = 5

    /// File ▸ New Note (⌘N): a note with no name yet, on top of the column
    /// the keyboard is in, its title to type first. Named, its file is
    /// named after it; left blank, it goes again.
    @objc func newNote(_ sender: Any?) {
        save()
        do {
            let path = try NoteCreation.createBlank(in: graph.root)
            blankNotes.insert(path)
            index.refresh(path)
            open(path)
            // The caret in the title, to type it.
            if let editor = focusedColumn.view(for: NoteRef(path: path))?.editor {
                window?.makeFirstResponder(editor)
                editor.enter(from: .top, x: .greatestFiniteMagnitude, scrolling: false)
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func title(of view: DayView) -> String? {
        view.ref.day == nil ? TitleRename.authoredTitle(path: view.ref.path, source: view.savedText) : nil
    }

    private func noteShown(_ view: DayView) {
        if lastText[view.ref.path] == nil { lastText[view.ref.path] = graph.read(path: view.ref.path) ?? "" }
        guard view.ref.day == nil, settledTitles[view.ref.path] == nil, let title = title(of: view) else { return }
        settledTitles[view.ref.path] = title
    }

    /// A note written: a title typed in it waits to settle, then is taken.
    private func noteSaved(_ view: DayView) {
        let path = view.ref.path
        noteEdits(path)
        refreshPages(of: view.ref)
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

    /// A note no longer shown: its title settled now; a new one left blank,
    /// taken away.
    private func noteLeft(_ view: DayView) {
        let path = view.ref.path
        if pendingTitles[path] != nil { settleTitle(path) }
        guard blankNotes.contains(path) else { return }
        // Once the column has done letting it go: shown nowhere else, then.
        DispatchQueue.main.async { [weak self] in self?.dropIfBlank(view.ref) }
    }

    private func dropIfBlank(_ ref: NoteRef) {
        let path = ref.path
        guard blankNotes.contains(path), graph.exists(path: path), !columns.contains(where: { $0.view(for: ref) != nil }) else { return }
        let text = graph.read(path: path) ?? ""
        guard TitleRename.authoredTitle(path: path, source: text) == nil, Backlinks.isEmpty(OutlineMarkdown.parse(text).rows) else { return }
        blankNotes.remove(path)
        try? FileManager.default.removeItem(at: graph.url(for: path))
        index.refresh(path)
        refreshSidebar()
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
    /// manages moves to the file its title names. A note that had no title
    /// (`from` nil) only moves: nothing links to a title never had.
    private func retitle(_ path: String, from: String?, to: String) {
        blankNotes.remove(path)
        save()
        guard graph.exists(path: path) else { return }
        if let from {
            let result = index.retitleLinks(to: path, from: from, to: to, read: graph.read(path:),
                                             write: { [graph] text, source in try graph.write(text, path: source) })
            // The old title, kept as an alias — unless it is another note's.
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
            index.refresh(path)
        }
        // The file follows the title, for a note Reflect manages.
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
        SessionState.shared.moved(graph.root, from: NoteRef(path: path), to: NoteRef(path: destination))
        if let title = settledTitles.removeValue(forKey: path) { settledTitles[destination] = title }
        if let chain = renameChains.removeValue(forKey: path) { renameChains[destination] = chain }
        noteMoved(from: NoteRef(path: path), to: NoteRef(path: destination))
    }

    /// A note's file moved: every column and sheet showing it, showing it
    /// where it is now, scrolled and with the caret as they were.
    private func noteMoved(from old: NoteRef, to new: NoteRef) {
        for column in columns {
            column.beneath = column.beneath.map { sheet in
                var sheet = sheet
                if sheet.kind == .note(old) { sheet.kind = .note(new) }
                if sheet.place?.ref == old { sheet.place?.ref = new }
                return sheet
            }
            guard column.kind == .note(old) else { continue }
            let place = column.place.map { Column.Place(ref: new, offset: $0.offset) }
            let selection = column.view(for: old)?.editor.selectedRange()
            let hadKeyboard = column.view(for: old).map { window?.firstResponder === $0.editor } ?? false
            materialize(Sheet(kind: .note(new), place: place, offset: 0, title: "", snapshot: nil), in: column)
            if let editor = column.view(for: new)?.editor, let selection {
                if hadKeyboard { window?.makeFirstResponder(editor) }
                let length = (editor.string as NSString).length
                editor.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            }
        }
        saveLayout()
        refreshSidebar()
    }

    // MARK: Syncing

    /// Graph ▸ Sync Now (⌘S): what is written saved, committed, and the
    /// graph's repository brought in step — fetched, merged, pushed.
    @objc func syncNow(_ sender: Any?) {
        guard graph.git != nil else {
            showSync(.failed("This graph is not in a git repository"))
            return
        }
        sync.sync()
    }

    private var syncFade: Timer?

    private func showSync(_ status: SyncController.Status) {
        let text: String
        switch status {
        case .idle: return
        case .syncing: text = "Syncing…"
        case .synced: text = "Synced"
        case .failed(let message): text = "Sync failed: " + message
        case .unavailable: text = "Not in a git repository"
        }
        syncStatus.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: face.font(size: 12, weight: .medium),
            .foregroundColor: { if case .failed = status { NSColor.systemRed } else { Ink.secondary } }(),
        ])
        syncStatus.toolTip = text
        syncStatus.alphaValue = 1
        page.needsLayout = true
        syncFade?.invalidate()
        guard status != .syncing else { return }
        syncFade = Timer.scheduledTimer(withTimeInterval: { if case .failed = status { 8 } else { 2 } }(), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.4
                    self?.syncStatus.animator().alphaValue = 0
                }
            }
        }
    }

    // MARK: Searching

    /// Edit ▸ Search (⌘F): a search, as a new sheet on the column the
    /// keyboard is in — or, in a search already, its field, the words in
    /// it chosen, to type over.
    @objc func find(_ sender: Any?) {
        let column = focusedColumn
        if case .search = column.kind, let header = column.blocks.first as? SearchHeader {
            column.scroll(toY: 0, animated: true)
            window?.makeFirstResponder(header.field)
            header.field.currentEditor()?.selectAll(nil)
            return
        }
        showSearchSheet(sender)
    }

    /// Edit ▸ Find in Note (⇧⌘F): the find bar of the note the keyboard is in.
    @objc func findInNote(_ sender: Any?) {
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        (window?.firstResponder as? NSTextView)?.performFindPanelAction(item)
    }

    /// Opens a search in a column of its own, right of this one.
    @objc func showSearch(_ sender: Any?) {
        let (column, fresh) = columnBeside(focusedColumn)
        if !fresh { push(column) }
        search("", in: column)
        saveLayout()
    }

    /// Opens a search as a new sheet on the column the keyboard is in.
    @objc func showSearchSheet(_ sender: Any?) {
        let column = focusedColumn
        push(column)
        search("", in: column)
        saveLayout()
    }

    /// Which search each column last asked for: an older one, finished
    /// late, is not shown over it.
    private var searchGeneration: [ObjectIdentifier: Int] = [:]

    /// Looks for words in every note, in the background: those with all of
    /// them, the most lately changed first, each with the rows they are in.
    private func search(_ query: String, in column: Column, offset: CGFloat? = nil) {
        active = column
        let words = Column.words(query)
        let id = ObjectIdentifier(column)
        let generation = (searchGeneration[id] ?? 0) + 1
        searchGeneration[id] = generation
        guard !words.isEmpty else {
            column.showSearch(query, found: [], names: backlinkName)
            return
        }
        // The column says what it looks for now — its head kept as typed
        // in, saying it is looking — so what is found is shown when it comes.
        if column.kind != .search(query) { column.showSearch(query, found: nil, names: backlinkName) }
        let index = index
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak column] in
            let found = NoteSearch.find(words, in: index).map { ($0.path, $0.slices, $0.editable) }
            DispatchQueue.main.async {
                guard let self, let column, self.searchGeneration[id] == generation, column.kind == .search(query) else { return }
                column.showSearch(query, found: found, names: self.backlinkName)
                if let offset { column.scroll(toY: offset + 12, animated: false) }
            }
        }
    }

    /// The searches shown caught up — but not one being typed in, which
    /// waits till the keyboard leaves it.
    private func refreshSearches() {
        for column in columns {
            guard case .search(let query) = column.kind, !column.isTypingInSlice, !column.isTypingQuery else { continue }
            search(query, in: column, offset: column.scrollOffset)
        }
    }

    // MARK: Views as sheets

    /// A view opened as a new sheet on the column the keyboard is in, what
    /// was there going beneath it.
    /// Where a sheet goes, asked of a column: never on a page's column — the
    /// nearest column of notes before it, else a new one beside it.
    private func notesColumn(_ column: Column) -> Column {
        guard column.isWeb, let i = columns.firstIndex(where: { $0 === column }) else { return column }
        return columns[..<i].last { !$0.isWeb } ?? addColumn(after: column)
    }

    private func openSheet(_ kind: Column.Kind, at ref: NoteRef? = nil, on target: Column? = nil) {
        let column = notesColumn(target ?? focusedColumn)
        push(column)
        materialize(Sheet(kind: kind, place: ref.map { Column.Place(ref: $0, offset: -12) }, offset: 0,
                          title: Column.title(of: kind, top: ref), snapshot: nil), in: column)
    }

    @objc func showTimelineSheet(_ sender: Any?) {
        openSheet(.timeline, at: focusedNote.flatMap { day(of: $0) != nil ? $0 : nil } ?? .day(.today))
    }

    @objc func showBacklinksSheet(_ sender: Any?) {
        guard let ref = focusedNote else { return NSSound.beep() }
        openSheet(.backlinks(ref))
    }

    /// A sheet put on a column from its bar: about what the column shows.
    private func addSheet(_ choice: SheetBar.Choice, on column: Column) {
        active = column
        let note: NoteRef? = { if case .backlinks(let ref) = column.kind { return ref } else { return column.current?.ref } }()
        switch choice {
        case .timeline: openSheet(.timeline, at: note.flatMap { day(of: $0) != nil ? $0 : nil } ?? .day(.today), on: column)
        case .backlinks:
            guard let note else { return NSSound.beep() }
            openSheet(.backlinks(note), on: column)
        case .inbox: openSheet(.inbox, on: column)
        case .tasks: openSheet(.tasks, on: column)
        case .search:
            push(column)
            search("", in: column)
            saveLayout()
        }
    }

    @objc func showInboxSheet(_ sender: Any?) { openSheet(.inbox) }
    @objc func showTasksSheet(_ sender: Any?) { openSheet(.tasks) }

    @objc func showBacklinks(_ sender: Any?) {
        guard let ref = focusedNote else { return NSSound.beep() }
        if !wantsNewColumn, let open = columns.first(where: { $0.kind == .backlinks(ref) }) {
            active = open
            return
        }
        let (column, fresh) = columnBeside(focusedColumn)
        if !fresh { push(column) }
        active = column
        findBacklinks(ref, in: column)
    }

    /// Opens a column of the timeline, right of this one: about the day
    /// the keyboard is in, else about today.
    @objc func showTimeline(_ sender: Any?) {
        let ref = focusedNote.flatMap { day(of: $0) != nil ? $0 : nil } ?? .day(.today)
        let (column, fresh) = columnBeside(focusedColumn)
        // A timeline there already only scrolls to the day.
        if !fresh, !column.isTimeline { push(column) }
        show(ref.path, in: column)
    }

    /// What a note is called among backlinks: a day by its date.
    private func backlinkName(_ path: String) -> (title: String, detail: String?) {
        if let day = GraphPaths.day(fromDailyPath: path) { return (OpenQuickly.dayTitle(day), day == .today ? "Today" : nil) }
        if let week = GraphPaths.week(fromWeeklyPath: path) { return ("Week \(week.week)", OpenQuickly.weekRange(week)) }
        return (index.entry(path)?.title ?? (path as NSString).lastPathComponent, nil)
    }

    /// Looks for what links to a note, off the main thread, and shows it.
    private func findBacklinks(_ ref: NoteRef, in column: Column) {
        let name = backlinkName(ref.path).title
        if column.kind != .backlinks(ref) {
            column.backlinks = nil
            column.showBacklinks(of: ref, name: name, sources: nil, names: backlinkName)
        }
        let index = index
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak column] in
            let sources = index.backlinks(to: ref.path)
            DispatchQueue.main.async {
                // Not while typed in: once the keyboard leaves, it is looked for again.
                guard let self, let column, column.kind == .backlinks(ref), !column.isTypingInSlice else { return }
                // Shown again only when what links here changed.
                if column.backlinks == sources, column.pendingOffset == nil { return }
                column.backlinks = sources
                column.showBacklinks(of: ref, name: name, sources: sources, names: self.backlinkName)
            }
        }
    }

    private func refreshBacklinks() {
        for column in columns {
            if case .backlinks(let ref) = column.kind { findBacklinks(ref, in: column) }
            if case .note = column.kind { refreshTopic(column) }
        }
    }

    /// A topic note — `topic: true`, or one that says nothing but its
    /// title — shown with what links to it, under it; any other, without.
    private func refreshTopic(_ column: Column) {
        guard case .note(let ref) = column.kind, let view = column.view(for: ref) else { return }
        let isTopic = ref.day == nil && (index.entry(ref.path)?.isTopic == true || Backlinks.isEmpty(view.editor.fullRows))
        guard isTopic else {
            if column.backlinks != nil {
                column.backlinks = nil
                column.showInlineBacklinks(nil, names: backlinkName)
            }
            return
        }
        let index = index
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak column] in
            let sources = index.backlinks(to: ref.path)
            DispatchQueue.main.async {
                guard let self, let column, column.kind == .note(ref), column.backlinks != sources,
                      !column.isTypingInSlice else { return }
                column.backlinks = sources
                column.showInlineBacklinks(sources, names: self.backlinkName)
            }
        }
    }

    /// Whether notes say nothing but their titles, by path, as of when
    /// they were last changed: read once a change.
    private var emptiness: [String: (modified: Date, empty: Bool)] = [:]

    private func isEmptyTopic(_ entry: NoteEntry) -> Bool {
        if let known = emptiness[entry.path], known.modified == entry.modified { return known.empty }
        let empty = index.body(entry.path).map { Backlinks.isEmpty(OutlineMarkdown.parse($0).rows) } ?? false
        emptiness[entry.path] = (entry.modified, empty)
        return empty
    }

    // MARK: Keeping up

    /// Watches the graph's notes, so every view of them — the days, a note,
    /// the inbox, what links where, the tasks, the sidebar — follows every
    /// change to them, made here or anywhere, as it is made.
    private var watcher: GraphWatcher?

    /// Notes changed on disk: everything showing them caught up.
    private func notesChanged(_ paths: Set<String>) {
        // A sync touching many at once: the whole graph read again.
        if paths.count > 40 { index.scan() } else { paths.forEach(index.refresh) }
        let entries = timelineEntries()
        for column in columns {
            column.reloadFromDisk(paths)
            column.updateTimeline(entries)
        }
        refreshInboxes()
        refreshBacklinks()
        refreshTaskColumns()
        refreshSearches()
        refreshSidebar()
        showHeading()
    }

    // MARK: The tasks

    /// Opens a column of the tasks, right of this one — or goes to the one open.
    @objc func showTasks(_ sender: Any?) {
        if !wantsNewColumn, let open = columns.first(where: { $0.kind == .tasks }) {
            active = open
            return
        }
        let (column, fresh) = columnBeside(focusedColumn)
        if !fresh { push(column) }
        active = column
        refreshTasks(column, force: true)
        saveLayout()
    }

    /// What the tasks shown were, by column: shown again only when changed.
    private var shownTasks: [ObjectIdentifier: [String]] = [:]

    /// Shows the open tasks in a column: in Reflect's groups, those at the
    /// same place in a note together under the path to it, each just the
    /// task and what is under it.
    private func refreshTasks(_ column: Column, force: Bool = false) {
        column.taskEditors.forEach { $0.flush() }
        let tasks = index.tasks()
        let signature = tasks.map { "\($0.notePath)#\($0.ordinal)#\($0.text)" }
        guard force || shownTasks[ObjectIdentifier(column)] != signature || column.kind != .tasks else { return }
        shownTasks[ObjectIdentifier(column)] = signature
        // Each note read once, its tasks cut out of it with what is under them.
        var slices: [String: TaskSlice] = [:]
        var editable: Set<String> = []
        for (path, list) in Dictionary(grouping: tasks, by: \.notePath) {
            guard let source = graph.read(path: path) else { continue }
            if OutlineMarkdown.roundTrips(source) { editable.insert(path) }
            for slice in TaskSlice.slices(of: list, in: source) { slices["\(path)#\(slice.task?.ordinal ?? -1)"] = slice }
        }
        let groups = Tasks.group(tasks, today: .today).map { group -> TaskGroupBlock in
            var runs: [(steps: [String], slices: [TaskSlice])] = []
            var last: (String, [String])?
            for task in group.tasks {
                guard let slice = slices["\(task.notePath)#\(task.ordinal)"] else { continue }
                let crumbs = Tasks.visibleBreadcrumbs(task.breadcrumbs)
                let key = (task.notePath, crumbs)
                if let last, last == key {
                    runs[runs.count - 1].slices.append(slice)
                } else {
                    // In a note's own group, the note goes without saying.
                    let note = task.day.map(OpenQuickly.dayTitle) ?? task.noteTitle
                    runs.append((group.kind == .note ? crumbs : [note] + crumbs, [slice]))
                }
                last = key
            }
            let block = TaskGroupBlock(group: group, runs: runs, metrics: metrics, face: face, images: images, navigator: column,
                                       onEdit: { [weak self, weak column] editor in
                                           guard let self, let column else { return }
                                           writeBack(editor, in: column)
                                       },
                                       onResize: { [weak column] in column?.relayout() },
                                       onLeave: { [weak self] in self?.refreshTaskColumns() },
                                       onOpen: { [weak self, weak column] path, newColumn in
                                           guard let self, let column else { return }
                                           openAlone(NoteRef(path: path), from: column, newColumn: newColumn)
                                       })
            for editor in block.editors where !editable.contains(editor.slice.path) { editor.view.isEditable = false }
            return block
        }
        column.showTasks(groups, count: tasks.count)
    }

    /// The tasks columns caught up — but not one being typed in, which
    /// waits till the keyboard has left it.
    private func refreshTaskColumns() {
        for column in columns where column.kind == .tasks {
            if let editor = window?.firstResponder as? OutlineTextView, column.taskEditors.contains(where: { $0.view === editor }) {
                staleTasks.insert(ObjectIdentifier(column))
                continue
            }
            staleTasks.remove(ObjectIdentifier(column))
            refreshTasks(column)
        }
    }

    /// Tasks columns with changes waiting, while they were typed in.
    private var staleTasks: Set<ObjectIdentifier> = []

    /// Writes a task as edited back to its place in its note, and has the
    /// others of the note after it move along as it grew or shrank.
    private func writeBack(_ editor: TaskEditor, in column: Column) {
        let path = editor.slice.path
        guard let source = graph.read(path: path) else { return }
        let rows = editor.rowsInNote
        guard let updated = editor.slice.writing(rows, into: source) else { return refreshTasks(column, force: true) }
        do {
            try graph.write(updated, path: path)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        index.refresh(path)
        let delta = rows.count - editor.slice.count
        editor.slice.count = rows.count
        for other in column.sliceEditors where other !== editor && other.slice.path == path && other.slice.start > editor.slice.start {
            other.slice.start += delta
        }
        column.relayout()
    }

    // MARK: The inbox

    /// Opens a column of the inbox, right of this one — or goes to the one open.
    @objc func showInbox(_ sender: Any?) {
        if !wantsNewColumn, let open = columns.first(where: { $0.kind == .inbox }) {
            active = open
            if let view = open.views.first { window?.makeFirstResponder(view.editor) }
            return
        }
        let (column, fresh) = columnBeside(focusedColumn)
        if !fresh { push(column) }
        active = column
        refreshInbox(column)
        if let view = column.views.first { window?.makeFirstResponder(view.editor) }
        saveLayout()
    }

    private func refreshInbox(_ column: Column) {
        column.showInbox(index.inbox.map { NoteRef(path: $0.path) })
    }

    private func refreshInboxes() {
        for column in columns where column.kind == .inbox { refreshInbox(column) }
    }

    // MARK: The note's own settings

    /// Sets or takes away a frontmatter key of a note — `inbox`, `pinned`,
    /// `topic`, `private` — and has everything that shows it catch up.
    private func setFrontmatter(_ path: String, _ key: String, _ value: String?) {
        save()
        guard let source = graph.read(path: path) else { return NSSound.beep() }
        let updated = Frontmatter.setting(key, to: value, in: source)
        guard updated != source else { return }
        do {
            try graph.write(updated, path: path)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        index.refresh(path)
        columns.forEach { $0.reloadFromDisk() }
        refreshInboxes()
        refreshBacklinks()
        refreshSidebar()
    }

    /// The note the Note menu is about: the one the keyboard is in.
    private var menuNote: NoteEntry? {
        focusedNote.flatMap { index.entry($0.path) ?? NoteIndex.entry(path: $0.path, source: graph.read(path: $0.path) ?? "") }
    }

    /// A note's own menu, from the ⋯ at the right of its name: what the Note
    /// menu does, done to that note — the keyboard put in it first, so the
    /// menu's items know which.
    private func showNoteMenu(for view: DayView, from button: NSButton) {
        window?.makeFirstResponder(view.editor)
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        item("Add to Inbox", #selector(toggleInbox(_:)))
        item("Pin", #selector(togglePinned(_:)))
        item("Topic", #selector(toggleTopic(_:)))
        item("Private", #selector(togglePrivate(_:)))
        menu.addItem(.separator())
        item("Backlinks", #selector(showBacklinks(_:)))
        item("Copy Link", #selector(copyNoteLink(_:)))
        item("Reveal in Finder", #selector(revealNoteInFinder(_:)))
        // Among others, how its card shows it.
        if columns.contains(where: { $0.listsNotes && $0.views.contains(view) }) {
            menu.addItem(.separator())
            NoteCardBlock.showAsItems(view.ref.path).forEach(menu.addItem)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.height + 4 : -4), in: button)
    }

    @objc func toggleInbox(_ sender: Any?) {
        guard let note = menuNote else { return NSSound.beep() }
        setFrontmatter(note.path, "inbox", note.isInInbox ? nil : "true")
    }

    @objc func togglePinned(_ sender: Any?) {
        guard let note = menuNote, note.day == nil else { return NSSound.beep() }
        setFrontmatter(note.path, "pinned", note.pin == nil ? String(index.nextPinOrder) : nil)
    }

    @objc func toggleTopic(_ sender: Any?) {
        guard let note = menuNote, note.day == nil else { return NSSound.beep() }
        setFrontmatter(note.path, "topic", note.isTopic ? nil : "true")
    }

    @objc func togglePrivate(_ sender: Any?) {
        guard let note = menuNote else { return NSSound.beep() }
        setFrontmatter(note.path, "private", note.isPrivate ? nil : "true")
    }

    /// Puts a `[[link]]` to the note on the pasteboard.
    @objc func copyNoteLink(_ sender: Any?) {
        guard let note = menuNote else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("[[\(note.day?.description ?? note.title)]]", forType: .string)
    }

    @objc func revealNoteInFinder(_ sender: Any?) {
        guard let note = menuNote, graph.exists(path: note.path) else { return NSSound.beep() }
        NSWorkspace.shared.activateFileViewerSelecting([graph.url(for: note.path)])
    }

    func windowWillClose(_ notification: Notification) { save() }

    private func refreshSidebar() {
        guard sidebarShown || sidebarPinned else { return }
        let today = Day.today
        var days = [today]
        days += graph.dailyNoteFiles().keys.filter { $0 < today }.sorted(by: >).prefix(6)
        let dayPlaces = days.map { day in
            Place(title: day == today ? "Today" : OpenQuickly.dayTitle(day), path: GraphPaths.dailyPath(for: day),
                  flags: NoteFlags(index.entry(GraphPaths.dailyPath(for: day))))
        }
        // Among the pinned, their pins go without saying.
        let pinned = index.pinned.map { Place(title: $0.title, path: $0.path, flags: NoteFlags($0).subtracting(.pinned)) }
        let pinnedPaths = Set(pinned.map(\.path))
        let recent = index.all.filter { $0.day == nil && !$0.path.hasPrefix(GraphPaths.weeklyDirectory + "/") && !pinnedPaths.contains($0.path) }
            .sorted { $0.modified > $1.modified }.prefix(12).map { Place(title: $0.title, path: $0.path, flags: NoteFlags($0)) }
        sidebar.show([("Days", dayPlaces), ("Pinned", pinned), ("Recent", Array(recent))],
                     current: active.flatMap(location(of:)), face: face)
    }

    private func find(_ query: String) -> [Place] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var places: [Place] = []
        if trimmed.isEmpty || "today".hasPrefix(trimmed.lowercased()) {
            places.append(Place(title: "Today", path: GraphPaths.dailyPath(for: .today), detail: OpenQuickly.dayTitle(.today)))
        }
        // Any day, as it might be said — `friday`, `3 days ago`, `march 5` —
        // whether it has a note yet or not.
        if let day = DayQuery.day(trimmed), !(day == .today && !places.isEmpty) {
            let path = GraphPaths.dailyPath(for: day)
            let relative = day == .today ? "Today" : day == Day.today.adding(-1) ? "Yesterday" : day == Day.today.adding(1) ? "Tomorrow" : "Day"
            places.append(Place(title: OpenQuickly.dayTitle(day), path: path,
                                detail: graph.exists(path: path) ? relative : relative + " · no note yet"))
        }
        let relative = { (date: Date) in
            RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        }
        places += index.matches(trimmed, limit: 20).map {
            Place(title: $0.entry.title, path: $0.entry.path, detail: $0.alias.map { "as \($0)" } ?? relative($0.entry.modified),
                  flags: NoteFlags($0.entry))
        }
        return places
    }

    // MARK: Commands

    /// This week's note, before its days in the timeline — there to write
    /// in, if there is none yet.
    @objc func goThisWeek(_ sender: Any?) {
        let timeline = focusedColumn.isTimeline ? focusedColumn : columns.first { $0.isTimeline } ?? focusedColumn
        open(GraphPaths.weeklyPath(for: .current), from: timeline)
    }

    /// ⌘N: a new row at the top of today — under its title, if it has
    /// one — the caret in it; in today's own empty row, when it has none.
    @objc func writeToday(_ sender: Any?) {
        goToday(sender)
        let today = NoteRef.day(.today)
        // Once today is laid out where it was gone to.
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = columns.lazy.compactMap({ $0.view(for: today) }).first else { return NSSound.beep() }
            let editor = view.editor
            let rows = editor.rows
            window?.makeFirstResponder(editor)
            let at = rows.first.map { if case .heading(1) = $0.kind { 1 } else { 0 } } ?? 0
            // Its first row empty already: that one, not another.
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

    // MARK: Link notes' pages

    /// A link note's page, in a column of its own beside the note's — or
    /// the one already showing it.
    private func openPage(of ref: NoteRef, beside column: Column) {
        save()
        if let open = columns.first(where: { $0.kind == .web(ref) }) {
            active = open
            return
        }
        let new = addColumn(after: column)
        materialize(Sheet(kind: .web(ref), place: nil, offset: 0, title: Column.title(of: .web(ref), top: nil), snapshot: nil), in: new)
        saveLayout()
    }

    /// Shows a link note's page in a column, its note's highlights marked.
    private func showPage(of ref: NoteRef, in column: Column) {
        let source = graph.read(path: ref.path) ?? ""
        guard let address = WebCapture.url(in: source), let url = URL(string: address) else { return NSSound.beep() }
        column.showWeb(ref, url: url, highlights: WebCapture.highlights(in: source))
    }

    /// The pages of a note shown, marked as its note now says.
    private func refreshPages(of ref: NoteRef) {
        let pages = columns.filter { $0.kind == .web(ref) }
        guard !pages.isEmpty else { return }
        let highlights = WebCapture.highlights(in: graph.read(path: ref.path) ?? "")
        pages.forEach { $0.updateWebHighlights(highlights) }
    }

    /// A passage highlighted on a page: kept in its note, under its Highlights.
    private func highlight(_ passage: String, in ref: NoteRef) {
        save()
        guard let source = graph.read(path: ref.path) else { return NSSound.beep() }
        let updated = WebCapture.highlighting(passage, in: source)
        guard updated != source else { return }
        do {
            try graph.write(updated, path: ref.path)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        index.refresh(ref.path)
        columns.forEach { $0.reloadFromDisk([ref.path]) }
    }

    // MARK: Pages captured in a browser

    /// A page the browser extension captured: its screenshot kept in the
    /// graph's assets, its note written — or, captured before, added to —
    /// and linked from today; every column showing them caught up.
    func capture(_ page: WebCapture.Page, screenshot: Data?) throws -> (path: String, title: String) {
        save()
        var page = page
        if let screenshot {
            let name = "screenshot-" + Assets.slug(WebCapture.title(page.title, url: page.url)).prefix(40) + "-"
                + Assets.pastedName(extension: "png").replacingOccurrences(of: "pasted-", with: "")
            page.screenshot = try Assets.add(screenshot, named: name, to: graph.root)
        }
        let path = try WebCapture.save(page, in: graph, index: index)
        notesChanged([path, GraphPaths.dailyPath(for: .today)])
        sync.noteChanged()
        return (path, index.entry(path)?.title ?? WebCapture.title(page.title, url: page.url))
    }

    /// A captured page's note, opened from the browser: the window brought
    /// forward, the note in the column the keyboard is in.
    func openCaptured(_ path: String) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        open(path)
    }

    /// ⌘D: today, in the column the keyboard is in — its timeline taken
    /// there, or, showing anything else, a timeline put on it about today.
    @objc func goToday(_ sender: Any?) {
        let column = focusedColumn
        if column.isTimeline {
            open(GraphPaths.dailyPath(for: .today), from: column)
        } else {
            openSheet(.timeline, at: .day(.today), on: column)
        }
    }

    /// Back: the top sheet of the focused column taken off.
    @objc func goBack(_ sender: Any?) { pop(focusedColumn) }

    @objc func goForward(_ sender: Any?) { forward(0, in: focusedColumn) }

    @objc func pinSheet(_ sender: Any?) { togglePinnedSheet(nil, in: focusedColumn) }

    @objc func findNote(_ sender: Any?) { showFinder() }

    /// ⌘W: the top sheet, then, with none beneath, the column.
    @objc func closeColumn(_ sender: Any?) {
        let column = focusedColumn
        if !column.beneath.isEmpty {
            pop(column)
        } else if columns.count > 1 {
            close(column)
        } else {
            window?.performClose(sender)
        }
    }

    func showFinder(query: String = "") {
        _ = focusedColumn
        if finder.superview == nil {
            if !sidebarPinned { setSidebar(shown: false, animated: true) }
            finder.frame = page.bounds
            page.addSubview(finder)
        }
        finder.open(face: face, query: query)
    }

    // MARK: Recent edits

    /// The rows changed since a note was last read, kept as recent edits.
    private func noteEdits(_ path: String) {
        let now = graph.read(path: path) ?? ""
        let before = lastText[path] ?? now
        lastText[path] = now
        guard before != now else { return }
        recent.note(path, from: before, to: now)
        saveRecent()
    }

    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static func recentURL(_ root: URL) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Prism")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let scripted = ProcessInfo.processInfo.environment["PRISM_SNAP"] != nil
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

    /// Written a moment later, once for many saves.
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

    /// ⌘Y: the rows lately written in, found by their words or their parents'.
    @objc func showRecentEdits(_ sender: Any?) {
        save()
        _ = focusedColumn
        if recentFinder.superview == nil {
            recentFinder.frame = page.bounds
            page.addSubview(recentFinder)
        }
        recentFinder.open(face: face)
    }

    private func closeRecent() {
        recentFinder.removeFromSuperview()
        if let view = active?.current { window?.makeFirstResponder(view.editor) }
    }

    private func findRecent(_ query: String) -> [Place] {
        recent.matching(query, title: { Column.name(of: NoteRef(path: $0)).title }).compactMap { edit in
            guard graph.exists(path: edit.path) else { return nil }
            let note = NoteRef(path: edit.path)
            let name = Column.name(of: note).title
            let path = ([name] + edit.ancestors.map { InlineMarkup.plainText($0) }).joined(separator: "  ›  ")
            let text = InlineMarkup.plainText(edit.text)
            return Place(title: text.isEmpty ? "(empty)" : text, path: edit.path, detail: Self.ago.localizedString(for: edit.date, relativeTo: Date()), trail: path, edit: edit)
        }
    }

    /// `PRISM_RECENT=<query>`: ⌘Y's finder opened on a query, its rows printed;
    /// `PRISM_RECENT_GO=1`, the first gone to, and the caret's row printed.
    func recentForScript(_ query: String, go: Bool) {
        showRecentEdits(nil)
        recentFinder.open(face: face, query: query)
        for place in findRecent(query).prefix(5) { print("recent: \(place.trail ?? "") ›› \(place.title)") }
        guard go, let edit = findRecent(query).first?.edit else { return }
        closeRecent()
        goTo(edit, newColumn: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let editor = self?.window?.firstResponder as? OutlineTextView else { return print("caret: none") }
            let row = editor.rowIndex(at: editor.selectedRange().location)
            print("caret: row \(row) “\(editor.rows[row].text)”")
        }
    }

    /// Goes to an edit's row: its note opened, the row shown, the caret at its end.
    private func goTo(_ edit: RecentEdits.Edit, newColumn: Bool) {
        open(edit.path, newColumn: newColumn)
        let ref = NoteRef(path: edit.path)
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = columns.lazy.compactMap({ $0.view(for: ref) }).first,
                  let target = RecentEdits.locate(edit, in: graph.read(path: edit.path) ?? "") else { return }
            let editor = view.editor
            guard let row = editor.showRow(unfolded: target) else { return }
            window?.makeFirstResponder(editor)
            editor.editText(inRow: row)
            editor.showFindIndicator(for: editor.paragraphRanges[row])
        }
    }

    private func closeFinder() {
        finder.removeFromSuperview()
        if let view = active?.current { window?.makeFirstResponder(view.editor) }
    }

    @objc func toggleSidebar(_ sender: Any?) { sidebarPinned.toggle() }

    @objc func chooseTypeface(_ sender: NSMenuItem) {
        guard let face = Typeface(rawValue: sender.representedObject as? String ?? "") else { return }
        self.face = face
    }

    @objc func biggerText(_ sender: Any?) { size = min(26, size + 1) }
    @objc func smallerText(_ sender: Any?) { size = max(11, size - 1) }
    @objc func actualSizeText(_ sender: Any?) { size = CGFloat(face.defaults.size) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(chooseTypeface(_:)):
            item.state = item.representedObject as? String == face.rawValue ? .on : .off
        case #selector(toggleSidebar(_:)):
            item.title = sidebarPinned ? "Hide Sidebar" : "Show Sidebar"
        case #selector(closeColumn(_:)):
            item.title = !focusedColumn.beneath.isEmpty ? "Close Sheet" : columns.count > 1 ? "Close Column" : "Close"
        case #selector(switchSheets(_:)), #selector(switchSheetsBackward(_:)):
            return !focusedColumn.beneath.isEmpty || switcherColumn != nil
        case #selector(toggleInbox(_:)):
            item.title = menuNote?.isInInbox == true ? "Remove from Inbox" : "Add to Inbox"
            return menuNote != nil
        case #selector(togglePinned(_:)):
            item.title = menuNote?.pin != nil ? "Unpin" : "Pin"
            return menuNote.map { $0.day == nil } ?? false
        case #selector(toggleTopic(_:)):
            item.state = menuNote?.isTopic == true ? .on : .off
            return menuNote.map { $0.day == nil } ?? false
        case #selector(togglePrivate(_:)):
            item.state = menuNote?.isPrivate == true ? .on : .off
            return menuNote != nil
        case #selector(copyNoteLink(_:)), #selector(revealNoteInFinder(_:)):
            return menuNote != nil
        case #selector(goBack(_:)): return !focusedColumn.beneath.isEmpty
        case #selector(goForward(_:)): return !focusedColumn.ahead.isEmpty
        case #selector(toggleCollapsed(_:)): return columns.count > 1
        case #selector(pinSheet(_:)):
            item.title = focusedColumn.isPinned ? "Unpin Sheet" : "Pin Sheet"
            return true
        default: break
        }
        return true
    }

    // MARK: For scripts

    func snapshot(to url: URL) {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Types at the end of a note on the page, as from the keyboard.
    func typeForScript(_ text: String, in path: String) {
        guard let view = columns.lazy.compactMap({ $0.view(for: NoteRef(path: path)) }).first else { return }
        let editor = view.editor
        window?.makeFirstResponder(editor)
        editor.enter(from: .bottom, x: .greatestFiniteMagnitude, scrolling: false)
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            if i > 0 { editor.insertNewline(nil) }
            if !line.isEmpty { editor.insertText(line, replacementRange: editor.selectedRange()) }
        }
    }

    /// The caret at a note's top, its nth checkbox scrolled to and
    /// clicked: where the column was scrolled, before and after.
    func clickBoxForScript(in path: String, nth: Int) {
        guard let column = columns.first(where: { $0.view(for: NoteRef(path: path)) != nil }),
              let editor = column.view(for: NoteRef(path: path))?.editor else { return print("no note") }
        let boxes = editor.rows.indices.filter { editor.rows[$0].task != nil }
        guard !boxes.isEmpty else { return print("no checkbox") }
        let row = boxes[min(max(nth, 1), boxes.count) - 1]
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.scrollRangeToVisible(editor.paragraphRanges[row])
        let before = column.scrolledForScript
        editor.clickHandleForScript(ofRow: row)
        DispatchQueue.main.async {
            print("clicked row \(row): scrolled \(before) -> \(column.scrolledForScript); caret at \(editor.selectedRange().location)")
        }
    }

    /// Follows a `[[link]]` as a ⌘-click does: into a column of its own.
    func openInColumnForScript(_ title: String) {
        guard let url = URL(string: "reflect-note:" + (title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title)) else { return }
        follow(url, from: columns[0], newColumn: true)
    }

    /// Moves a note's first top-level item, with what is under it, to the
    /// end of the last column's note — as dragging it there does.
    func moveRowForScript(from path: String) {
        guard let source = columns.lazy.compactMap({ $0.view(for: NoteRef(path: path)) }).first?.editor,
              let target = columns.last?.views.first?.editor, source !== target else { return }
        let rows = source.rows
        guard let first = rows.indices.first(where: { rows[$0].depth == 0 && rows[$0].kind.isListItem }) else { return }
        let block = OutlineEditing.block(rows, first..<(first + 1))
        target.moveRows(block, from: source, to: .init(index: target.rows.count, depth: 0))
    }

    /// Opens the backlinks column of a note, from the column it is in.
    /// `PRISM_STACK`: steps on a column's stack, in turn — `pin:<i>` (`pin:top`
    /// for its own), `back:<i>`, `forward:<i>`, `open:<title>` — each printed after.
    func stackForScript(_ steps: String) {
        let index = ProcessInfo.processInfo.environment["PRISM_PEEK_COLUMN"].flatMap(Int.init)
        guard let column = index.flatMap({ columns.indices.contains($0) ? columns[$0] : nil }) ?? columns.last else { return }
        for step in steps.split(separator: "|") {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "pin": togglePinnedSheet(arg == "top" ? nil : Int(arg), in: column)
            case "back": raise(Int(arg) ?? column.beneath.count - 1, in: column)
            case "forward": forward(Int(arg) ?? 0, in: column)
            case "open": addSheet(SheetBar.Choice.allCases.first { $0.name.lowercased() == arg } ?? .inbox, on: column)
            case "age":
                // `age:<i>:<hours>`: a sheet beneath left so long ago.
                let bits = arg.split(separator: ":").compactMap { Double($0) }
                if bits.count == 2, column.beneath.indices.contains(Int(bits[0])) {
                    column.beneath[Int(bits[0])].seen = Date().addingTimeInterval(-bits[1] * 3600)
                }
            case "today":
                window?.makeFirstResponder(nil)
                active = column
                goToday(nil)
            case "fold": setCollapsed(true, column)
            case "unfold": setCollapsed(false, column)
            default: break
            }
            print("\(step): " + sheetsForScript)
        }
    }

    /// `PRISM_OPEN_PAGE=<path>`: a link note's page opened beside it; after a
    /// while, the passages marked on it printed — `PRISM_PAGE_CHOOSE` first
    /// chosen and highlighted, as the button does — and the note's after.
    func openPageForScript(_ path: String) {
        let ref = NoteRef(path: path)
        guard let column = columns.first else { return }
        openPage(of: ref, beside: column)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, let page = columns.first(where: { $0.kind == .web(ref) }) else { return print("page: none") }
            page.checkWebForScript(choosing: ProcessInfo.processInfo.environment["PRISM_PAGE_CHOOSE"]) { marked in
                print("marked: " + marked)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    print("note highlights: " + WebCapture.highlights(in: self.graph.read(path: path) ?? "").joined(separator: " | "))
                }
            }
        }
    }

    func peekForScript(pointingAt index: Int?) {
        let env = ProcessInfo.processInfo.environment
        let column = env["PRISM_PEEK_COLUMN"].flatMap(Int.init).flatMap { columns.indices.contains($0) ? columns[$0] : nil } ?? columns.last
        guard let column else { return }
        column.showSheetListForScript(pointingAt: index)
        if env["PRISM_PEEK_LIVE"] == "1", let index { column.peekLiveForScript(index) }
        // `PRISM_PEEK_CLICK`: a click on the oldest sheet, as the mouse would send it.
        guard env["PRISM_PEEK_CLICK"] == "1", let window, let point = column.oldestSheetPointForScript else { return }
        print("before click: " + sheetsForScript)
        // Ordered in where it is, off screen, the app not brought forward: windows not in take no clicks.
        window.orderFrontRegardless()
        let at = column.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            print("after click:  " + sheetsForScript)
        }
    }

    func sheetBarForScript(_ choice: String) {
        let index = ProcessInfo.processInfo.environment["PRISM_PEEK_COLUMN"].flatMap(Int.init)
        guard let column = index.flatMap({ columns.indices.contains($0) ? columns[$0] : nil }) ?? columns.last else { return }
        column.updateSheetBar()
        guard let pick = SheetBar.Choice.allCases.first(where: { $0.name.lowercased() == choice }) else { return }
        addSheet(pick, on: column)
        column.updateSheetBar()
    }

    func showBacklinksForScript(_ path: String) {
        if let view = columns.lazy.compactMap({ $0.view(for: NoteRef(path: path)) }).first {
            window?.makeFirstResponder(view.editor)
        }
        showBacklinks(nil)
    }

    /// Scrolls the first column a step at a time — up for steps under
    /// 0 — the app running between, as a person scrolling does; then `done`.
    func scrollForScript(steps: Int, done: @escaping () -> Void) {
        guard steps != 0, !columns.isEmpty else { return done() }
        // The first column — the timeline — and, with others, the last too.
        for column in Set([columns.first!, columns.last!].map(ObjectIdentifier.init)).compactMap({ id in columns.first { ObjectIdentifier($0) == id } }) {
            column.scrollForScript(by: steps < 0 ? -500 : 500)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            self?.scrollForScript(steps: steps < 0 ? steps + 1 : steps - 1, done: done)
        }
    }

    /// The window on the timeline, and what the first column holds.
    var timelineForScript: String {
        "shown \(columns.first?.shown ?? 0..<0) at \(columns.first?.scrolledForScript ?? "-") first \(columns.first?.views.first?.ref.path ?? "-") count \(columns.first?.views.count ?? 0)"
    }

    /// Collapses every row of a note on the page, as Outline ▸ Collapse All does.
    func collapseAllForScript(in path: String) {
        guard let view = columns.lazy.compactMap({ $0.view(for: NoteRef(path: path)) }).first else { return }
        window?.makeFirstResponder(view.editor)
        view.editor.collapseAll(nil)
    }

    /// Chooses the finder's first result as ⌘↩ does: into a column of its own.
    func chooseInNewColumnForScript() {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                           windowNumber: window?.windowNumber ?? 0, context: nil, characters: "\r",
                                           charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { return }
        _ = finder.performKeyEquivalent(with: event)
    }

    /// Puts a note in the inbox, or takes it out, from the Note menu.
    func toggleInboxForScript(_ path: String) {
        if let view = columns.lazy.compactMap({ $0.view(for: NoteRef(path: path)) }).first {
            window?.makeFirstResponder(view.editor)
        }
        toggleInbox(nil)
    }

    /// Clicks the × on an inbox note.
    func removeFromInboxForScript(_ path: String) { setFrontmatter(path, "inbox", nil) }

    /// Follows a `[[link]]` as a plain click does: onto the column's stack.
    func followForScript(_ title: String) {
        guard let url = URL(string: "reflect-note:" + (title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title)) else { return }
        follow(url, from: focusedColumn, newColumn: false)
    }

    /// Opens ⌘E's cards, moved down so many, settled, and left open.
    func switchForScript(moves: Int, pick: Bool = false) {
        if pick || ProcessInfo.processInfo.environment["PRISM_SWITCH_KEYS"] != nil {
            window?.makeFirstResponder(nil)
            active = columns.max { $0.beneath.count < $1.beneath.count }
        }
        cycleSheets(backward: false)
        for _ in 0..<abs(moves) { switcherColumn?.moveSwitcher(moves < 0 ? 1 : -1) }
        switcherColumn?.settleSwitcherForScript()
        if let typed = ProcessInfo.processInfo.environment["PRISM_SWITCH_TYPE"] {
            switcherColumn?.findInSwitcher(typed)
            switcherColumn?.settleSwitcherForScript()
        }
        if let at = ProcessInfo.processInfo.environment["PRISM_SWITCH_AT"].flatMap(Double.init) {
            switcherColumn?.freezeSwitcherForScript(at: CGFloat(at))
        }
        // `PRISM_SWITCH_KEYS`: letters typed as the keyboard would, ⌘ held, then ⌘ let go.
        if let keys = ProcessInfo.processInfo.environment["PRISM_SWITCH_KEYS"], let window {
            print("before keys: " + sheetsForScript)
            // Ordered in, off screen, not brought forward: its animations run.
            window.orderFrontRegardless()
            for character in keys {
                let text = character == "<" ? "\u{7f}" : String(character)
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false,
                                                keyCode: character == "<" ? 51 : 0) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            // Then ⌘ let go — which can't be posted as an event — the choice taken.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let column = switcherColumn, let chosen = column.switcherSelection else { return }
                print("typed: \(column.switcherQuery ?? "") chose: \(chosen)")
                endSwitcher(choosing: nil)
                if chosen < column.beneath.count { raise(chosen, in: column) }
                print("after keys:  " + sheetsForScript)
            }
            return
        }
        // Escape, as the keyboard would send it, ⌘ still down: nothing chosen.
        if ProcessInfo.processInfo.environment["PRISM_SWITCH_ESC"] == "1", let window {
            print("before escape: " + sheetsForScript)
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                          charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            NSApp.postEvent(escape, atStart: false)
            let release = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                           isARepeat: false, keyCode: 55)
            if let release { NSApp.postEvent(release, atStart: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                print("after escape:  " + sheetsForScript + "  switcher open: \(switcherColumn != nil)")
            }
            return
        }
        // ⌘ let go: the stack gone back down to the one chosen.
        guard pick, let column = switcherColumn, let chosen = column.switcherSelection else { return }
        print("before: " + sheetsForScript)
        endSwitcher(choosing: nil)
        if chosen < column.beneath.count { raise(chosen, in: column) }
        print("after:  " + sheetsForScript)
    }

    var scrubberAlphasForScript: [CGFloat] { columns.map(\.scrubberAlphaForScript) }

    var sheetsForScript: String {
        columns.map { column in
            (column.beneath.map { $0.title + ($0.pinned ? "📌" : "") } + ["[" + column.currentSheet.title + (column.isPinned ? "📌" : "") + "]"]
                + column.ahead.map { "→ " + $0.title }).joined(separator: " / ")
        }
            .joined(separator: "  ||  ")
    }

        /// A sheet dragged — from a column, the top or one beneath — to a place
    /// across the window (0 to 1) halfway down: shown there, or let go.
    func dragForScript(column: Int, index: Int?, at fraction: CGFloat, perform: Bool) {
        guard columns.indices.contains(column) else { return }
        let source = columns[column]
        let point = NSPoint(x: page.bounds.width * fraction, y: page.bounds.midY)
        let drop = drop(at: point, from: source, index: index)
        if perform {
            if let drop { move(index, from: source, to: drop) }
            return
        }
        let sheet = index.map { source.beneath[$0] } ?? source.currentSheet
        let card = SwitcherCard(sheet: sheet, contentSize: source.bounds.size, face: face)
        let width = min(240, source.bounds.width * 0.5)
        let height = SwitcherCard.headerHeight + source.bounds.height * width / source.bounds.width * 0.5
        page.addSubview(dropMarker)
        page.addSubview(card)
        card.frame = cardFrame(at: point, width: width, height: height)
        showMarker(for: drop)
    }

    /// Ticks the first task in the tasks column, as clicking its box does,
    /// and writes it back.
    func tickFirstTaskForScript() {
        guard let column = columns.first(where: { $0.kind == .tasks }), let editor = column.taskEditors.first else { return }
        window?.makeFirstResponder(editor.view)
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        editor.view.toggleDone(nil)
        editor.flush()
        print("ticked \(editor.slice.path): \(editor.slice.task?.text ?? "")")
    }

    var scrollsForScript: String { columns.map { "\($0.kind): \($0.scrolledForScript)" }.joined(separator: " | ") }

    /// Folds the first backlink of the backlinks column, as its chevron does.
    func foldFirstBacklinkForScript() {
        guard let column = columns.first(where: { if case .backlinks = $0.kind { true } else { false } }),
              let block = column.blocks.compactMap({ $0 as? BacklinkBlock }).first else { return }
        block.toggleForScript()
    }

    /// Times becoming key, as switching to the app does.
    func becomeKeyForScript() {
        let start = Date()
        windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        print(String(format: "became key in %.0f ms", Date().timeIntervalSince(start) * 1000))
    }

    /// Types at the end of the first piece of a note shown away from it — a
    /// backlink, a search result — and writes it back.
    func typeInBacklinkForScript(_ text: String) {
        guard let column = columns.first(where: { !$0.sliceEditors.isEmpty }),
              let editor = column.sliceEditors.first else { return print("no backlink") }
        window?.makeFirstResponder(editor.view)
        editor.view.setSelectedRange(NSRange(location: (editor.view.string as NSString).length, length: 0))
        editor.view.insertText(text, replacementRange: editor.view.selectedRange())
        editor.flush()
        print("typed into \(editor.slice.path)")
    }

    /// Searches for words in a column of its own, as typing them would.
    func searchForScript(_ query: String) {
        let column = addColumn(after: focusedColumn)
        let start = Date()
        search(query, in: column)
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard column.blocks.count > 1 || Date().timeIntervalSince(start) > 3 else { return }
                timer.invalidate()
                print(String(format: "found %d notes in %.0f ms", column.blocks.count - 1, Date().timeIntervalSince(start) * 1000))
            }
        }
    }

    /// Opens an empty search, then types words into its field as the
    /// keyboard does, ↩ after them when asked.
    func typeSearchForScript(_ words: String, enter: Bool) {
        showSearch(nil)
        guard let column = columns.first(where: { if case .search = $0.kind { true } else { false } }),
              let header = column.blocks.first as? SearchHeader else { return print("no search") }
        window?.makeFirstResponder(header.field)
        guard let editor = header.field.currentEditor() as? NSTextView else { return print("no field editor") }
        editor.insertText(words, replacementRange: editor.selectedRange())
        if enter { editor.insertNewline(nil) }
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard column.blocks.count > 1 || Date().timeIntervalSince(start) > 3 else { return }
                timer.invalidate()
                print("query \(column.kind), \(column.blocks.count - 1) notes")
                if ProcessInfo.processInfo.environment["PRISM_FIND_KEY"] == "1", let editor = column.sliceEditors.last {
                    self.window?.makeFirstResponder(editor.view)
                    column.scrollForScript(by: 3000)
                    print("before: scrolled \(column.scrolledForScript)")
                    self.find(nil)
                    let inField = (column.blocks.first as? SearchHeader)?.field.currentEditor() === self.window?.firstResponder
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        print("after: in field \(inField), scrolled \(column.scrolledForScript)")
                    }
                }
            }
        }
    }

    /// ⌘N, a title typed, a line under it, and the title settled at once.
    func newNoteForScript(title: String) {
        newNote(nil)
        guard let view = focusedColumn.views.first else { return print("no note") }
        let made = view.ref.path
        view.editor.insertText(title, replacementRange: view.editor.selectedRange())
        view.editor.insertNewline(nil)
        view.editor.insertText("A first line.", replacementRange: view.editor.selectedRange())
        view.save()
        settleTitle(made)
        print("made \(made), now \(focusedColumn.views.first?.ref.path ?? "-"), titled \(index.entry(focusedColumn.views.first?.ref.path ?? "")?.title ?? "-")")
    }

    /// ⌘N, and away again without a word.
    func blankNoteForScript() {
        newNote(nil)
        let made = focusedColumn.views.first?.ref.path ?? "-"
        goBack(nil)
        DispatchQueue.main.async { print("blank \(made) still there: \(self.graph.exists(path: made))") }
    }

    func showSidebarForScript() { setSidebar(shown: true, animated: false); page.needsLayout = true }

    /// Hovers the first column's scrubber, at a place down it from 0 to 1.
    func hoverScrubberForScript(_ fraction: CGFloat) { columns.first?.hoverForScript(fraction) }
}

/// Between two columns: a hairline, and a grip either side of it that
/// shares the width out anew as it is dragged; double-clicked, evens all.
final class ColumnDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var onReset: (() -> Void)?
    /// How far either side of the line it can be taken hold of.
    static let reach: CGFloat = 4
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        (hovering ? Ink.faint : Ink.rule).setFill()
        NSRect(x: bounds.midX - (hovering ? 1 : 0.5), y: 0, width: hovering ? 2 : 1, height: bounds.height).fill()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?() }
    }

    override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow.x) }
    override func mouseUp(with event: NSEvent) { onEnd?() }
}

/// Where a dragged sheet will land: a column outlined, for its stack; a
/// band between columns, for a new one there.
final class DropMarker: NSView {
    private var newColumn = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ frame: NSRect?, newColumn: Bool) {
        guard let frame else { isHidden = true; return }
        isHidden = false
        self.newColumn = newColumn
        if self.frame != frame { self.frame = frame }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if newColumn {
            // The new column's place: a soft band, and a bar where it goes in.
            Ink.accent.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
            Ink.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 2, y: 8, width: 4, height: bounds.height - 16), xRadius: 2, yRadius: 2).fill()
        } else {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
            Ink.accent.withAlphaComponent(0.06).setFill()
            shape.fill()
            Ink.accent.withAlphaComponent(0.8).setStroke()
            shape.lineWidth = 2
            shape.stroke()
        }
    }
}

extension Notification.Name {
    /// The face, or how it is set, changed.
    static let prismTypographyChanged = Notification.Name("PrismTypographyChanged")
}

/// The window's content: tells of the pointer, for the sidebar.
final class PageView: NSView {
    var onLayout: (() -> Void)?
    var onMouseMoved: ((NSPoint) -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func draw(_ dirtyRect: NSRect) {
        Ink.paper.setFill()
        dirtyRect.fill()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }
}

/// A label over other things, to be read, not clicked: clicks go through it
/// to what is under — the first column's top, its stack of sheets.
final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
