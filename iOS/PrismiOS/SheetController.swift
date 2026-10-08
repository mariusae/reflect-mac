import UIKit
import ReflectCore
import PrismCore

/// What a sheet shows: the days, a note on its own, or a view of many.
enum SheetKind: Hashable, Codable {
    case timeline
    case note(String)
    case backlinks(String)
    case inbox
    case tasks
    case search(String)
    /// The pinned notes, in their order.
    case pinned
}

/// A sheet of a column: notes one under another, each editable where it is
/// — the timeline's days, oldest at the top, each week before its days; or
/// a note on its own — with a scrubber down the right edge whose ticks are
/// the days and what is in them, to drag along with the thumb.
final class SheetController: UIViewController, UIScrollViewDelegate {
    let store: PrismStore
    private(set) var kind: SheetKind
    /// Whether it lists notes, each a card that shows it as asked — not
    /// one note alone, always whole.
    var listsNotes: Bool { if case .note = kind { false } else { true } }
    let scroll = UIScrollView()
    private let content = UIView()
    private let scrubber = ScrubberView()
    private(set) var blocks: [SheetBlock] = []
    private var metrics: PhoneMetrics
    /// Asked to open a note — alone, on this column's stack — or a link.
    var onOpen: ((SheetKind) -> Void)?
    var onLink: ((String) -> Void)?
    /// Asked for the sheet's menu, and for a new note.
    var menu: ((SheetController) -> UIMenu)?
    /// Asked for a listed note's own menu.
    var noteMenu: ((SheetController, String) -> UIMenu)?
    var onCompose: (() -> Void)?
    /// Asked to go to a note or a day.
    var onFind: (() -> Void)?
    /// Asked to set a note's frontmatter key — `inbox`, `topic` — or take it away.
    var onFlag: ((String, String, String?) -> Void)?

    /// The timeline's entries, and the window of them shown.
    private var entries: [NoteRef] = []
    private var shown: Range<Int> = 0..<0
    private static let span = 40
    private static let step = 20
    /// The note to bring to the top once laid out.
    private var target: NoteRef?

    // MARK: Where it was left

    /// Where a sheet is scrolled to: the block at the top of the screen —
    /// by its note's path, or its place among the blocks — and how far
    /// into it. Kept as that, not as a distance down the sheet, so it
    /// holds however the notes above grow, shrink or are built.
    struct Place: Codable, Equatable {
        var path: String?
        var index: Int
        var offset: CGFloat
    }

    /// Where the caret was: in which note's which editor, and where.
    struct Focus: Codable, Equatable {
        var path: String
        var editor: Int
        var location: Int
    }

    /// Where it is scrolled to now.
    var place: Place? {
        guard !blocks.isEmpty else { return nil }
        let top = scroll.contentOffset.y + scroll.adjustedContentInset.top
        guard let index = blocks.lastIndex(where: { $0.frame.minY <= top + 0.5 }) else { return nil }
        return Place(path: Self.path(of: blocks[index]), index: index, offset: top - blocks[index].frame.minY)
    }

    /// Where the caret is now, when it is in this sheet.
    var focus: Focus? {
        for block in blocks {
            guard let path = Self.path(of: block) else { continue }
            for (i, editor) in block.editors.enumerated() where editor.isFirstResponder {
                return Focus(path: path, editor: i, location: editor.selectedRange.location)
            }
        }
        return nil
    }

    private static func path(of block: SheetBlock) -> String? {
        (block as? NoteBlock)?.ref.path ?? (block as? SliceBlock)?.path
    }

    /// Where to be scrolled to, and where the caret goes, once laid out —
    /// for lists found off the main thread, once what was there is there.
    private var pendingPlace: Place?
    private var pendingFocus: Focus?
    /// Told when where it is scrolled to, or the caret, may have changed.
    var onStateChange: (() -> Void)?

    func restore(place: Place?, focus: Focus?) {
        pendingPlace = place
        pendingFocus = focus
        // A day in the timeline: the window put about it first.
        if case .timeline = kind, let path = place?.path, Timeline.day(of: NoteRef(path: path)) != nil { target = NoteRef(path: path) }
        if isViewLoaded { relayout() }
    }

    /// The block a place names, when it is there.
    private func block(for place: Place) -> SheetBlock? {
        if let path = place.path { return blocks.first { Self.path(of: $0) == path } }
        return blocks.indices.contains(place.index) ? blocks[place.index] : nil
    }

    private func applyPending() {
        if let place = pendingPlace, let block = block(for: place) {
            pendingPlace = nil
            target = nil
            if !block.isLive { block.goLive() }
            let wanted = block.frame.minY + place.offset - scroll.adjustedContentInset.top
            scroll.contentOffset.y = max(-scroll.adjustedContentInset.top,
                                         min(wanted, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom))
        }
        if pendingPlace == nil, let focus = pendingFocus,
           let block = blocks.first(where: { Self.path(of: $0) == focus.path }) {
            pendingFocus = nil
            if !block.isLive { block.goLive() }
            DispatchQueue.main.async {
                guard block.editors.indices.contains(focus.editor) else { return }
                let editor = block.editors[focus.editor]
                editor.becomeFirstResponder()
                editor.selectedRange = NSRange(location: min(focus.location, max(0, editor.textStorage.length - 1)), length: 0)
            }
        }
    }

    init(kind: SheetKind, store: PrismStore, around target: NoteRef? = nil) {
        self.kind = kind
        self.store = store
        self.target = target
        metrics = PhoneMetrics(face: .current, size: PhoneState.size)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        if StallWatch.enabled { StallWatch.mark("sheet load \(kind)") }
        defer { if StallWatch.enabled { StallWatch.mark("sheet loaded \(kind)") } }
        view.backgroundColor = Ink.page
        scroll.delegate = self
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.contentInsetAdjustmentBehavior = .always
        scroll.showsVerticalScrollIndicator = false
        view.addSubview(scroll)
        scroll.addSubview(content)
        view.addSubview(scrubber)
        scrubber.onScrub = { [weak self] y in self?.scrub(to: y) }
        // No title over the content: the buttons alone, as in Threads.
        navigationItem.title = nil
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.largeTitleDisplayMode = .never
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardMoved(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        // Pulled down: a sync, now.
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            guard let self else { return }
            self.saveAll()
            Task { @MainActor in
                let before = Set(self.store.conflicted)
                await self.store.sync()
                refresh?.endRefreshing()
                if let error = self.store.syncError {
                    self.say(error)
                } else if !Set(self.store.conflicted).subtracting(before).isEmpty {
                    let count = self.store.conflicted.count
                    self.say("\(count) \(count == 1 ? "note was" : "notes were") edited on two devices — see ⋯ to settle.")
                }
            }
        }, for: .valueChanged)
        scroll.refreshControl = refresh
        // The menu at the right of a tab's first sheet; deeper, Back on the
        // left and the note's ⋯. Search is the bottom bar's.
        let menuItems = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in
                guard let self, let menu = self.menu?(self) else { return done([]) }
                done(menu.children)
            },
        ])
        if navigationController?.viewControllers.first === self || navigationController == nil {
            let menu = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal"), menu: menuItems)
            menu.accessibilityLabel = "Menu"
            navigationItem.rightBarButtonItems = [menu]
            menuButton = (menu, "line.3.horizontal")
        } else {
            let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: menuItems)
            more.accessibilityLabel = "More"
            navigationItem.rightBarButtonItems = [more]
            menuButton = (more, "ellipsis")
        }
        showSyncing(syncing)
        if case .search(let query) = kind { setUpSearch(query) }
        // A note opened anew — not put back as the sheet was left — where
        // it was last read to, and typed in, if it was.
        if case .note(let path) = kind, pendingPlace == nil, pendingFocus == nil, let place = PhoneState.place(path) {
            pendingPlace = Place(path: path, index: 0, offset: place.offset)
            if place.editing { pendingFocus = Focus(path: path, editor: 0, location: place.caret) }
        }
        reload()
    }

    // MARK: Syncing

    /// The button the menu hangs on, and its own symbol.
    private var menuButton: (item: UIBarButtonItem, symbol: String)?
    /// Whether a sync is under way.
    var syncing = false

    /// While a sync runs, the menu's button is the sync arrows, turning.
    func showSyncing(_ on: Bool) {
        syncing = on
        guard let (item, symbol) = menuButton else { return }
        item.removeAllSymbolEffects()
        item.image = UIImage(systemName: on ? "arrow.triangle.2.circlepath" : symbol)
        if on { item.addSymbolEffect(.rotate.byLayer, options: .repeat(.continuous)) }
        item.accessibilityValue = on ? "Syncing" : nil
    }

    /// Whether it is going away: the keyboard leaving then is not the
    /// reader putting it away.
    private var disappearing = false

    /// Where each note shown was left: the one at the top, how far into it;
    /// the one typed in, the caret, and that it was.
    private func rememberPlaces() {
        guard pendingPlace == nil, let place, let path = place.path, blocks.indices.contains(place.index),
              blocks[place.index] is NoteBlock else { return }
        PhoneState.setPlace(path, offset: place.offset)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if StallWatch.enabled { StallWatch.mark("viewWillAppear \(kind)") }
        if let changes = unseenChanges, isViewLoaded {
            unseenChanges = nil
            // Its window not yet set: taken in on the next turn.
            DispatchQueue.main.async { self.notesChanged(changes) }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if StallWatch.enabled { StallWatch.mark("viewDidAppear \(kind)") }
        disappearing = false
        if case .search(let query) = kind, query.isEmpty {
            DispatchQueue.main.async { self.navigationItem.searchController?.searchBar.becomeFirstResponder() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if StallWatch.enabled { StallWatch.mark("viewWillDisappear \(kind)") }
        disappearing = true
        rememberPlaces()
        for case let note as NoteBlock in blocks where note.isLive {
            PhoneState.setPlace(note.ref.path, caret: note.editor.selectedRange.location, editing: note.editor.isFirstResponder)
        }
        saveAll()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // A new note left: named after its title, or gone when blank.
        if isMovingFromParent || navigationController?.isBeingDismissed == true, case .note(let path) = kind {
            store.settleNewNote(path)
        }
    }

    /// Something gone wrong, said for a moment over the foot of the page.
    func say(_ message: String) {
        let label = PaddedLabel()
        label.text = message
        label.numberOfLines = 3
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = Ink.paper
        label.backgroundColor = Ink.text.withAlphaComponent(0.9)
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        let size = label.sizeThatFits(CGSize(width: view.bounds.width - 64, height: 200))
        label.frame = CGRect(x: (view.bounds.width - min(size.width, view.bounds.width - 32)) / 2,
                             y: view.bounds.height - view.safeAreaInsets.bottom - size.height - 24,
                             width: min(size.width, view.bounds.width - 32), height: size.height)
        view.addSubview(label)
        UIView.animate(withDuration: 0.3, delay: 3, options: []) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }

    // MARK: The search field

    private var searchTimer: Timer?

    private func setUpSearch(_ query: String) {
        let search = UISearchController(searchResultsController: nil)
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        search.searchBar.text = query
        search.searchBar.placeholder = "Find in notes"
        search.searchBar.autocapitalizationType = .none
        search.searchBar.delegate = self
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .stacked
    }

    // MARK: The keyboard

    /// The keyboard, up or down: the page's foot above it.
    @objc private func keyboardMoved(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, let window = view.window else { return }
        let local = view.convert(window.convert(frame, from: nil), from: nil)
        let covered = max(0, view.bounds.maxY - local.minY - view.safeAreaInsets.bottom)
        scroll.contentInset.bottom = covered
        scroll.verticalScrollIndicatorInsets.bottom = covered
        if let block = blocks.first(where: { $0.editors.contains(where: \.isFirstResponder) }) {
            DispatchQueue.main.async { self.reveal(block) }
        }
    }

    /// The caret in a note brought into sight, a little room around it.
    private func reveal(_ block: SheetBlock) {
        guard let editor = block.editors.first(where: \.isFirstResponder),
              let caret = editor.caretRect, !caret.isNull, !caret.isInfinite else { return }
        let rect = scroll.convert(caret, from: editor).insetBy(dx: 0, dy: -24)
        let visible = scroll.bounds.inset(by: scroll.adjustedContentInset)
        if rect.minY < visible.minY {
            scroll.contentOffset.y -= visible.minY - rect.minY
        } else if rect.maxY > visible.maxY {
            scroll.contentOffset.y += rect.maxY - visible.maxY
        }
    }

    private var titleText: String {
        switch kind {
        case .timeline: "Days"
        case .note(let path): store.index?.entry(path)?.title ?? GraphPaths.day(fromDailyPath: path).map(NoteBlock.dayTitle) ?? path
        case .backlinks(let path): "Linked to " + (store.index?.entry(path)?.title ?? path)
        case .inbox: "Inbox"
        case .tasks: "Tasks"
        case .pinned: "Pinned"
        case .search: "Search"
        }
    }

    // MARK: Contents

    /// The notes shown whole: the timeline's days, a note on its own, the inbox's.
    private var noteBlocks: [NoteBlock] { blocks.compactMap { $0 as? NoteBlock } }

    /// Whether a note has done items to move below the rest.
    func canMoveDoneToBottom(in path: String) -> Bool {
        var rows = noteBlocks.first(where: { $0.ref.path == path })?.liveEditor?.rows ?? OutlineMarkdown.parse(store.text(path)).rows
        return OutlineEditing.moveAllDoneToBottom(&rows)
    }

    /// Every list in a note with its done items below the rest: in its
    /// editor, to be undone there, when it is shown whole; else on disk.
    func moveDoneToBottom(in path: String) {
        if let editor = noteBlocks.first(where: { $0.ref.path == path })?.liveEditor {
            editor.moveAllDoneToBottom()
            return
        }
        saveAll()
        var outline = OutlineMarkdown.parse(store.text(path))
        guard OutlineEditing.moveAllDoneToBottom(&outline.rows) else { return }
        store.write(OutlineMarkdown.serialize(outline), path: path)
    }

    /// A new row at the top of a note shown here, the caret in it — or its
    /// one empty row, when it has nothing in it yet.
    func writeAtTop(of ref: NoteRef) {
        guard let block = noteBlocks.first(where: { $0.ref == ref }) else { return }
        if !block.isLive { block.goLive() }
        let editor = block.editor
        var rows = editor.rows
        // Under its title, when its first row is one.
        let at = rows.first.map { if case .heading(1) = $0.kind { return 1 } else { return 0 } } ?? 0
        editor.becomeFirstResponder()
        if rows.indices.contains(at), rows[at].text.isEmpty {
            // Its first row empty already: that one, not another.
            editor.setCaret(OutlineKeys.Caret(row: at, offset: 0))
        } else {
            rows.insert(.blank, at: min(at, rows.count))
            editor.replace(rows, caret: OutlineKeys.Caret(row: at, offset: 0), undoName: "New Row")
        }
        relayout()
        DispatchQueue.main.async { self.reveal(block) }
    }

    /// A row with words in it, first in a note — its first row, when that
    /// is empty — not typed in: written, and shown.
    func addAtTop(of ref: NoteRef, text: String) {
        guard let block = noteBlocks.first(where: { $0.ref == ref }) else { return }
        if !block.isLive { block.goLive() }
        let editor = block.editor
        var rows = editor.rows
        let at = rows.first.map { if case .heading(1) = $0.kind { return 1 } else { return 0 } } ?? 0
        if rows.indices.contains(at), rows[at].text.isEmpty, rows[at].task == nil {
            rows[at].text = text
        } else {
            var row = Row.blank
            row.text = text
            rows.insert(row, at: min(at, rows.count))
        }
        editor.replace(rows, caret: nil, undoName: "Dictation")
        block.save()
        relayout()
        let row = min(at, rows.count - 1)
        DispatchQueue.main.async {
            self.reveal(block)
            // Once in sight: what came in, marked a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { editor.flashRow(row) }
        }
    }

    func reload() {
        switch kind {
        case .timeline:
            guard let graph = store.graph, let index = store.index else { return }
            entries = Timeline.entries(graph: graph, index: index, including: target, revealed: store.revealedDays)
            let center = target.flatMap(entries.firstIndex(of:)) ?? entries.count - 1
            let low = max(0, min(center - Self.span / 2, entries.count - Self.span))
            shown = low..<min(entries.count, low + Self.span)
            setBlocks(Array(entries[shown]), showsHeaders: true)
        case .note(let path):
            setBlocks([NoteRef(path: path)], showsHeaders: false)
            refreshTopic(path)
        case .inbox:
            refreshInbox()
        case .tasks:
            refreshTasks()
        case .pinned:
            refreshPinned()
        case .backlinks(let path):
            refreshBacklinks(path)
        case .search(let query):
            find(query)
        }
    }

    /// The notes shown, those still shown kept as they are; after them, any
    /// other blocks given.
    private func setBlocks(_ refs: [NoteRef], showsHeaders: Bool, before: [SheetBlock] = [], after: [SheetBlock] = []) {
        var existing: [NoteRef: NoteBlock] = [:]
        for block in noteBlocks { existing[block.ref] = block }
        let notes: [SheetBlock] = refs.map { ref in
            if let gap = ref.gap {
                let block = GapBlock(gap: gap, metrics: metrics)
                block.onReveal = { [weak self] gap in self?.store.reveal(Timeline.reveal(gap)) }
                return block
            }
            if let block = existing.removeValue(forKey: ref) { return block }
            // Among many, a note is built once it comes near; alone, at once.
            let block = NoteBlock(ref: ref, store: store, metrics: metrics, showsHeader: showsHeaders, live: refs.count == 1)
            block.onOpen = { [weak self] in self?.onOpen?(.note(ref.path)) }
            block.onLink = { [weak self] link in self?.onLink?(link) }
            if refs.count > 1 { block.noteMenu = { [weak self] in self.flatMap { $0.noteMenu?($0, ref.path) } } }
            return block
        }
        let kept = Set(notes.map(ObjectIdentifier.init))
        for block in blocks where !kept.contains(ObjectIdentifier(block)) {
            block.save()
            block.removeFromSuperview()
        }
        blocks = before + notes + after
        for block in blocks where block.superview !== content {
            block.onHeightChange = { [weak self] in self?.setNeedsRelayout() }
            block.onCaretMove = { [weak self, weak block] in
                guard let self, let block else { return }
                DispatchQueue.main.async { self.reveal(block) }
                if let note = block as? NoteBlock, note.editor.isFirstResponder {
                    PhoneState.setPlace(note.ref.path, caret: note.editor.selectedRange.location, editing: true)
                }
                self.onStateChange?()
            }
            if let note = block as? NoteBlock {
                // The keyboard put away by the reader: not typed in when next opened.
                note.onEditingEnd = { [weak self, weak note] in
                    guard let self, let note, !self.disappearing else { return }
                    PhoneState.setPlace(note.ref.path, caret: note.editor.selectedRange.location, editing: false)
                }
            }
            if let slices = block as? SliceBlock {
                let path = slices.path
                slices.onOpen = { [weak self] in self?.onOpen?(.note(path)) }
                slices.onLink = { [weak self] link in self?.onLink?(link) }
            }
            content.addSubview(block)
        }
        relayout()
    }

    /// The pieces of notes found, a block a note.
    private func sliceBlocks(_ found: [(path: String, slices: [NoteSlice], editable: Bool)]) -> [SheetBlock] {
        found.map { SliceBlock(path: $0.path, slices: $0.slices, editable: $0.editable, store: store, metrics: metrics) }
    }

    /// Whether something here is typed in: lists are not redone under it.
    private var isTyping: Bool { blocks.contains { $0.editors.contains(where: \.isFirstResponder) } }

    // MARK: The inbox

    private var inboxShown: [String]?

    private func refreshInbox() {
        guard let index = store.index else { return }
        let paths = index.inbox.map(\.path)
        guard paths != inboxShown || blocks.isEmpty else { return }
        inboxShown = paths
        // The notes alone, no heading over them; when there are none, a word saying so.
        let head = paths.isEmpty ? [HeadBlock(title: "Inbox", kicker: "Nothing to deal with", metrics: metrics)] : []
        setBlocks(paths.map(NoteRef.init(path:)), showsHeaders: true, before: head)
        for block in noteBlocks where block.accessory == nil {
            let path = block.ref.path
            block.setAccessory(symbol: "checkmark.circle", label: "Done") { [weak self] in self?.onFlag?(path, "inbox", nil) }
        }
    }

    // MARK: Pinned

    private var pinnedShown: [String]?

    /// The pinned notes, whole, one after another in their pinned order.
    private func refreshPinned() {
        guard let index = store.index else { return }
        let paths = index.pinned.map(\.path)
        guard paths != pinnedShown || blocks.isEmpty else { return }
        pinnedShown = paths
        let head = HeadBlock(title: "Pinned", kicker: paths.isEmpty ? "Pin a note from its ⋯ menu" : "\(paths.count) \(paths.count == 1 ? "note" : "notes")",
                             metrics: metrics)
        setBlocks(paths.map(NoteRef.init(path:)), showsHeaders: true, before: [head])
    }

    // MARK: Tasks

    private var tasksShown: [String]?

    /// The open tasks, in Reflect's groups, each with what is under it.
    private func refreshTasks() {
        guard let graph = store.graph, let index = store.index else { return }
        // Every note's tasks gathered, and cut out with what is under them,
        // off the main thread; only the blocks made on it.
        DispatchQueue.global(qos: .userInitiated).async {
            let tasks = index.tasks()
            let signature = tasks.map { "\($0.notePath)#\($0.ordinal)#\($0.text)" }
            var slices: [String: NoteSlice] = [:]
            var editable: Set<String> = []
            for (path, list) in Dictionary(grouping: tasks, by: \.notePath) {
                guard let source = graph.read(path: path) else { continue }
                if OutlineMarkdown.roundTrips(source) { editable.insert(path) }
                for var slice in NoteSlice.slices(of: list, in: source) {
                    slice.crumbs = Tasks.visibleBreadcrumbs(slice.task?.breadcrumbs ?? [])
                    slices["\(path)#\(slice.task?.ordinal ?? -1)"] = slice
                }
            }
            var groups: [(label: String, runs: [(path: String, slices: [NoteSlice], editable: Bool)])] = []
            for group in Tasks.group(tasks, today: .today) {
                // A note's tasks together, as long as they come one after another.
                var runs: [(path: String, slices: [NoteSlice], editable: Bool)] = []
                for task in group.tasks {
                    guard let slice = slices["\(task.notePath)#\(task.ordinal)"] else { continue }
                    if runs.last?.path == task.notePath { runs[runs.count - 1].slices.append(slice) } else {
                        runs.append((task.notePath, [slice], editable.contains(task.notePath)))
                    }
                }
                groups.append((group.label, runs))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.kind == .tasks, !self.isTyping, signature != self.tasksShown || self.blocks.isEmpty else { return }
                self.tasksShown = signature
                var after: [SheetBlock] = []
                for group in groups {
                    after.append(HeadBlock(title: group.label, kicker: nil, metrics: self.metrics, isGroup: true))
                    after += self.sliceBlocks(group.runs)
                }
                let head = HeadBlock(title: "Tasks", kicker: tasks.isEmpty ? "Nothing to do" : "\(tasks.count) to do", metrics: self.metrics)
                self.setBlocks([], showsHeaders: true, before: [head], after: after)
            }
        }
    }

    // MARK: What links to a note

    private var backlinksShown: [BacklinkSource]?

    /// What links to a note, looked for off the main thread.
    private func linked(to path: String, then show: @escaping ([BacklinkSource], [(path: String, slices: [NoteSlice], editable: Bool)]) -> Void) {
        guard let index = store.index, let graph = store.graph else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let sources = index.backlinks(to: path)
            let found = sources.compactMap { source -> (path: String, slices: [NoteSlice], editable: Bool)? in
                guard let text = graph.read(path: source.path) else { return nil }
                let slices = NoteSlice.slices(holding: source.contexts.map(\.link), path: source.path, in: text)
                return slices.isEmpty ? nil : (source.path, slices, OutlineMarkdown.roundTrips(text))
            }
            DispatchQueue.main.async { show(sources, found) }
        }
    }

    private func refreshBacklinks(_ path: String) {
        linked(to: path) { [weak self] sources, found in
            guard let self, self.kind == .backlinks(path), !self.isTyping, sources != self.backlinksShown || self.blocks.isEmpty else { return }
            self.backlinksShown = sources
            let head = HeadBlock(title: SliceBlock.name(path, store: self.store),
                                 kicker: found.isEmpty ? "Nothing links here" : "Linked from \(found.count) \(found.count == 1 ? "note" : "notes")",
                                 metrics: self.metrics)
            self.setBlocks([], showsHeaders: true, before: [head], after: self.sliceBlocks(found))
        }
    }

    /// A topic — a note that says it is one, or says nothing but its name —
    /// shown with what links to it, under it.
    private func refreshTopic(_ path: String) {
        guard GraphPaths.day(fromDailyPath: path) == nil, let note = noteBlocks.first else { return }
        let isTopic = store.index?.entry(path)?.isTopic == true
            || note.savedText.utf16.count < 2_000 && Backlinks.isEmpty(note.editor.rows)
        guard isTopic else {
            if blocks.count > 1 { setBlocks([note.ref], showsHeaders: false) }
            return
        }
        linked(to: path) { [weak self] sources, found in
            guard let self, self.kind == .note(path), !self.isTyping, sources != self.backlinksShown || self.blocks.count == 1 else { return }
            self.backlinksShown = sources
            let head = HeadBlock(title: "Linked here", kicker: found.isEmpty ? "Nothing yet" : "\(found.count) \(found.count == 1 ? "note" : "notes")",
                                 metrics: self.metrics, isGroup: true)
            self.setBlocks([NoteRef(path: path)], showsHeaders: false, after: [head] + self.sliceBlocks(found))
        }
    }

    // MARK: Search

    private var searching = 0

    /// The notes with all of a query's words, the rows they are in shown.
    func find(_ query: String) {
        kind = .search(query)
        let words = NoteSearch.words(query)
        searching += 1
        let generation = searching
        guard !words.isEmpty, let index = store.index else {
            return setBlocks([], showsHeaders: true)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = NoteSearch.find(words, in: index)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.searching else { return }
                let head = HeadBlock(title: query, kicker: found.isEmpty ? "Nothing found" : "\(found.count == 60 ? "60+" : String(found.count)) notes",
                                     metrics: self.metrics, isGroup: true)
                self.setBlocks([], showsHeaders: true, before: [head], after: self.sliceBlocks(found.map { ($0.path, $0.slices, $0.editable) }))
            }
        }
    }

    /// Takes in what changed on disk.
    /// Changes to take in once it is seen: a sheet out of sight does no work.
    private var unseenChanges: Set<String>?

    func notesChanged(_ paths: Set<String>) {
        guard isViewLoaded, view.window != nil else {
            unseenChanges = paths.isEmpty || unseenChanges?.isEmpty == true ? [] : (unseenChanges ?? []).union(paths)
            return
        }
        for block in blocks { block.notesChanged(paths) }
        switch kind {
        case .timeline:
            guard let graph = store.graph, let index = store.index else { return }
            // Notes already in it changed: nothing new to place.
            if !paths.isEmpty, paths.allSatisfy({ entries.contains(NoteRef(path: $0)) && graph.exists(path: $0) }) { return relayout() }
            // A new day or week, in its place; the window kept on the same days.
            let new = Timeline.entries(graph: graph, index: index, revealed: store.revealedDays)
            guard new != entries, !shown.isEmpty else { return relayout() }
            let first = entries[shown.lowerBound], last = entries[shown.upperBound - 1]
            entries = new
            let low = entries.firstIndex(of: first) ?? 0
            let high = (entries.firstIndex(of: last) ?? entries.count - 1) + 1
            shown = low..<max(low, high)
            setBlocks(Array(entries[shown]), showsHeaders: true)
        case .inbox:
            refreshInbox()
        case .pinned:
            refreshPinned()
        case .tasks:
            if !isTyping { refreshTasks() }
        case .backlinks(let path):
            refreshBacklinks(path)
            relayout()
        case .note(let path):
            refreshTopic(path)
            relayout()
        case .search:
            relayout()
        }
    }

    func saveAll() { blocks.forEach { $0.save() } }

    // MARK: Layout

    private var relayoutPending = false

    private func setNeedsRelayout() {
        guard !relayoutPending else { return }
        relayoutPending = true
        DispatchQueue.main.async { [weak self] in
            self?.relayoutPending = false
            self?.relayout()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if StallWatch.enabled { StallWatch.mark("sheet layout \(kind)") }
        defer { if StallWatch.enabled { StallWatch.mark("sheet laid out \(kind)") } }
        scroll.frame = view.bounds
        let safe = view.safeAreaInsets
        // Clear of the tab bar's place at the foot.
        let foot: CGFloat = 24
        scrubber.frame = CGRect(x: view.bounds.width - 28, y: safe.top + 12, width: 28, height: view.bounds.height - safe.top - safe.bottom - 24 - foot)
        relayout()
    }

    /// Lays the notes out one under another, the one at the top of the
    /// screen kept where it is, however those above it grew or shrank.
    private var separators: [UIView] = []
    static let rulesBetween = false

    func relayout() {
        let width = view.bounds.width
        guard width > 0 else { return }
        let top = scroll.contentOffset.y + scroll.adjustedContentInset.top
        let anchor = blocks.last { $0.frame.minY <= top && $0.frame.height > 0 }.map { ($0, top - $0.frame.minY) }
        var y: CGFloat = 0
        // A hairline across between the notes of a list, as between posts.
        var rules = 0
        for (i, block) in blocks.enumerated() {
            let height = block.height(width: width)
            block.frame = CGRect(x: 0, y: y, width: width, height: height)
            y += height
            // No rule between cards: the space above each header parts them.
            let next = blocks.indices.contains(i + 1) ? blocks[i + 1] : nil
            if Self.rulesBetween, let next, !(block is HeadBlock), !(next is HeadBlock), height > 0 {
                if separators.count == rules {
                    let rule = UIView()
                    rule.backgroundColor = Ink.rule
                    content.addSubview(rule)
                    separators.append(rule)
                }
                separators[rules].frame = CGRect(x: 0, y: y - 0.5, width: width, height: 1 / max(view.traitCollection.displayScale, 1))
                separators[rules].isHidden = false
                rules += 1
            }
        }
        for rule in separators.dropFirst(rules) { rule.isHidden = true }
        if case .timeline = kind, shown.upperBound == entries.count { y += max(0, view.bounds.height - 320) }
        content.frame = CGRect(x: 0, y: 0, width: width, height: y)
        scroll.contentSize = content.frame.size
        let placing = pendingPlace != nil
        if placing || pendingFocus != nil { applyPending() }
        // Just put where it was left: no other place to keep.
        if placing && pendingPlace == nil {
            setNeedsMarks()
            wakeNearby()
            return
        }
        if let target, let block = noteBlocks.first(where: { $0.ref == target }) {
            self.target = nil
            scroll.contentOffset.y = max(-scroll.adjustedContentInset.top, min(block.frame.minY - scroll.adjustedContentInset.top,
                                                                              scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom))
        } else if let (block, offset) = anchor, blocks.contains(where: { $0 === block }) {
            let wanted = block.frame.minY + offset - scroll.adjustedContentInset.top
            if abs(wanted - scroll.contentOffset.y) > 0.5, !scroll.isDragging, !scroll.isDecelerating {
                scroll.contentOffset.y = wanted
            }
        }
        setNeedsMarks()
        wakeNearby()
    }

    // MARK: The scrubber's marks, when things settle

    private var marksPending = false

    /// The scrubber's marks found again — every heading of every note shown —
    /// once what changed has settled, and not while scrolling: not for each
    /// keystroke or frame.
    private func setNeedsMarks() {
        guard !marksPending else { return }
        marksPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.marksPending = false
            if self.scroll.isDragging || self.scroll.isDecelerating { return self.setNeedsMarks() }
            self.refreshMarks()
        }
    }

    // MARK: Building notes as they come near

    private var waking = false
    private var lastWake: CGFloat = -.greatestFiniteMagnitude
    private var lastWakeHeight: CGFloat = 0

    /// The notes on screen built now; those within a screen and a half,
    /// one a turn of the run loop — nearest first — so no frame waits on
    /// more than one.
    private func wakeNearby() {
        guard scroll.bounds.height > 0 else { return }
        let seen = scroll.bounds
        let near = seen.insetBy(dx: 0, dy: -seen.height * 2.5)
        let middle = seen.midY
        // In sight and not built: built now — it is wanted this frame.
        // One being built ahead is left to come in — a moment, off this
        // thread — not built twice.
        let visible = blocks.filter { !$0.isLive && $0.frame.intersects(seen) && ($0 as? NoteBlock)?.preparing != true }
        if !visible.isEmpty {
            visible.forEach { $0.goLive() }
            setNeedsRelayout()
        }
        // Gone out of sight: hidden, the tiles its text drew let go. Far
        // away: its editor let go too, the text kept to put back when it
        // comes near — the memory a long scroll takes bounded.
        let drawn = seen
        let far = seen.insetBy(dx: 0, dy: -seen.height * 4)
        for case let note as NoteBlock in blocks {
            if note.isLive, !note.frame.intersects(far) { note.sleep() }
            let hidden = note.isLive && !note.frame.intersects(drawn) && !note.editor.isFirstResponder
            if note.isHidden != hidden { note.isHidden = hidden }
        }
        // Coming near: built ahead, off the main thread, nearest first —
        // looked for again once the page has moved some.
        guard abs(seen.minY - lastWake) > 60 || !visible.isEmpty || lastWakeHeight != scroll.contentSize.height else { return }
        lastWake = seen.minY
        lastWakeHeight = scroll.contentSize.height
        let width = view.bounds.width
        for block in blocks.filter({ !$0.isLive && $0.frame.intersects(near) })
            .sorted(by: { abs($0.frame.midY - middle) < abs($1.frame.midY - middle) }) {
            block.prepareLive(width: width)
        }
    }

    // MARK: The scrubber

    private func refreshMarks() {
        var marks: [ScrubberView.Mark] = []
        let height = max(scroll.contentSize.height, 1)
        let listed: Bool = { if case .note = kind { return false } else { return true } }()
        for block in blocks {
            // Each note of many, by its name.
            if listed, let note = block as? NoteBlock {
                let isWeek = GraphPaths.week(fromWeeklyPath: note.ref.path) != nil
                let name = note.ref.day.map(NoteBlock.dayTitle) ?? (isWeek ? "Week" : SliceBlock.name(note.ref.path, store: store))
                marks.append(.init(fraction: block.frame.minY / height, title: name, rank: 2, isWeek: isWeek))
            } else if let slices = block as? SliceBlock {
                marks.append(.init(fraction: block.frame.minY / height, title: SliceBlock.name(slices.path, store: store), rank: 2, isWeek: false))
            }
            for editor in block.editors {
                for heading in editor.headings {
                    let glyph = editor.outlineLayout.glyphIndexForCharacter(at: heading.location)
                    let y = block.frame.minY + editor.frame.minY + editor.outlineLayout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                    marks.append(.init(fraction: y / height, title: InlineMarkup.plainText(heading.text), rank: 1, isWeek: false))
                }
            }
        }
        scrubber.marks = marks
        scrubber.isHidden = marks.count < 3
    }

    /// The thumb on the scrubber: the page taken to that place in it.
    private func scrub(to fraction: CGFloat) {
        let height = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        scroll.contentOffset.y = max(-scroll.adjustedContentInset.top, fraction * max(height, 0))
    }

    // MARK: Scrolling to the window's ends

    /// To the top of the sheet, as a tap on the status bar goes.
    func scrollToTop() {
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top), animated: true)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        rememberPlaces()
        onStateChange?()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            rememberPlaces()
            onStateChange?()
        }
    }

    /// Told to hide the chrome — reading down — or bring it back.
    var onChromeHidden: ((Bool) -> Void)?
    private var lastScrollY: CGFloat = 0
    private var chromeTravel: CGFloat = 0

    /// Scrolled down by the reader, some way: the chrome goes; up a little,
    /// or near the top, it comes back.
    private func followForChrome() {
        let y = scroll.contentOffset.y
        defer { lastScrollY = y }
        guard scroll.isTracking || scroll.isDecelerating else { return }
        let delta = y - lastScrollY
        if y < 40 - scroll.adjustedContentInset.top {
            chromeTravel = 0
            return onChromeHidden?(false) ?? ()
        }
        // The same way a while, before it counts.
        chromeTravel = (delta > 0) == (chromeTravel > 0) ? chromeTravel + delta : delta
        if chromeTravel > 24 { onChromeHidden?(true) } else if chromeTravel < -12 { onChromeHidden?(false) }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        followForChrome()
        scrubber.visible = scroll.contentOffset.y / max(scroll.contentSize.height, 1)
        wakeNearby()
        guard case .timeline = kind, !shown.isEmpty, !relayoutPending else { return }
        let offset = scroll.contentOffset.y
        if offset < scroll.bounds.height, shown.lowerBound > 0 {
            slide(earlier: true)
        } else if offset > scroll.contentSize.height - 2 * scroll.bounds.height, shown.upperBound < entries.count {
            slide(earlier: false)
        }
    }

    private func slide(earlier: Bool) {
        var low = shown.lowerBound, high = shown.upperBound
        if earlier {
            low = max(0, low - Self.step)
            high = min(high, low + Self.span + Self.step)
        } else {
            high = min(entries.count, high + Self.step)
            low = max(low, high - Self.span - Self.step)
        }
        guard low..<high != shown else { return }
        shown = low..<high
        setBlocks(Array(entries[shown]), showsHeaders: true)
    }

    /// Brings a day of the timeline to the top, the window moved to it.
    func show(_ ref: NoteRef, asLeft: Bool = false) {
        guard case .timeline = kind else { return }
        // A day with no note yet: in the timeline, empty, to write in.
        if let day = ref.day, store.graph?.exists(path: ref.path) == false { store.reveal([day]) }
        // Gone to: where it was last read to, and typed in, if it was.
        if asLeft, let place = PhoneState.place(ref.path) {
            if !entries.contains(ref) || !entries[shown].contains(ref) {
                target = ref
                reload()
            }
            restore(place: Place(path: ref.path, index: 0, offset: place.offset),
                    focus: place.editing ? Focus(path: ref.path, editor: 0, location: place.caret) : nil)
            return
        }
        if !entries.contains(ref) || !entries[shown].contains(ref) {
            target = ref
            reload()
        } else {
            target = ref
            relayout()
        }
    }
}

/// The scrubber: ticks down the right edge — a long one for each day, a
/// short one for each heading — dragged along with the thumb, a tick of the
/// phone at each day passed, the day said beside the thumb.
final class ScrubberView: UIView {
    struct Mark: Equatable {
        var fraction: CGFloat
        var title: String
        var rank: Int
        var isWeek: Bool
    }

    var marks: [Mark] = [] { didSet { if marks != oldValue { setNeedsDisplay() } } }
    /// Whether its marks show: only while a thumb is on it, and a moment
    /// after. Else it is a faint line at the edge.
    private var revealed = false {
        didSet {
            guard revealed != oldValue else { return }
            UIView.transition(with: self, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.setNeedsDisplay()
                self.layer.displayIfNeeded()
            }
        }
    }
    private var hideTimer: Timer?
    /// Where the screen's top is, from 0 to 1.
    var visible: CGFloat = 0
    /// Dragged: where along it the thumb is, from 0 to 1.
    var onScrub: ((CGFloat) -> Void)?
    private let label = PaddedLabel()
    private let haptics = UISelectionFeedbackGenerator()
    private var lastMark: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        label.isHidden = true
        label.backgroundColor = Ink.shelf
        label.textColor = Ink.text
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.layer.cornerRadius = 9
        label.lineBreakMode = .byTruncatingTail
        label.numberOfLines = 1
        label.layer.masksToBounds = true
        addSubview(label)
        clipsToBounds = false
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(dragged(_:))).with { $0.minimumPressDuration = 0 })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        // At rest: nothing — it shows when a thumb is on it.
        guard revealed else { return }
        for mark in marks {
            let y = 6 + mark.fraction * (bounds.height - 12)
            let length: CGFloat = mark.rank == 2 ? 12 : 6
            (mark.isWeek ? Ink.week : mark.rank == 2 ? Ink.secondary : Ink.faint).setFill()
            UIBezierPath(roundedRect: CGRect(x: bounds.width - 6 - length, y: y - 0.75, width: length, height: 1.5), cornerRadius: 0.75).fill()
        }
    }

    @objc private func dragged(_ gesture: UILongPressGestureRecognizer) {
        let y = gesture.location(in: self).y
        let fraction = min(1, max(0, (y - 6) / max(bounds.height - 12, 1)))
        switch gesture.state {
        case .began, .changed:
            hideTimer?.invalidate()
            revealed = true
            onScrub?(fraction)
            // The day the thumb is at, said beside it, and felt as it passes.
            let nearest = marks.indices.filter { marks[$0].rank == 2 }.min { abs(marks[$0].fraction - fraction) < abs(marks[$1].fraction - fraction) }
            if let nearest {
                if nearest != lastMark { haptics.selectionChanged() }
                lastMark = nearest
                label.text = marks[nearest].title
                label.sizeToFit()
                // No wider than the screen leaves it, left of the scrubber:
                // a long title cut short, not run off the edge.
                let room = max(80, frame.minX - 16 - 12)
                let width = min(label.bounds.width, room)
                label.frame = CGRect(x: -width - 12, y: y - label.bounds.height / 2, width: width, height: label.bounds.height)
                label.isHidden = false
            }
        default:
            label.isHidden = true
            lastMark = nil
            // Its marks a moment longer, then the faint line again.
            hideTimer?.invalidate()
            hideTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.revealed = false }
            }
        }
    }
}

/// A label with room round its words.
final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 10, dy: 5)) }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fit = super.sizeThatFits(size)
        return CGSize(width: fit.width + 20, height: fit.height + 10)
    }
}

extension UIGestureRecognizer {
    func with(_ change: (Self) -> Void) -> Self {
        change(self)
        return self
    }
}

extension PhoneState {
    /// The text size set, in points.
    static var size: CGFloat {
        get { UserDefaults.standard.object(forKey: "TextSize") as? CGFloat ?? 16 }
        set { UserDefaults.standard.set(newValue, forKey: "TextSize") }
    }
}

extension SheetController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange text: String) {
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.find(text)
            }
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchTimer?.invalidate()
        find(searchBar.text ?? "")
        searchBar.resignFirstResponder()
    }
}
