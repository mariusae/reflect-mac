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
}

/// A sheet of a column: notes one under another, each editable where it is
/// — the timeline's days, oldest at the top, each week before its days; or
/// a note on its own — with a scrubber down the right edge whose ticks are
/// the days and what is in them, to drag along with the thumb.
final class SheetController: UIViewController, UIScrollViewDelegate {
    let store: PrismStore
    private(set) var kind: SheetKind
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
    var onCompose: (() -> Void)?
    /// Asked to set a note's frontmatter key — `inbox`, `topic` — or take it away.
    var onFlag: ((String, String, String?) -> Void)?

    /// The timeline's entries, and the window of them shown.
    private var entries: [NoteRef] = []
    private var shown: Range<Int> = 0..<0
    private static let span = 40
    private static let step = 20
    /// The note to bring to the top once laid out.
    private var target: NoteRef?

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
        view.backgroundColor = Ink.paper
        scroll.delegate = self
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.contentInsetAdjustmentBehavior = .always
        scroll.showsVerticalScrollIndicator = false
        view.addSubview(scroll)
        scroll.addSubview(content)
        view.addSubview(scrubber)
        scrubber.onScrub = { [weak self] y in self?.scrub(to: y) }
        title = titleText
        navigationItem.largeTitleDisplayMode = .never
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardMoved(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        // Pulled down: a sync, now.
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            guard let self else { return }
            self.saveAll()
            Task { @MainActor in
                await self.store.sync()
                refresh?.endRefreshing()
                if let error = self.store.syncError { self.say(error) }
            }
        }, for: .valueChanged)
        scroll.refreshControl = refresh
        let compose = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), primaryAction: UIAction { [weak self] _ in self?.onCompose?() })
        compose.accessibilityLabel = "New Note"
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in
                guard let self, let menu = self.menu?(self) else { return done([]) }
                done(menu.children)
            },
        ]))
        more.accessibilityLabel = "More"
        navigationItem.rightBarButtonItems = [more, compose]
        if case .search(let query) = kind { setUpSearch(query) }
        reload()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if case .search(let query) = kind, query.isEmpty {
            DispatchQueue.main.async { self.navigationItem.searchController?.searchBar.becomeFirstResponder() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
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
        case .search: "Search"
        }
    }

    // MARK: Contents

    /// The notes shown whole: the timeline's days, a note on its own, the inbox's.
    private var noteBlocks: [NoteBlock] { blocks.compactMap { $0 as? NoteBlock } }

    func reload() {
        switch kind {
        case .timeline:
            guard let graph = store.graph, let index = store.index else { return }
            entries = Timeline.entries(graph: graph, index: index, including: target)
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
            if let block = existing.removeValue(forKey: ref) { return block }
            let block = NoteBlock(ref: ref, store: store, metrics: metrics, showsHeader: showsHeaders)
            block.onOpen = { [weak self] in self?.onOpen?(.note(ref.path)) }
            block.onLink = { [weak self] link in self?.onLink?(link) }
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
        let head = HeadBlock(title: "Inbox", kicker: paths.isEmpty ? "Nothing to deal with" : "\(paths.count) \(paths.count == 1 ? "note" : "notes") to deal with",
                             metrics: metrics)
        setBlocks(paths.map(NoteRef.init(path:)), showsHeaders: true, before: [head])
        for block in noteBlocks where block.accessory == nil {
            let path = block.ref.path
            block.setAccessory(symbol: "checkmark.circle", label: "Done") { [weak self] in self?.onFlag?(path, "inbox", nil) }
        }
    }

    // MARK: Tasks

    private var tasksShown: [String]?

    /// The open tasks, in Reflect's groups, each with what is under it.
    private func refreshTasks() {
        guard let graph = store.graph, let index = store.index else { return }
        let tasks = index.tasks()
        let signature = tasks.map { "\($0.notePath)#\($0.ordinal)#\($0.text)" }
        guard signature != tasksShown || blocks.isEmpty else { return }
        tasksShown = signature
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
        var after: [SheetBlock] = []
        for group in Tasks.group(tasks, today: .today) {
            after.append(HeadBlock(title: group.label, kicker: nil, metrics: metrics, isGroup: true))
            // A note's tasks together, as long as they come one after another.
            var runs: [(path: String, slices: [NoteSlice])] = []
            for task in group.tasks {
                guard let slice = slices["\(task.notePath)#\(task.ordinal)"] else { continue }
                if runs.last?.path == task.notePath { runs[runs.count - 1].slices.append(slice) } else { runs.append((task.notePath, [slice])) }
            }
            after += sliceBlocks(runs.map { ($0.path, $0.slices, editable.contains($0.path)) })
        }
        let head = HeadBlock(title: "Tasks", kicker: tasks.isEmpty ? "Nothing to do" : "\(tasks.count) to do", metrics: metrics)
        setBlocks([], showsHeaders: true, before: [head], after: after)
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
        let isTopic = store.index?.entry(path)?.isTopic == true || Backlinks.isEmpty(note.editor.rows)
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
    func notesChanged(_ paths: Set<String>) {
        for block in blocks { block.notesChanged(paths) }
        switch kind {
        case .timeline:
            guard let graph = store.graph, let index = store.index else { return }
            // A new day or week, in its place; the window kept on the same days.
            let new = Timeline.entries(graph: graph, index: index)
            guard new != entries, !shown.isEmpty else { return relayout() }
            let first = entries[shown.lowerBound], last = entries[shown.upperBound - 1]
            entries = new
            let low = entries.firstIndex(of: first) ?? 0
            let high = (entries.firstIndex(of: last) ?? entries.count - 1) + 1
            shown = low..<max(low, high)
            setBlocks(Array(entries[shown]), showsHeaders: true)
        case .inbox:
            refreshInbox()
        case .tasks:
            if !isTyping { refreshTasks() }
            relayout()
        case .backlinks(let path):
            refreshBacklinks(path)
            relayout()
        case .note(let path):
            refreshTopic(path)
            relayout()
        case .search:
            relayout()
        }
        title = titleText
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
        let safe = view.safeAreaInsets
        scrubber.frame = CGRect(x: view.bounds.width - 28, y: safe.top + 12, width: 28, height: view.bounds.height - safe.top - safe.bottom - 24)
        relayout()
    }

    /// Lays the notes out one under another, the one at the top of the
    /// screen kept where it is, however those above it grew or shrank.
    func relayout() {
        let width = view.bounds.width
        guard width > 0 else { return }
        let top = scroll.contentOffset.y + scroll.adjustedContentInset.top
        let anchor = blocks.last { $0.frame.minY <= top && $0.frame.height > 0 }.map { ($0, top - $0.frame.minY) }
        var y: CGFloat = 0
        for block in blocks {
            let height = block.height(width: width - 12)
            block.frame = CGRect(x: 0, y: y, width: width - 12, height: height)
            y += height
        }
        if case .timeline = kind, shown.upperBound == entries.count { y += max(0, view.bounds.height - 320) }
        content.frame = CGRect(x: 0, y: 0, width: width, height: y)
        scroll.contentSize = content.frame.size
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
        refreshMarks()
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
                for (index, row) in editor.rows.enumerated() {
                    guard case .heading = row.kind else { continue }
                    let range = editor.paragraphRanges[index]
                    let glyph = editor.outlineLayout.glyphIndexForCharacter(at: range.location)
                    let y = block.frame.minY + editor.frame.minY + editor.outlineLayout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                    marks.append(.init(fraction: y / height, title: InlineMarkup.plainText(row.text), rank: 1, isWeek: false))
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

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        scrubber.visible = scroll.contentOffset.y / max(scroll.contentSize.height, 1)
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
    func show(_ ref: NoteRef) {
        guard case .timeline = kind else { return }
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
    struct Mark {
        var fraction: CGFloat
        var title: String
        var rank: Int
        var isWeek: Bool
    }

    var marks: [Mark] = [] { didSet { setNeedsDisplay() } }
    /// Where the screen's top is, from 0 to 1.
    var visible: CGFloat = 0 { didSet { setNeedsDisplay() } }
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
        label.layer.masksToBounds = true
        addSubview(label)
        clipsToBounds = false
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(dragged(_:))).with { $0.minimumPressDuration = 0 })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
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
            onScrub?(fraction)
            // The day the thumb is at, said beside it, and felt as it passes.
            let nearest = marks.indices.filter { marks[$0].rank == 2 }.min { abs(marks[$0].fraction - fraction) < abs(marks[$1].fraction - fraction) }
            if let nearest {
                if nearest != lastMark { haptics.selectionChanged() }
                lastMark = nearest
                label.text = marks[nearest].title
                label.sizeToFit()
                label.frame = CGRect(x: -label.bounds.width - 12, y: y - label.bounds.height / 2, width: label.bounds.width, height: label.bounds.height)
                label.isHidden = false
            }
        default:
            label.isHidden = true
            lastMark = nil
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
        get { UserDefaults.standard.object(forKey: "TextSize") as? CGFloat ?? 17 }
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
