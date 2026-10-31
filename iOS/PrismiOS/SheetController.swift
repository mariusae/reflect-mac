import UIKit
import ReflectCore
import PrismCore

/// What a sheet shows: a note — what links to it at its end — or the
/// tasks, or what a search found.
enum SheetKind: Hashable, Codable {
    case note(String)
    case tasks
    case search(String)
}

/// A page of blocks one under another, each editable where it is: a note
/// whole, and under it the rows that link to it; or the pieces of notes a
/// lens gathers — the tasks, what was found — each written back into its
/// own note.
final class SheetController: UIViewController, UIScrollViewDelegate {
    let store: PrismStore
    private(set) var kind: SheetKind
    let scroll = UIScrollView()
    private let content = UIView()
    private(set) var blocks: [SheetBlock] = []
    private var metrics: PhoneMetrics
    /// Asked to open a note — at a row, by its place among all the note's
    /// rows, to show and mark a moment.
    var onOpen: ((String, Int?) -> Void)?
    /// Told when a link is tapped: the link, and the note it is in.
    var onLink: ((String, String) -> Void)?
    /// Asked to set a note's frontmatter key — `inbox` — or take it away.
    var onFlag: ((String, String, String?) -> Void)?
    /// How many notes link to the note shown, once found: its bar's count.
    var onLinkedCount: ((Int) -> Void)?
    private(set) var linkedCount: Int?
    /// The notes linking here, as last found: the newest first.
    private(set) var linkedPaths: [String] = []

    // MARK: Where it was left

    /// Where a sheet is scrolled to: the block at the top of the screen —
    /// by its note's path, or its place among the blocks — and how far
    /// into it.
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

    var place: Place? {
        guard !blocks.isEmpty else { return nil }
        let top = scroll.contentOffset.y + scroll.adjustedContentInset.top
        guard let index = blocks.lastIndex(where: { $0.frame.minY <= top + 0.5 }) else { return nil }
        return Place(path: Self.path(of: blocks[index]), index: index, offset: top - blocks[index].frame.minY)
    }

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

    private var pendingPlace: Place?
    private var pendingFocus: Focus?

    func restore(place: Place?, focus: Focus?) {
        pendingPlace = place
        pendingFocus = focus
        if isViewLoaded { relayout() }
    }

    private func block(for place: Place) -> SheetBlock? {
        if let path = place.path { return blocks.first { Self.path(of: $0) == path } }
        return blocks.indices.contains(place.index) ? blocks[place.index] : nil
    }

    private func applyPending() {
        if let place = pendingPlace, let block = block(for: place) {
            pendingPlace = nil
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

    init(kind: SheetKind, store: PrismStore) {
        self.kind = kind
        self.store = store
        metrics = PhoneMetrics(face: .current, size: PhoneState.size)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Ink.page
        scroll.delegate = self
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.contentInsetAdjustmentBehavior = .always
        scroll.topEdgeEffect.isHidden = true
        view.addSubview(scroll)
        scroll.addSubview(content)
        // The page under a note tapped — past its end — a row there to write in.
        let after = UITapGestureRecognizer(target: self, action: #selector(tappedPage(_:)))
        after.cancelsTouchesInView = false
        content.addGestureRecognizer(after)
        scroll.addGestureRecognizer({
            let tap = UITapGestureRecognizer(target: self, action: #selector(tappedPage(_:)))
            tap.cancelsTouchesInView = false
            return tap
        }())
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
        scroll.refreshControl = pullsToSync ? refresh : nil
        // A note opened anew where it was last read to, and typed in, if it was.
        if restoresPlace, case .note(let path) = kind, pendingPlace == nil, pendingFocus == nil, let place = PhoneState.place(path) {
            pendingPlace = Place(path: path, index: 0, offset: place.offset)
            if place.editing { pendingFocus = Focus(path: path, editor: 0, location: place.caret) }
        }
        reload()
    }

    /// Pulled down at its top: a sync — not on a day's page, where it is the week.
    var pullsToSync = true
    /// Opened where it was last read to — not a day's page, which opens at its top.
    var restoresPlace = true

    /// Whether it is going away: the keyboard leaving then is not the
    /// reader putting it away.
    private var disappearing = false

    private func rememberPlaces() {
        guard pendingPlace == nil, let place, let path = place.path, blocks.indices.contains(place.index),
              blocks[place.index] is NoteBlock else { return }
        PhoneState.setPlace(path, offset: place.offset)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let changes = unseenChanges, isViewLoaded {
            unseenChanges = nil
            DispatchQueue.main.async { self.notesChanged(changes) }
        }
    }

    // MARK: A row marked

    private var pendingMark: Int?

    func mark(unfoldedRow row: Int) {
        pendingMark = row
        if view.window != nil { DispatchQueue.main.async { self.markPending() } }
    }

    private func markPending() {
        guard let row = pendingMark, case .note(let path) = kind,
              let block = noteBlocks.first(where: { $0.ref.path == path }) else { return }
        pendingMark = nil
        relayout()
        let editor = block.editor
        guard let index = editor.row(unfolded: row) else { return }
        let rect = scroll.convert(editor.rowRect(index), from: editor)
        let visible = scroll.bounds.inset(by: scroll.adjustedContentInset)
        let top = -scroll.adjustedContentInset.top
        let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let y = min(max(rect.minY - visible.height / 3 - scroll.adjustedContentInset.top, top), bottom)
        UIView.animate(withDuration: 0.3) { self.scroll.contentOffset.y = y } completion: { _ in editor.flashRow(index) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if pendingMark != nil { markPending() }
        disappearing = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        disappearing = true
        rememberPlaces()
        for case let note as NoteBlock in blocks where note.isLive {
            PhoneState.setPlace(note.ref.path, caret: note.editor.selectedRange.location, editing: note.editor.isFirstResponder)
        }
        saveAll()
    }

    /// A note let go: a new one named after its title, or gone when blank.
    /// Says where it went, when it went: nil, gone.
    @discardableResult
    func settle() -> (from: String, to: String?)? {
        guard case .note(let path) = kind else { return nil }
        let now = store.settleNewNote(path)
        return now == path ? nil : (path, now)
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

    // MARK: The keyboard

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

    // MARK: Contents

    private var noteBlocks: [NoteBlock] { blocks.compactMap { $0 as? NoteBlock } }

    /// The note shown — the sheet's own — when it is one.
    var notePath: String? { if case .note(let path) = kind { path } else { nil } }

    /// A note deleted: the cards showing it never write it again.
    func discard(_ path: String) {
        noteBlocks.filter { $0.ref.path == path }.forEach { $0.discard() }
    }

    func canMoveDoneToBottom(in path: String) -> Bool {
        var rows = noteBlocks.first(where: { $0.ref.path == path })?.liveEditor?.rows ?? OutlineMarkdown.parse(store.text(path)).rows
        return OutlineEditing.moveAllDoneToBottom(&rows)
    }

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

    /// A new row at the top of the note, the caret in it — or its one
    /// empty row, when it has nothing in it yet.
    func writeAtTop() {
        guard let block = noteBlocks.first else { return }
        if !block.isLive { block.goLive() }
        let editor = block.editor
        var rows = editor.rows
        let at = rows.first.map { if case .heading(1) = $0.kind { return 1 } else { return 0 } } ?? 0
        editor.becomeFirstResponder()
        if rows.indices.contains(at), rows[at].text.isEmpty {
            editor.setCaret(OutlineKeys.Caret(row: at, offset: 0))
        } else {
            rows.insert(.blank, at: min(at, rows.count))
            editor.replace(rows, caret: OutlineKeys.Caret(row: at, offset: 0), undoName: "New Row")
        }
        relayout()
        DispatchQueue.main.async { self.reveal(block) }
    }

    /// The page tapped under the note's end — not on what follows it, what
    /// links here: the caret at its end, in a new row — its last row, if
    /// that is empty already.
    @objc private func tappedPage(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, let block = noteBlocks.first,
              tap.view === content || tap.view === scroll else { return }
        let point = tap.location(in: content)
        // On something of the page's own: its own to answer.
        if let hit = content.hitTest(point, with: nil), hit !== content { return }
        let below = blocks.first { $0 !== block && $0.frame.minY > block.frame.minY }
        guard point.y > block.frame.maxY - 12, below.map({ point.y < $0.frame.minY }) ?? true else { return }
        writeAtEnd()
    }

    /// A new row at the end of the note, the caret in it — or its last row,
    /// when that is empty already.
    func writeAtEnd() {
        guard let block = noteBlocks.first else { return }
        if !block.isLive { block.goLive() }
        let editor = block.editor
        var rows = editor.rows
        editor.becomeFirstResponder()
        if let last = rows.last, last.text.trimmingCharacters(in: .whitespaces).isEmpty, last.task == nil, last.kind.isListItem {
            editor.setCaret(OutlineKeys.Caret(row: rows.count - 1, offset: 0))
        } else {
            rows.append(.blank)
            editor.replace(rows, caret: OutlineKeys.Caret(row: rows.count - 1, offset: 0), undoName: "New Row")
        }
        relayout()
        DispatchQueue.main.async { self.reveal(block) }
    }

    /// A row with words in it, first in the note — its first row, when
    /// that is empty — not typed in: written, and shown.
    func addAtTop(text: String) {
        guard let block = noteBlocks.first else { return }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { editor.flashRow(row) }
        }
    }

    /// The first editor, the caret in it: a new note's title, to type.
    func focusFirst() {
        guard let block = noteBlocks.first else { return }
        if !block.isLive { block.goLive() }
        block.editor.becomeFirstResponder()
    }

    func reload() {
        switch kind {
        case .note(let path):
            setBlocks(note: path)
            refreshLinked(path)
        case .tasks:
            refreshTasks()
        case .search(let query):
            find(query)
        }
    }

    /// The note shown, kept as it is when it is already; after it, any
    /// other blocks given.
    private func setBlocks(note path: String?, before: [SheetBlock] = [], after: [SheetBlock] = []) {
        var notes: [SheetBlock] = []
        if let path {
            if let block = noteBlocks.first(where: { $0.ref.path == path }) {
                notes = [block]
            } else {
                let ref = NoteRef(path: path)
                let block = NoteBlock(ref: ref, store: store, metrics: metrics, showsHeader: false, live: true)
                block.onLink = { [weak self] link, from in self?.onLink?(link, from) }
                notes = [block]
            }
        }
        let kept = Set((notes + before + after).map(ObjectIdentifier.init))
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
            }
            if let note = block as? NoteBlock {
                note.onEditingEnd = { [weak self, weak note] in
                    guard let self, let note, !self.disappearing else { return }
                    PhoneState.setPlace(note.ref.path, caret: note.editor.selectedRange.location, editing: false)
                }
            }
            if let slices = block as? SliceBlock {
                let path = slices.path
                // Opened where it was found: at the link, the task, the words searched for.
                let start = slices.slices.first?.start
                slices.onOpen = { [weak self] in self?.onOpen?(path, start) }
                slices.onLink = { [weak self] link, from in self?.onLink?(link, from) }
            }
            content.addSubview(block)
        }
        updateInbox()
        relayout()
    }

    private func sliceBlocks(_ found: [(path: String, slices: [NoteSlice], editable: Bool)]) -> [SheetBlock] {
        found.map { SliceBlock(path: $0.path, slices: $0.slices, editable: $0.editable, store: store, metrics: metrics) }
    }

    private var isTyping: Bool { blocks.contains { $0.editors.contains(where: \.isFirstResponder) } }

    // MARK: The inbox

    /// The note shown, when it is in the inbox: its Done before its name.
    private func updateInbox() {
        guard let index = store.index else { return }
        for block in noteBlocks {
            let path = block.ref.path
            block.setInbox(index.entry(path)?.isInInbox == true, marked: true) { [weak self, weak block] in
                guard let self, let block else { return }
                block.save()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                block.checkAccessory()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.onFlag?(path, "inbox", nil) }
            }
        }
    }

    // MARK: Tasks

    private var tasksShown: [String]?

    /// The open tasks, in Reflect's groups, each with what is under it.
    private func refreshTasks() {
        guard let graph = store.graph, let index = store.index else { return }
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
                if tasks.isEmpty { after.append(HeadBlock(title: "Nothing to do", kicker: nil, metrics: self.metrics, isGroup: true)) }
                for group in groups {
                    after.append(HeadBlock(title: group.label, kicker: nil, metrics: self.metrics, isGroup: true))
                    after += self.sliceBlocks(group.runs)
                }
                self.setBlocks(note: nil, after: after)
            }
        }
    }

    // MARK: What links to the note

    private var linkedShown: [BacklinkSource]?

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

    /// Every note followed by what links to it — the one place links are
    /// shown from their other end.
    private func refreshLinked(_ path: String) {
        linked(to: path) { [weak self] sources, found in
            guard let self, self.kind == .note(path), !self.isTyping else { return }
            self.linkedPaths = found.map(\.path).sorted {
                (self.store.index?.entry($0)?.modified ?? .distantPast) > (self.store.index?.entry($1)?.modified ?? .distantPast)
            }
            if self.linkedCount != found.count {
                self.linkedCount = found.count
                self.onLinkedCount?(found.count)
            }
            guard sources != self.linkedShown || self.blocks.count == 1 else { return }
            self.linkedShown = sources
            let after: [SheetBlock] = found.isEmpty ? [] : [LinkedHead(count: found.count, metrics: self.metrics)] + self.sliceBlocks(found)
            self.setBlocks(note: path, after: after)
        }
    }

    /// To what links here, at the note's end.
    func scrollToLinked() {
        guard let head = blocks.first(where: { $0 is LinkedHead }) else { return }
        relayout()
        let top = -scroll.adjustedContentInset.top
        let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        scroll.setContentOffset(CGPoint(x: 0, y: min(max(head.frame.minY - scroll.adjustedContentInset.top, top), bottom)), animated: true)
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
            return setBlocks(note: nil)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = NoteSearch.find(words, in: index)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.searching else { return }
                let head = HeadBlock(title: found.isEmpty ? "Nothing found" : "\(found.count == 60 ? "60+" : String(found.count)) notes",
                                     kicker: nil, metrics: self.metrics, isGroup: true)
                self.setBlocks(note: nil, before: [head], after: self.sliceBlocks(found.map { ($0.path, $0.slices, $0.editable) }))
            }
        }
    }

    // MARK: Keeping up

    private var unseenChanges: Set<String>?

    func notesChanged(_ paths: Set<String>) {
        guard isViewLoaded, view.window != nil else {
            unseenChanges = paths.isEmpty || unseenChanges?.isEmpty == true ? [] : (unseenChanges ?? []).union(paths)
            return
        }
        for block in blocks { block.notesChanged(paths) }
        defer { updateInbox() }
        switch kind {
        case .tasks:
            if !isTyping { refreshTasks() }
        case .note(let path):
            refreshLinked(path)
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
        scroll.frame = view.bounds
        relayout()
    }

    /// Lays the blocks out one under another, the one at the top of the
    /// screen kept where it is, however those above it grew or shrank.
    func relayout() {
        let width = view.bounds.width
        guard width > 0 else { return }
        let top = scroll.contentOffset.y + scroll.adjustedContentInset.top
        let anchor = blocks.last { $0.frame.minY <= top && $0.frame.height > 0 }.map { ($0, top - $0.frame.minY) }
        // Wide — an iPad — a measure to read in, in the middle; a phone's whole width, else.
        let measure = width > 480 ? min(width - 64, 760) : width
        let x = ((width - measure) / 2).rounded()
        var y: CGFloat = 0
        for block in blocks {
            let height = block.height(width: measure)
            block.frame = CGRect(x: x, y: y, width: measure, height: height)
            y += height
        }
        // Room under the last, to read it clear of the bar.
        y += 40
        content.frame = CGRect(x: 0, y: 0, width: width, height: y)
        scroll.contentSize = content.frame.size
        if pendingPlace != nil || pendingFocus != nil {
            applyPending()
            return
        }
        if let (block, offset) = anchor, blocks.contains(where: { $0 === block }) {
            let wanted = block.frame.minY + offset - scroll.adjustedContentInset.top
            if abs(wanted - scroll.contentOffset.y) > 0.5, !scroll.isDragging, !scroll.isDecelerating {
                scroll.contentOffset.y = wanted
            }
        }
        for block in blocks where !block.isLive && block.frame.intersects(scroll.bounds) { block.goLive() }
    }

    // MARK: Scrolling

    func scrollToTop() {
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top), animated: true)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { rememberPlaces() }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { rememberPlaces() }
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
        chromeTravel = (delta > 0) == (chromeTravel > 0) ? chromeTravel + delta : delta
        if chromeTravel > 24 { onChromeHidden?(true) } else if chromeTravel < -12 { onChromeHidden?(false) }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        followForChrome()
        for block in blocks where !block.isLive && block.frame.intersects(scroll.bounds.insetBy(dx: 0, dy: -scroll.bounds.height)) {
            block.goLive()
        }
    }
}

/// Over what links to a note, at its end: a hairline, and how many.
final class LinkedHead: UIView, SheetBlock {
    private let label = UILabel()
    private let rule = UIView()
    var onHeightChange: (() -> Void)?
    var onCaretMove: (() -> Void)?
    var editors: [OutlineEditor] { [] }
    var isLive: Bool { true }
    func goLive() {}

    init(count: Int, metrics: PhoneMetrics) {
        super.init(frame: .zero)
        rule.backgroundColor = Ink.rule
        addSubview(rule)
        label.attributedText = NSAttributedString(string: "LINKED FROM \(count) \(count == 1 ? "NOTE" : "NOTES")", attributes: Card.label(size: metrics.size))
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func height(width: CGFloat) -> CGFloat { 64 }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = NoteBlock.side
        rule.frame = CGRect(x: side, y: 24, width: bounds.width - 2 * side, height: 1 / max(traitCollection.displayScale, 1))
        label.frame = CGRect(x: side, y: 36, width: bounds.width - 2 * side, height: 20)
    }

    func save() {}
    func notesChanged(_ paths: Set<String>) {}
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
