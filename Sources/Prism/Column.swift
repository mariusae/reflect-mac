import AppKit
import ReflectCore
import PrismCore
import ReflectUI

/// One mark on the scrubber: a day or week, a heading, or a topic.
struct ScrubMark {
    var y: CGFloat
    var title: String
    var detail: String?
    /// 3 for a day or week, 2 for a heading, 1 for a topic.
    var rank: Int
    /// A week's mark, in a shade of its own.
    var isWeek = false
}

/// A column of the window, the window's way of arranging things: the days,
/// one after another, oldest at the top, each week's note before the days
/// it covers; a note on its own; or what links to a note. It is a stack of
/// blocks — each note the outline editor's, under its name — with a
/// scrubber down the left whose ticks are the blocks and what is in them.
@MainActor
final class Column: NSView, OutlineTextViewNavigator {
    enum Kind: Equatable {
        case timeline
        case note(NoteRef)
        /// The notes linking to a note.
        case backlinks(NoteRef)
        /// The notes in the inbox.
        case inbox
        /// The tasks of every note, grouped as Reflect groups them.
        case tasks
        /// The notes some words are found in.
        case search(String)
    }

    let graph: Graph
    let images: ImageStore
    private(set) var kind: Kind = .timeline
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let scrubber = Scrubber()
    private let tip = ScrubTip()
    private let close = CloseButton()
    private let fade = TopFade()
    private let edges = SheetEdges()
    private var sheetList: SheetList?
    /// The sheets beneath the one shown, the bottom first: where the column
    /// has been, to go back to.
    var beneath: [Sheet] = [] {
        didSet {
            edges.count = beneath.count
            needsLayout = true
            if beneath.count != oldValue.count { onStackChange?() }
        }
    }
    /// Its stack grew or shrank: the columns' top sheets lined up again.
    var onStackChange: (() -> Void)?
    /// How many sheets the deepest stack among the columns shows beneath its
    /// top: room above every column's top sheet for that many, so the top
    /// sheets line up, however many each has beneath.
    var stackDepth = 0 {
        didSet {
            guard stackDepth != oldValue else { return }
            edges.depth = stackDepth
            needsLayout = true
        }
    }

    /// Room at the top for the window's buttons, over a stack.
    static let titleRoom: CGFloat = 30
    /// How much of each sheet beneath shows above the one in front of it.
    static let sheetStep: CGFloat = 10

    /// How far down the top sheet starts: the window's row of buttons and
    /// the sheets beneath, when there are stacks; nothing, else.
    var cardInset: CGFloat { stackDepth == 0 ? 0 : Self.titleRoom + CGFloat(stackDepth) * Self.sheetStep + 2 }
    /// Told to bring a sheet beneath to the top, by its place in `beneath`.
    var onRaise: ((Column, Int) -> Void)?
    /// A sheet was picked up: the top, for nil; else one beneath, by its place.
    var onDragSheet: ((Column, Int?, NSEvent) -> Void)?
    /// ⌘E's file of cards, while it is open.
    private(set) var switcher: SheetSwitcher?
    private(set) var blocks: [ColumnBlock] = []
    /// The notes in it, to edit.
    var views: [DayView] { blocks.compactMap { $0 as? DayView } }

    var metrics: OutlineMetrics {
        didSet {
            for view in views { view.metrics = metrics }
            relayout()
        }
    }
    var face: Typeface = .mona
    /// Its share of the window's width, among the columns'.
    var share: CGFloat = 1

    /// A link to follow, from here: and whether to a column of its own.
    var onOpen: ((URL, Column, _ newColumn: Bool) -> Void)?
    /// A note to open, from here — a backlink's — and whether in a column of its own.
    var onOpenPath: ((String, Column, _ newColumn: Bool) -> Void)?
    /// It was scrolled.
    var onScroll: ((Column) -> Void)?
    /// A note in it was written.
    var onSave: ((DayView) -> Void)?
    /// The note at the top of the column changed.
    var onCurrent: ((Column) -> Void)?
    var onClose: ((Column) -> Void)?
    /// Whether it may be closed: not when it is the only one.
    var closable = false { didSet { close.isHidden = !closable } }

    init(graph: Graph, images: ImageStore, metrics: OutlineMetrics) {
        self.graph = graph
        self.images = images
        self.metrics = metrics
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        scroll.wantsLayer = true
        addSubview(scroll)
        addSubview(fade)
        addSubview(scrubber)
        addSubview(tip)
        addSubview(close)
        addSubview(edges)
        edges.onClick = { [weak self] in
            guard let self, !beneath.isEmpty else { return }
            hideSheetList()
            onRaise?(self, beneath.count - 1)
        }
        edges.onDrag = { [weak self] event in
            guard let self else { return }
            hideSheetList()
            onDragSheet?(self, nil, event)
        }
        edges.onHover = { [weak self] inside in
            if inside { self?.showSheetList() } else { self?.hideSheetListSoon() }
        }
        tip.isHidden = true
        close.isHidden = true
        close.target = self
        close.action = #selector(closeColumn)
        scrubber.onHover = { [weak self] mark, y in self?.hover(mark, at: y) }
        scrubber.onPick = { [weak self] mark in self?.scroll(toY: mark.y, animated: true) }
        scrubber.onDrag = { [weak self] fraction in self?.drag(to: fraction) }
        scrubber.onPage = { [weak self] earlier in self?.page(earlier: earlier) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeColumn() { onClose?(self) }

    // MARK: Contents

    var isTimeline: Bool { kind == .timeline }
    /// Whether it shows many notes, one after another: the timeline, the inbox.
    var listsNotes: Bool { isTimeline || kind == .inbox }

    // MARK: Sheets

    private func showSheetList() {
        hideTimer?.invalidate()
        guard !beneath.isEmpty, switcher == nil else { return }
        let list = sheetList ?? {
            let list = SheetList()
            list.onChoose = { [weak self] row in
                guard let self else { return }
                hideSheetList()
                onRaise?(self, beneath.count - 1 - row)
            }
            list.onLeave = { [weak self] in self?.hideSheetListSoon() }
            list.onDrag = { [weak self] row, event in
                guard let self else { return }
                hideSheetList()
                onDragSheet?(self, beneath.count - 1 - row, event)
            }
            addSubview(list)
            sheetList = list
            return list
        }()
        list.show(beneath.reversed(), face: face)
        let width = min(360, bounds.width - 48)
        let height = min(list.fittingHeight, bounds.height - 120)
        list.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: edges.frame.minY - 6 - height, width: width, height: height)
    }

    private var hideTimer: Timer?

    /// The list goes when the pointer has left both it and the edges.
    private func hideSheetListSoon() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let list = self.sheetList, let window = self.window else { return }
                let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if !list.frame.contains(point), !self.edges.frame.contains(point) { self.hideSheetList() }
            }
        }
    }

    private func hideSheetList() {
        hideTimer?.invalidate()
        sheetList?.removeFromSuperview()
        sheetList = nil
    }

    /// Opens ⌘E's cards: from the sheet just beneath the top, or, going
    /// backward, from the bottom.
    func openSwitcher(backward: Bool) {
        guard switcher == nil, !beneath.isEmpty else { return }
        hideSheetList()
        let sheets = beneath + [currentSheet]
        let switcher = SheetSwitcher(sheets: sheets, contentSize: bounds.size, selection: backward ? 0 : sheets.count - 2, face: face)
        switcher.frame = bounds
        switcher.onPick = { [weak self] index in self?.closeSwitcher(choosing: index) }
        addSubview(switcher)
        self.switcher = switcher
        switcher.present()
    }

    /// Moves the choice: down the stack for E, up for ⇧E.
    func moveSwitcher(_ delta: Int) { switcher?.move(delta) }

    /// Closes the cards on the one chosen — the top, for none — which comes
    /// forward and is brought to the top.
    func closeSwitcher(choosing index: Int?) {
        guard let switcher, !switcher.isClosing else { return }
        let top = beneath.count
        let chosen = index ?? top
        switcher.dismiss(to: chosen) { [weak self, weak switcher] in
            switcher?.tearDown()
            switcher?.removeFromSuperview()
            guard let self else { return }
            self.switcher = nil
            if chosen != top { onRaise?(self, chosen) }
        }
    }

    var switcherSelection: Int? { switcher?.selection }

    /// Settles the cards at once, for a script's picture.
    func settleSwitcherForScript() { switcher?.settle() }

    // MARK: Searching

    /// The words looked for were changed, here.
    var onSearch: ((String, Column) -> Void)?

    /// Shows a search: its head, and the notes found — nil while looking —
    /// each with where the words are, editable. The head is kept as it is
    /// typed in.
    func showSearch(_ query: String, found: [(path: String, slices: [TaskSlice], editable: Bool)]?,
                    names: (String) -> (title: String, detail: String?)) {
        let head = (kind == .search(query) || { if case .search = kind { true } else { false } }())
            ? blocks.first as? SearchHeader : nil
        let top = scroll.contentView.bounds.minY
        let same = head != nil
        if !same { removeBlocks() } else { blocks.dropFirst().forEach { $0.removeFromSuperview() } }
        kind = .search(query)
        let header = head ?? {
            let header = SearchHeader(query: query, metrics: metrics)
            header.onQuery = { [weak self] words in
                guard let self else { return }
                onSearch?(words, self)
            }
            document.addSubview(header)
            return header
        }()
        header.show(count: found?.count)
        let words = Self.words(query)
        let root = graph.root
        let results: [ColumnBlock] = (found ?? []).map { note in
            let name = names(note.path)
            let block = BacklinkBlock(path: note.path, slices: note.slices, editable: note.editable, name: name.title,
                                      detail: name.detail,
                                      folded: SessionState.shared.backlinkFolded(root, to: "search:", from: note.path),
                                      unit: "match", highlight: words, metrics: metrics, face: face, images: images,
                                      navigator: self)
            block.onFold = { [weak self] folded in
                SessionState.shared.setBacklinkFolded(root, to: "search:", from: note.path, folded)
                self?.relayout()
            }
            block.onOpen = { [weak self] newColumn in
                guard let self else { return }
                onOpenPath?(note.path, self, newColumn)
            }
            for editor in block.editors {
                editor.onEdit = { [weak self] editor in
                    guard let self else { return }
                    onSliceEdit?(editor, self)
                }
                editor.onResize = { [weak self] in self?.relayout() }
                editor.onLeave = { [weak self] in
                    guard let self else { return }
                    onSliceLeave?(self)
                }
            }
            return block
        }
        blocks = [header] + results
        results.forEach(document.addSubview)
        relayout()
        if same {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(top, max(0, document.frame.height - scroll.contentSize.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            scroll(toY: 0, animated: false)
            window?.makeFirstResponder(header.field)
        }
        settled = true
    }

    /// A query's words, as looked for.
    static func words(_ query: String) -> [String] { NoteSearch.words(query) }

    /// Whether the keyboard is in the search's field.
    var isTypingQuery: Bool {
        guard let header = blocks.first as? SearchHeader, let editor = header.field.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    // MARK: The tasks

    /// Each task shown, editable where it is.
    var taskEditors: [TaskEditor] { blocks.compactMap { $0 as? TaskGroupBlock }.flatMap(\.editors) }
    /// Every piece of a note shown here away from it — tasks, the rows
    /// links are in — editable where it is.
    var sliceEditors: [TaskEditor] { taskEditors + blocks.compactMap { $0 as? BacklinkBlock }.flatMap(\.editors) }
    /// A piece of a note was typed in: to write back.
    var onSliceEdit: ((TaskEditor, Column) -> Void)?
    /// The keyboard left a piece of a note: what changed meanwhile can be shown.
    var onSliceLeave: ((Column) -> Void)?
    /// Whether the keyboard is in a piece of a note here: shown again only once it leaves.
    var isTypingInSlice: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return sliceEditors.contains { $0.view === responder }
    }

    /// Shows the tasks, their groups under a head — scrolled where they
    /// were, when they were shown already.
    func showTasks(_ groups: [TaskGroupBlock], count: Int) {
        let same = kind == .tasks
        let top = scroll.contentView.bounds.minY
        removeBlocks()
        kind = .tasks
        let head = InboxHeader(metrics: metrics, title: "Tasks", describe: { $0 == 0 ? "Nothing to do" : "\($0) to do" })
        head.count = count
        blocks = [head] + groups
        blocks.forEach(document.addSubview)
        relayout()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: same ? min(top, max(0, document.frame.height - scroll.contentSize.height)) : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        settled = true
    }

    // MARK: The inbox

    /// Told to take a note out of the inbox: its handle was clicked.
    var onRemoveFromInbox: ((NoteRef) -> Void)?
    /// Each inbox note's handle, by the note.
    private var handles: [NoteRef: CloseButton] = [:]
    /// The rules between the inbox's notes, as the days are ruled apart.
    private var rules: [NSView] = []
    /// Each note's flags — inbox, pinned, private, topic — by its name.
    private var badges: [NoteRef: NoteBadges] = [:]
    /// Each listed note's ⋯, at the right of its name: its own menu.
    private var menuButtons: [NoteRef: NSButton] = [:]
    /// Told when a note's ⋯ is clicked: its menu, to show from the button.
    var onNoteMenu: ((DayView, NSButton) -> Void)?
    /// What each note's frontmatter says of it, by path: the graph's index's.
    static var flags: (String) -> NoteFlags = { _ in [] }
    /// Over each note's header, among many: a click opens the note alone.
    private var headerLinks: [NoteRef: NoteHeaderLink] = [:]
    /// A note's header was clicked: the note, to open on its own — with ⌘,
    /// in a column of its own.
    var onOpenAlone: ((NoteRef, Column, _ newColumn: Bool) -> Void)?

    /// Shows the inbox's notes: those already shown kept where they are,
    /// those new to it first, those gone from it let go.
    func showInbox(_ refs: [NoteRef]) {
        let wasInbox = kind == .inbox
        if !wasInbox {
            removeBlocks()
            kind = .inbox
            settled = false
        }
        var existing: [NoteRef: DayView] = [:]
        var header: InboxHeader?
        for block in blocks {
            if let view = block as? DayView { existing[view.ref] = view } else if let block = block as? InboxHeader { header = block }
        }
        let wanted = Set(refs)
        let kept = blocks.compactMap { ($0 as? DayView)?.ref }.filter(wanted.contains)
        let ordered = refs.filter { !kept.contains($0) } + kept
        let head = header ?? {
            let head = InboxHeader(metrics: metrics)
            document.addSubview(head)
            return head
        }()
        head.metrics = metrics
        head.count = ordered.count
        blocks = [head] + ordered.map { ref in existing.removeValue(forKey: ref) ?? makeView(ref) }
        for view in existing.values { letGo(view) }
        for (ref, handle) in handles where !wanted.contains(ref) {
            handle.removeFromSuperview()
            handles[ref] = nil
        }
        for ref in ordered where handles[ref] == nil {
            let handle = CloseButton(toolTip: "Remove from Inbox")
            handle.target = self
            handle.action = #selector(removeFromInbox(_:))
            handle.identifier = NSUserInterfaceItemIdentifier(ref.path)
            document.addSubview(handle)
            handles[ref] = handle
        }
        relayout()
        if !wasInbox {
            scroll(toY: 0, animated: false)
            settled = true
        }
    }

    @objc private func removeFromInbox(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        onRemoveFromInbox?(NoteRef(path: path))
    }

    /// Each handle at the right of its note's name; a rule over each note
    /// but the first.
    private func placeHandles() {
        placeBadges()
        guard kind == .inbox else { return }
        let notes = views
        while rules.count < max(0, notes.count - 1) {
            let rule = NSView()
            rule.wantsLayer = true
            document.addSubview(rule)
            rules.append(rule)
        }
        while rules.count > max(0, notes.count - 1) { rules.removeLast().removeFromSuperview() }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (rule, view) in zip(rules, notes.dropFirst()) {
                let column = min(metrics.columnWidth, view.frame.width - 48)
                rule.frame = NSRect(x: view.frame.minX + ((view.frame.width - column) / 2).rounded(), y: view.frame.minY,
                                    width: column, height: 1)
                rule.layer?.backgroundColor = Ink.rule.cgColor
            }
        }
        for view in notes {
            guard let handle = handles[view.ref] else { continue }
            let column = min(metrics.columnWidth, view.frame.width - 48)
            let right = view.frame.minX + ((view.frame.width - column) / 2).rounded() + column
            handle.frame = NSRect(x: right - 24, y: round(nameMiddle(of: view)) - 11, width: 22, height: 22)
        }
    }

    @objc private func noteMenuClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue, let view = view(for: NoteRef(path: path)) else { return }
        onNoteMenu?(view, sender)
    }

    /// Where a note's name is, down its view: the title over it, or else
    /// its own first line.
    private func nameMiddle(of view: DayView) -> CGFloat {
        // Laid out at its frame first: the editor placed under its name.
        view.layoutSubtreeIfNeeded()
        let editor = view.editor
        if editor.frame.minY < metrics.fontSize * 2, let layout = editor.layoutManager, layout.numberOfGlyphs > 0 {
            let line = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            return view.frame.minY + editor.frame.minY + editor.textContainerOrigin.y + line.midY
        }
        return view.frame.minY + round(metrics.fontSize * 2.2) + round(metrics.fontSize * 1.45 * 1.2 / 2)
    }

    /// Over each note's header, where it has one of its own — a day's date,
    /// a week's name, a title — a link to the note alone.
    private func placeHeaderLinks() {
        let notes = listsNotes ? views : []
        let shown = Set(notes.map(\.ref))
        for (ref, link) in headerLinks where !shown.contains(ref) {
            link.removeFromSuperview()
            headerLinks[ref] = nil
        }
        for view in notes {
            view.layoutSubtreeIfNeeded()
            let top = view.editor.frame.minY
            // Its first heading its name, it has no header but its text.
            guard top >= metrics.fontSize * 2 else {
                headerLinks[view.ref]?.removeFromSuperview()
                headerLinks[view.ref] = nil
                continue
            }
            let link = headerLinks[view.ref] ?? {
                let link = NoteHeaderLink()
                let ref = view.ref
                link.onClick = { [weak self] newColumn in
                    guard let self else { return }
                    onOpenAlone?(ref, self, newColumn)
                }
                link.toolTip = "Open “\(Self.name(of: ref).title)” (⌘-click: in the column beside; ⇧⌘-click: in a new one)"
                // Just over its note, and under the flags, which say what they are.
                document.addSubview(link, positioned: .above, relativeTo: view)
                headerLinks[view.ref] = link
                return link
            }()
            let column = min(metrics.columnWidth, view.frame.width - 48)
            let left = view.frame.minX + ((view.frame.width - column) / 2).rounded()
            link.frame = NSRect(x: left, y: view.frame.minY + round(metrics.fontSize * 1.6), width: column,
                                height: max(0, top - round(metrics.fontSize * 1.6) - 2))
        }
    }

    /// Each note's flags, at the right of its name — left of the inbox's ×.
    private func placeBadges() {
        placeHeaderLinks()
        let notes = views
        let shown = Set(notes.map(\.ref))
        for (ref, badge) in badges where !shown.contains(ref) {
            badge.removeFromSuperview()
            badges[ref] = nil
        }
        // A ⋯ on each note among many, its own menu.
        let menuSide: CGFloat = 26
        for (ref, button) in menuButtons where !shown.contains(ref) || !listsNotes {
            button.removeFromSuperview()
            menuButtons[ref] = nil
        }
        if listsNotes {
            for view in notes {
                let button = menuButtons[view.ref] ?? {
                    let button = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Note Menu")!,
                                          target: self, action: #selector(noteMenuClicked(_:)))
                    button.isBordered = false
                    button.contentTintColor = Ink.secondary
                    button.toolTip = "Pin, inbox, copy link…"
                    document.addSubview(button)
                    menuButtons[view.ref] = button
                    return button
                }()
                button.identifier = NSUserInterfaceItemIdentifier(view.ref.path)
                let column = min(metrics.columnWidth, view.frame.width - 48)
                let right = view.frame.minX + ((view.frame.width - column) / 2).rounded() + column - (kind == .inbox ? 30 : 0)
                button.frame = NSRect(x: right - menuSide, y: round(nameMiddle(of: view) - menuSide / 2) + 3, width: menuSide, height: menuSide)
            }
        }
        for view in notes {
            let flags = Self.flags(view.ref.path)
            guard !flags.isEmpty else {
                badges[view.ref]?.removeFromSuperview()
                badges[view.ref] = nil
                continue
            }
            let badge = badges[view.ref] ?? {
                let badge = NoteBadges()
                document.addSubview(badge)
                badges[view.ref] = badge
                return badge
            }()
            badge.flags = flags
            badge.size = round(metrics.fontSize * 0.8)
            let column = min(metrics.columnWidth, view.frame.width - 48)
            let right = view.frame.minX + ((view.frame.width - column) / 2).rounded() + column - (kind == .inbox ? 30 : 4) - (listsNotes ? menuSide : 0)
            let size = badge.intrinsicContentSize
            badge.frame = NSRect(x: right - size.width, y: round(nameMiddle(of: view) - size.height / 2), width: size.width, height: size.height)
        }
    }

    // MARK: The timeline

    /// Every day and week there is a note for, in order: the timeline the
    /// column shows a window on.
    private var entries: [NoteRef] = []
    /// The entries shown: some fifty about where the reader is, slid along
    /// as they scroll to either end — so the column, and its scrubber, hold
    /// about as much wherever in time they are.
    private(set) var shown: Range<Int> = 0..<0
    private static let span = 48
    private static let step = 24

    /// Shows the timeline, the window on it about a note.
    func showTimeline(_ entries: [NoteRef], around ref: NoteRef) {
        self.entries = entries
        let center = entries.firstIndex(of: ref) ?? entries.count - 1
        let low = max(0, min(center - Self.span / 2, entries.count - Self.span))
        shown = low..<min(entries.count, low + Self.span)
        if kind != .timeline { removeBlocks() }
        kind = .timeline
        settled = false
        setBlocks(entries[shown])
    }

    /// The timeline as it now is — a day written in elsewhere, a week
    /// begun — the window kept on the same days.
    func updateTimeline(_ entries: [NoteRef]) {
        guard isTimeline, !shown.isEmpty else { return }
        let first = self.entries[shown.lowerBound], last = self.entries[shown.upperBound - 1]
        self.entries = entries
        let low = entries.firstIndex(of: first) ?? entries.firstIndex { $0 == last } ?? 0
        let high = (entries.firstIndex(of: last) ?? entries.count - 1) + 1
        shown = low..<max(low, high)
        setBlocks(entries[shown])
    }

    /// Whether a note is among those shown.
    func shows(_ ref: NoteRef) -> Bool { isTimeline && entries[shown].contains(ref) }

    /// Moves the window a step along, earlier or later: notes added at that
    /// end, and as many taken off the other, out of sight.
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
        setBlocks(entries[shown])
    }

    /// The timeline's notes in place of those shown: those still shown kept
    /// as they are, the others made, or written and let go.
    private func setBlocks(_ refs: ArraySlice<NoteRef>) {
        var existing: [NoteRef: DayView] = [:]
        for block in blocks {
            if let view = block as? DayView { existing[view.ref] = view } else { block.removeFromSuperview() }
        }
        blocks = refs.map { ref -> ColumnBlock in
            if let gap = ref.gap { return makeGap(gap) }
            return existing.removeValue(forKey: ref) ?? makeView(ref)
        }
        for view in existing.values { letGo(view) }
        relayout()
    }

    /// Shows a note on its own.
    func showNote(_ ref: NoteRef) {
        removeBlocks()
        backlinks = nil
        blocks = [makeView(ref)]
        kind = .note(ref)
        settled = false
        relayout()
        scroll(toY: 0, animated: false)
    }

    /// Shows what links to a note: `sources` nil while they are looked for.
    func showBacklinks(of ref: NoteRef, name: String, sources: [BacklinkSource]?,
                       names: (String) -> (title: String, detail: String?)) {
        let top = scroll.contentView.bounds.minY
        let same = kind == .backlinks(ref)
        removeBlocks()
        kind = .backlinks(ref)
        let header = BacklinksHeader(note: name, count: sources?.count, metrics: metrics)
        header.onOpen = { [weak self] newColumn in
            guard let self else { return }
            onOpenPath?(ref.path, self, newColumn)
        }
        let blocks: [ColumnBlock] = [header] + backlinkBlocks(to: ref, sources ?? [], names: names)
        self.blocks = blocks
        blocks.forEach(document.addSubview)
        relayout()
        // Looked for again, the column stays where it was read to.
        if sources != nil, let offset = pendingOffset {
            pendingOffset = nil
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(offset, document.frame.height - scroll.contentSize.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            scroll(toY: same ? top + 12 : 0, animated: false)
        }
    }

    /// A block for each note linking to a note: its name, and the links,
    /// folded away when they were left so.
    private func backlinkBlocks(to ref: NoteRef, _ sources: [BacklinkSource],
                                names: (String) -> (title: String, detail: String?)) -> [ColumnBlock] {
        let root = graph.root
        return sources.map { source in
            let name = names(source.path)
            let text = graph.read(path: source.path) ?? ""
            let slices = TaskSlice.slices(holding: source.contexts.map(\.link), path: source.path, in: text)
            let block = BacklinkBlock(path: source.path, slices: slices, editable: OutlineMarkdown.roundTrips(text),
                                      name: name.title, detail: name.detail,
                                      folded: SessionState.shared.backlinkFolded(root, to: ref.path, from: source.path),
                                      metrics: metrics, face: face, images: images, navigator: self)
            for editor in block.editors {
                editor.onEdit = { [weak self] editor in
                    guard let self else { return }
                    onSliceEdit?(editor, self)
                }
                editor.onResize = { [weak self] in self?.relayout() }
                editor.onLeave = { [weak self] in
                    guard let self else { return }
                    onSliceLeave?(self)
                }
            }
            block.onFold = { [weak self] folded in
                SessionState.shared.setBacklinkFolded(root, to: ref.path, from: source.path, folded)
                self?.relayout()
            }
            block.onOpen = { [weak self] newColumn in
                guard let self else { return }
                onOpenPath?(source.path, self, newColumn)
            }
            return block
        }
    }

    /// A topic note's backlinks, under it in its column: what it is, it is
    /// by what links to it. Nil takes them away.
    func showInlineBacklinks(_ sources: [BacklinkSource]?, names: (String) -> (title: String, detail: String?)) {
        guard case .note(let ref) = kind, let note = blocks.first as? DayView else { return }
        for block in blocks.dropFirst() { block.removeFromSuperview() }
        var blocks: [ColumnBlock] = [note]
        if let sources {
            let head = InlineBacklinksHeader(count: sources.count, metrics: metrics)
            blocks += [head] + backlinkBlocks(to: ref, sources, names: names)
        }
        self.blocks = blocks
        blocks.dropFirst().forEach(document.addSubview)
        relayout()
    }

    private func removeBlocks() {
        headerLinks.values.forEach { $0.removeFromSuperview() }
        headerLinks = [:]
        badges.values.forEach { $0.removeFromSuperview() }
        badges = [:]
        handles.values.forEach { $0.removeFromSuperview() }
        handles = [:]
        rules.forEach { $0.removeFromSuperview() }
        rules = []
        for block in blocks {
            if let view = block as? DayView { letGo(view) } else { block.removeFromSuperview() }
        }
        blocks = []
    }

    func view(for ref: NoteRef) -> DayView? { views.first { $0.ref == ref } }

    /// A note shown here, shown no more: written, and told of.
    private func letGo(_ view: DayView) {
        view.save()
        view.removeFromSuperview()
        onViewGone?(view)
    }

    /// A note began to be shown here: its title as it is, to tell a new one by.
    var onViewMade: ((DayView) -> Void)?
    /// A note is no longer shown here.
    var onViewGone: ((DayView) -> Void)?

    /// Told when a gap in the timeline is clicked: some of its days to show.
    var onRevealGap: ((TimelineGap) -> Void)?

    private func makeGap(_ gap: TimelineGap) -> GapView {
        let view = GapView(gap: gap, metrics: metrics)
        view.onReveal = { [weak self] gap in self?.onRevealGap?(gap) }
        document.addSubview(view)
        return view
    }

    private func makeView(_ ref: NoteRef) -> DayView {
        let view = DayView(ref: ref, graph: graph, images: images, metrics: metrics)
        view.editor.navigator = self
        view.onHeightChange = { [weak self] _ in self?.setNeedsRelayout() }
        view.onSave = { [weak self, weak view] in
            guard let view else { return }
            self?.onSave?(view)
        }
        document.addSubview(view)
        onViewMade?(view)
        return view
    }

    func saveAll() { views.forEach { $0.save() } }
    func reloadFromDisk() {
        views.forEach { $0.reloadIfChanged() }
        relayout()
    }

    /// The notes shown that changed on disk, as they now are — a note with
    /// writing not yet saved here keeps it, and is told of the change.
    func reloadFromDisk(_ paths: Set<String>) {
        let changed = views.filter { paths.contains($0.ref.path) }
        guard !changed.isEmpty else { return }
        changed.forEach { $0.reloadIfChanged() }
        relayout()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        // The top sheet: the column's notes, under the sheets beneath.
        let card = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - cardInset)
        scroll.frame = card
        if let layer = scroll.layer {
            // Over a stack, a sheet: its top corners rounded.
            layer.cornerRadius = cardInset > 0 ? 6 : 0
            layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            layer.masksToBounds = cardInset > 0
        }
        fade.frame = NSRect(x: 0, y: card.maxY - 64, width: card.width, height: 64)
        scrubber.frame = NSRect(x: 4, y: 56, width: 40, height: max(0, card.height - 112))
        close.frame = NSRect(x: bounds.width - 34, y: bounds.height - 34, width: 22, height: 22)
        if stackDepth > 0 {
            // From the deepest sheet's edge down into the top sheet's.
            let band = CGFloat(stackDepth) * Self.sheetStep + 2
            edges.frame = NSRect(x: 0, y: card.maxY - SheetEdges.reach, width: bounds.width, height: band + SheetEdges.reach)
        } else {
            edges.frame = NSRect(x: 56, y: bounds.height - 30 - 12, width: max(0, bounds.width - 112), height: 12)
        }
        switcher?.frame = bounds
        relayout()
    }

    private var relayoutPending = false

    private func setNeedsRelayout() {
        guard !relayoutPending else { return }
        relayoutPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            relayoutPending = false
            relayout()
        }
    }

    /// The blocks laid out here already, whose frames say where they are.
    private var placed: Set<ObjectIdentifier> = []

    /// Lays the notes out one under another, the one at the top of the
    /// column kept where it is, however those above it grew or shrank.
    func relayout() {
        defer { placeHandles() }
        let width = scroll.contentSize.width
        guard width > 0 else { return }
        let top = scroll.contentView.bounds.minY
        // Only blocks this has placed: a new one's frame says nothing yet.
        let laidOut = blocks.filter { placed.contains(ObjectIdentifier($0)) && $0.frame.height > 0 }
        let anchor = (laidOut.last { $0.frame.minY <= top } ?? laidOut.first).map { ($0, top - $0.frame.minY) }
        var y: CGFloat = isTimeline ? 24 : 40
        // The notes clear of the scrubber, on the left.
        let inset: CGFloat = 36
        for view in blocks {
            let height = view.desiredHeight(width: width - inset)
            let frame = NSRect(x: inset, y: y, width: width - inset, height: height)
            if view.frame != frame { view.frame = frame }
            y += height
        }
        // Room for the last note to come to the top.
        y += isTimeline && shown.upperBound == entries.count ? max(120, scroll.contentSize.height - 260) : 160
        let size = NSSize(width: width, height: max(y, scroll.contentSize.height))
        if document.frame.size != size { document.setFrameSize(size) }
        placed = Set(blocks.map { ObjectIdentifier($0) })
        if let (view, offset) = anchor, blocks.contains(where: { $0 === view }) {
            let target = max(0, min(view.frame.minY + offset, size.height - scroll.contentSize.height))
            if abs(target - top) > 0.5 {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        refreshMarks()
    }

    private func refreshMarks() {
        let marks = blocks.flatMap { block in
            block.scrubMarks(listed: listsNotes).map { mark in
                var mark = mark
                mark.y += block.frame.minY
                return mark
            }
        }
        scrubber.update(marks: marks, height: document.frame.height, visible: scroll.contentView.bounds)
        scrubber.earlier = isTimeline && shown.lowerBound > 0 ? Self.name(of: entries[shown.lowerBound - 1]).title : nil
        scrubber.later = isTimeline && shown.upperBound < entries.count ? Self.name(of: entries[shown.upperBound]).title : nil
    }

    /// Goes to the note just past the window's end, the window about it.
    private func page(earlier: Bool) {
        guard isTimeline else { return }
        let index = earlier ? shown.lowerBound - 1 : shown.upperBound
        guard entries.indices.contains(index) else { return }
        let ref = entries[index]
        showTimeline(entries, around: ref)
        reveal(ref, animated: false)
    }

    /// Notes' titles, by path: the graph's index's.
    static var titles: (String) -> String? = { _ in nil }

    /// What a note is called on the scrubber: a day's date, a week's
    /// number, any other note its title.
    static func name(of ref: NoteRef) -> (title: String, detail: String?) {
        if let gap = ref.gap { return ("⋯", GapView.describe(gap)) }
        if let day = ref.day { return (OpenQuickly.dayTitle(day), day == .today ? "Today" : nil) }
        if let week = GraphPaths.week(fromWeeklyPath: ref.path) { return ("Week \(week.week)", OpenQuickly.weekRange(week)) }
        return (titles(ref.path) ?? (ref.path as NSString).lastPathComponent, nil)
    }

    // MARK: Scrolling

    private var sliding = false
    /// Whether the column has been taken to the note it was opened at: till
    /// then, where it is scrolled to says nothing of where the reader is.
    private var settled = false

    @objc private func scrolled() {

        scrubber.update(visible: scroll.contentView.bounds)
        // Within a screen of either end, the window slides along.
        if isTimeline, settled, !sliding {
            sliding = true
            let visible = scroll.contentView.bounds
            if visible.minY < visible.height, shown.lowerBound > 0 {
                slide(earlier: true)
            } else if visible.maxY > document.frame.height - visible.height, shown.upperBound < entries.count {
                slide(earlier: false)
            }
            sliding = false
        }
        onCurrent?(self)
        // The note at the top keeps how far into it it was read — on its
        // own or among the days — to open there again, wherever it is opened.
        if settled, let view = current {
            SessionState.shared.setOffset(graph.root, view.ref, Double(scroll.contentView.bounds.minY - view.frame.minY))
        }
        onScroll?(self)
    }

    /// The note at the top of the column.
    var current: DayView? {
        let top = scroll.contentView.bounds.minY + 60
        return views.last { $0.frame.minY <= top } ?? views.first
    }

    /// Whether the note at the top has its name scrolled out of sight.
    var currentNameHidden: Bool {
        guard let current else { return false }
        return current.frame.minY + 40 < scroll.contentView.bounds.minY
    }

    func scroll(toY y: CGFloat, animated: Bool) {
        let target = NSPoint(x: 0, y: max(0, min(y - 12, document.frame.height - scroll.contentSize.height)))
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scroll.contentView.animator().setBoundsOrigin(target)
            }
        } else {
            scroll.contentView.scroll(to: target)
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Brings a note to the top, the keyboard in it.
    /// Where a column is: the note at its top, and how far into it.
    struct Place: Equatable {
        var ref: NoteRef
        var offset: CGFloat
    }

    var place: Place? {
        guard let current else { return nil }
        return Place(ref: current.ref, offset: scroll.contentView.bounds.minY - current.frame.minY)
    }

    /// Scrolls back to a place, when its note is shown — the keyboard put in
    /// `key`, where its caret was left, when that is shown too.
    func restore(_ place: Place, key: NoteRef? = nil) {
        relayout()
        if let view = view(for: place.ref) {
            let y = max(0, min(view.frame.minY + place.offset, document.frame.height - scroll.contentSize.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        settled = true
        guard let key, let view = view(for: key), !view.hasConflict else { return }
        window?.makeFirstResponder(view.editor)
        _ = view.restoreSelection()
    }

    /// How far down the column is scrolled.
    var scrollOffset: CGFloat { scroll.contentView.bounds.minY }

    /// What links to the note, as last shown: not shown again unchanged.
    var backlinks: [BacklinkSource]?

        /// A backlinks column's place, to go back to once its notes are found.
    var pendingOffset: CGFloat?

    func reveal(_ ref: NoteRef, animated: Bool) {
        guard let view = view(for: ref) else { return }
        relayout()
        scroll(toY: view.frame.minY, animated: animated)
        settled = true
        guard !view.hasConflict else { return }
        window?.makeFirstResponder(view.editor)
        if !view.restoreSelection() { view.editor.enter(from: .bottom, x: .greatestFiniteMagnitude, scrolling: false) }
    }

    private func drag(to fraction: CGFloat) {
        let y = fraction * document.frame.height - scroll.contentSize.height / 2
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, document.frame.height - scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func hover(_ mark: ScrubMark?, at y: CGFloat) {
        guard let mark else { tip.isHidden = true; return }
        tip.show(mark, face: face)
        let size = tip.fittingSize
        let point = convert(NSPoint(x: scrubber.frame.maxX, y: y), from: scrubber)
        tip.frame = NSRect(x: point.x + 2, y: round(point.y - size.height / 2), width: size.width, height: size.height)
        tip.isHidden = false
    }

    var scrolledForScript: String { "\(scroll.contentView.bounds.minY) of \(document.frame.height)" }

    /// Scrolls by some points, as the wheel does.
    func scrollForScript(by amount: CGFloat) {
        let y = max(0, min(scroll.contentView.bounds.minY + amount, document.frame.height - scroll.contentSize.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func hoverForScript(_ fraction: CGFloat) {
        layoutSubtreeIfNeeded()
        scrubber.hover(atFraction: fraction)
    }

    // MARK: OutlineTextViewNavigator

    func outlineView(_ view: OutlineTextView, leaveThrough edge: OutlineTextView.Edge, x: CGFloat) {
        guard listsNotes, let index = views.firstIndex(where: { $0.editor === view }) else {
            view.enter(from: edge, x: edge == .top ? 0 : .greatestFiniteMagnitude)
            return
        }
        let next = index + (edge == .top ? -1 : 1)
        guard views.indices.contains(next) else { return }
        let target = views[next]
        window?.makeFirstResponder(target.editor)
        target.editor.enter(from: edge == .top ? .bottom : .top, x: x)
        if edge == .bottom {
            // Going down into a day shows its date along with its first line.
            target.scrollToVisible(NSRect(x: 0, y: 0, width: 1, height: target.editor.frame.minY + 1))
        }
    }

    func outlineView(_ view: OutlineTextView, open url: URL, inSplit: Bool) {
        onOpen?(url, self, inSplit)
    }
}

/// The ticks down a column's left: a long one for each day and week, a
/// shorter one for each heading, the shortest for each topic. Those on
/// screen are darker; weeks are ochre. Hovered, a tick says what it is;
/// clicked, goes there; dragged along, scrolls.
final class Scrubber: NSView {
    var onHover: ((ScrubMark?, CGFloat) -> Void)?
    var onPick: ((ScrubMark) -> Void)?
    /// Dragged along: how far down the page, from 0 to 1.
    var onDrag: ((CGFloat) -> Void)?
    /// One of the ends was clicked: earlier, or later.
    var onPage: ((_ earlier: Bool) -> Void)?
    /// What is past each end, when anything is: shown as a chevron there.
    var earlier: String? { didSet { if earlier != oldValue { needsDisplay = true } } }
    var later: String? { didSet { if later != oldValue { needsDisplay = true } } }

    private var marks: [ScrubMark] = []
    /// Each kept mark and where on the scrubber it is.
    private var placed: [(mark: ScrubMark, y: CGFloat)] = []
    private var height: CGFloat = 1
    private var visible: NSRect = .zero
    private var hovered: Int?
    private var dragged = false

    override var isFlipped: Bool { true }

    func update(marks: [ScrubMark], height: CGFloat, visible: NSRect) {
        self.marks = marks.sorted { $0.y < $1.y }
        self.height = max(height, 1)
        self.visible = visible
        place()
    }

    func update(visible: NSRect) {
        self.visible = visible
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    /// Room at each end for its chevron.
    private static let pad: CGFloat = 18

    private func position(_ y: CGFloat) -> CGFloat {
        Self.pad + y / height * max(1, bounds.height - 2 * Self.pad)
    }

    /// Where each mark goes. With more than there is room for, the least
    /// are left out — topics, then headings — and of marks still too close
    /// to tell apart, the greater kept.
    private func place() {
        placed = []
        let room = Int(max(0, bounds.height - 2 * Self.pad) / 6)
        let least = (1...3).first { rank in marks.filter { $0.rank >= rank }.count <= room } ?? 3
        for mark in marks where mark.rank >= least {
            let y = round(position(mark.y))
            if let last = placed.last, y - last.y < 5 {
                if mark.rank > last.mark.rank || (mark.isWeek && !last.mark.isWeek) { placed[placed.count - 1] = (mark, last.y) }
                continue
            }
            placed.append((mark, y))
        }
        hovered = nil
        needsDisplay = true
    }

    /// Where the ticks start, and how long a day's is.
    private static let tickX: CGFloat = 12
    private static let dayLength: CGFloat = 20

    /// The ends' chevrons, when there is more past them: centred over the
    /// days' ticks.
    private var earlierRect: NSRect { NSRect(x: Self.tickX, y: 0, width: Self.dayLength, height: 14) }
    private var laterRect: NSRect { NSRect(x: Self.tickX, y: bounds.height - 14, width: Self.dayLength, height: 14) }

    private func drawChevron(in rect: NSRect, up: Bool, hot: Bool) {
        let path = NSBezierPath()
        let mid = rect.midX, y = rect.midY
        path.move(to: NSPoint(x: mid - 5, y: y + (up ? 2.5 : -2.5)))
        path.line(to: NSPoint(x: mid, y: y + (up ? -2.5 : 2.5)))
        path.line(to: NSPoint(x: mid + 5, y: y + (up ? 2.5 : -2.5)))
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        (hot ? Ink.accent : Ink.secondary).setStroke()
        path.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        if earlier != nil { drawChevron(in: earlierRect, up: true, hot: hoveredEnd == true) }
        if later != nil { drawChevron(in: laterRect, up: false, hot: hoveredEnd == false) }
        let top = position(visible.minY)
        let bottom = position(visible.maxY)
        for (i, item) in placed.enumerated() {
            let length: CGFloat = item.mark.rank == 3 ? Self.dayLength : item.mark.rank == 2 ? 13 : 7
            let near = item.y >= top - 2 && item.y <= bottom + 2
            let color = i == hovered ? Ink.accent
                : item.mark.isWeek ? (near ? Ink.week : Ink.week.withAlphaComponent(0.45))
                : near ? Ink.text : Ink.faint
            color.setFill()
            let grow: CGFloat = i == hovered ? 4 : 0
            let thickness: CGFloat = item.mark.rank == 3 ? 2 : 1.5
            NSBezierPath(roundedRect: NSRect(x: Self.tickX, y: item.y - thickness / 2, width: length + grow, height: thickness),
                         xRadius: thickness / 2, yRadius: thickness / 2).fill()
        }
    }

    private func nearest(_ y: CGFloat) -> Int? {
        let best = placed.enumerated().min { abs($0.element.y - y) < abs($1.element.y - y) }
        guard let best, abs(best.element.y - y) <= 8 else { return nil }
        return best.offset
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    /// The end the pointer is on: true for the earlier.
    private var hoveredEnd: Bool? { didSet { if hoveredEnd != oldValue { needsDisplay = true } } }

    private func end(at point: NSPoint) -> Bool? {
        if earlier != nil, earlierRect.insetBy(dx: -4, dy: -4).contains(point) { return true }
        if later != nil, laterRect.insetBy(dx: -4, dy: -4).contains(point) { return false }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredEnd = end(at: point)
        if let isEarlier = hoveredEnd, let name = isEarlier ? earlier : later {
            hovered = nil
            onHover?(ScrubMark(y: 0, title: isEarlier ? "Earlier" : "Later", detail: name, rank: 3),
                     isEarlier ? earlierRect.midY : laterRect.midY)
            return
        }
        let y = point.y
        let index = nearest(y)
        if index != hovered {
            hovered = index
            needsDisplay = true
        }
        onHover?(index.map { placed[$0].mark }, index.map { placed[$0].y } ?? y)
    }

    func hover(atFraction fraction: CGFloat) {
        let y = Self.pad + fraction * (bounds.height - 2 * Self.pad)
        hovered = placed.enumerated().min { abs($0.element.y - y) < abs($1.element.y - y) }?.offset
        needsDisplay = true
        onHover?(hovered.map { placed[$0].mark }, hovered.map { placed[$0].y } ?? y)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        hoveredEnd = nil
        needsDisplay = true
        onHover?(nil, 0)
    }

    override func mouseDown(with event: NSEvent) { dragged = false }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        let y = convert(event.locationInWindow, from: nil).y
        onDrag?(min(1, max(0, (y - Self.pad) / max(1, bounds.height - 2 * Self.pad))))
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragged else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let isEarlier = end(at: point) {
            onPage?(isEarlier)
            return
        }
        let y = point.y
        if let index = nearest(y) { onPick?(placed[index].mark) }
    }
}

/// What a hovered tick is: its words, and the day it is in.
final class ScrubTip: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            return shadow
        }()
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ mark: ScrubMark, face: Typeface) {
        let text = NSMutableAttributedString(string: mark.title, attributes: [
            .font: face.font(size: 13, weight: mark.rank == 3 ? .semibold : .regular),
            .foregroundColor: mark.isWeek ? Ink.week : Ink.text,
        ])
        if let detail = mark.detail {
            text.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: face.font(size: 12), .foregroundColor: Ink.secondary,
            ]))
        }
        label.attributedStringValue = text
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Ink.paper.cgColor
            layer?.borderColor = Ink.rule.cgColor
        }
        needsLayout = true
    }

    override var fittingSize: NSSize {
        let size = label.attributedStringValue.size()
        return NSSize(width: min(420, ceil(size.width) + 24), height: ceil(size.height) + 10)
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 10, y: floor((bounds.height - size.height) / 2), width: bounds.width - 20, height: size.height)
    }
}

/// The top of a column, where the text goes under the title bar: the paper
/// fading in over it, so what is pinned there stays legible.
final class TopFade: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [Ink.paper, Ink.paper, Ink.paper.withAlphaComponent(0)],
                   atLocations: [0, 0.55, 1], colorSpace: .sRGB)?.draw(in: bounds, angle: -90)
    }
}

/// A column's ×, or an inbox note's: faint until the pointer is on it.
final class CloseButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }

    init(toolTip: String = "Close Column") {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = Ink.faint
        self.toolTip = toolTip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; contentTintColor = Ink.text }
    override func mouseExited(with event: NSEvent) { hovering = false; contentTintColor = Ink.faint }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Ink.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

/// Over a note's header among many: the pointer a hand, a click the note
/// alone.
final class NoteHeaderLink: NSView {
    var onClick: ((_ newColumn: Bool) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?(event.modifierFlags.contains(.command))
    }
}
