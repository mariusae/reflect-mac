import AppKit
import ReflectCore
import ReflectUI
import PrismCore

/// A note, where it is read and written: the note, then what links to it,
/// the whole height of the pane — over its top, floating on glass, back and
/// forward, its name, what links to it and its menu, out of the way while
/// it is read down or typed in. A day's note has two faces: the note as
/// written, or its hours, its time blocks down them.
final class NotePane: NSView, OutlineTextViewNavigator {
    let session: Session
    private(set) var history: PaneHistory
    var place: PanePlace { history.current }
    var ref: NoteRef { place.ref }

    /// Clicked or typed in: the pane worked in.
    var onActivate: ((NotePane) -> Void)?
    /// Somewhere else, or another face: the window's list and state caught up.
    var onMoved: ((NotePane) -> Void)?
    /// A link followed, or a note named: `beside`, in the other pane.
    var onOpenURL: ((URL, NotePane, _ beside: Bool) -> Void)?
    var onOpenPath: ((String, NotePane, _ beside: Bool) -> Void)?
    /// Its × clicked: closed, the other pane left.
    var onClose: ((NotePane) -> Void)?
    /// Its name clicked, or ⌘K: the way to go anywhere, dropped from the name.
    var onGoTo: ((NotePane, NSView) -> Void)?
    /// Notes to review, or the sync failed: its warning clicked.
    var onStatus: ((NSView) -> Void)?

    private let chrome = PaneChrome()
    /// Under the floating controls, once anything has gone up under them: the page fading out.
    private let edge = EdgeFade()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private var blocks: [ColumnBlock] = []
    private(set) var note: DayView?
    /// The hours, for a day's schedule.
    private var schedule: TimeBlocksPage?
    private var linkedHeader: InlineBacklinksHeader?
    private var linked: [BacklinkBlock] = []
    /// What links here, as last shown: not shown again unchanged.
    private var shownSources: [BacklinkSource]?
    /// What links here changed while typed in there: shown once the keyboard leaves.
    private var linkedStale = false

    override var isFlipped: Bool { true }

    var isActive = false
    /// Room at the left of the controls: the window's buttons, over this pane.
    var leading: CGFloat = 0 { didSet { if leading != oldValue { chrome.leading = leading } } }
    /// Something to look at — notes to review, a sync gone wrong — said by a warning.
    var status: String? { didSet { if status != oldValue { chrome.status = status } } }
    /// Beside another pane, on its right: a rule between them.
    var ruledLeft = false { didSet { leftRule.isHidden = !ruledLeft } }
    private let leftRule = RuleView()
    var closable = false { didSet { chrome.closable = closable } }

    init(session: Session, place: PanePlace) {
        self.session = session
        history = PaneHistory(place)
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
        addSubview(scroll)
        edge.isHidden = true
        addSubview(edge)
        addSubview(chrome)
        leftRule.isHidden = true
        addSubview(leftRule)
        chrome.onBack = { [weak self] in self?.goBack() }
        chrome.onForward = { [weak self] in self?.goForward() }
        chrome.onFace = { [weak self] face in self?.setFace(face) }
        chrome.onLinked = { [weak self] in self?.scrollToLinked() }
        chrome.onMenu = { [weak self] button in self?.showMenu(from: button) }
        chrome.onClose = { [weak self] in
            guard let self else { return }
            onClose?(self)
        }
        chrome.onTitle = { [weak self] view in
            guard let self else { return }
            onActivate?(self)
            onGoTo?(self, view)
        }
        chrome.onStep = { [weak self] by in self?.stepDay(by) }
        chrome.onMonth = { [weak self] view in self?.showMonth(from: view) }
        chrome.onStatus = { [weak self] view in self?.onStatus?(view) }
        NotificationCenter.default.addObserver(self, selector: #selector(typed(_:)), name: NSText.didChangeNotification, object: nil)
        show()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Where it is

    /// Somewhere new, with a way back.
    func go(_ place: PanePlace) {
        guard place != history.current else { return focusNote() }
        saveScroll()
        history.go(place)
        show()
        onMoved?(self)
    }

    /// Where it is changed in place — another day of the week, another face — no way back to it.
    func replace(_ place: PanePlace) {
        guard place != history.current else { return }
        saveScroll()
        history.replace(place)
        show()
        onMoved?(self)
    }

    func goBack() {
        saveScroll()
        guard history.goBack() != nil else { return NSSound.beep() }
        show()
        onMoved?(self)
    }

    func goForward() {
        saveScroll()
        guard history.goForward() != nil else { return NSSound.beep() }
        show()
        onMoved?(self)
    }

    /// A day's face: its note, or its hours.
    func setFace(_ face: DayFace) {
        guard ref.day != nil else { return }
        replace(PanePlace(path: place.path, face: face))
    }

    /// A day before or after, in place.
    func stepDay(_ by: Int) {
        guard let day = ref.day ?? GraphPaths.week(fromWeeklyPath: place.path)?.monday else { return NSSound.beep() }
        replace(PanePlace(.day(day.adding(by)), face: place.face))
    }

    /// History put back as it was left.
    func restore(_ history: PaneHistory) {
        self.history = history
        show()
    }

    // MARK: Shown

    private func show() {
        let ref = ref
        let face = ref.day != nil ? place.face : .outline
        // The note kept when it is the one shown still.
        if let note, note.ref != ref || face == .schedule { letGo(note) }
        blocks.forEach { if !($0 is DayView) { $0.removeFromSuperview() } }
        blocks = []
        linked = []
        linkedHeader = nil
        shownSources = nil
        let week = GraphPaths.week(fromWeeklyPath: ref.path)
        if face == .schedule, let day = ref.day {
            let page = schedule ?? makeSchedule(day)
            schedule = page
            page.show(day)
            document.addSubview(page.block)
            blocks = [page.block]
        } else {
            let view = note ?? makeView(ref)
            view.standsAlone = ref.day != nil || week != nil
            note = view
            blocks = [view]
            showLinked(session.backlinks(to: ref.path) { [weak self] sources in
                guard let self, self.ref.path == ref.path else { return }
                self.showLinked(sources)
            })
        }
        updateBar()
        needsLayout = true
        layoutSubtreeIfNeeded()
        relayout()
        if face == .schedule {
            schedule?.scrollToWork()
        } else {
            let offset = SessionState.shared.place(session.graph.root, ref)?.offset ?? 0
            scroll(toY: CGFloat(offset), animated: false)
        }
        if isActive { focusNote() }
    }

    /// The keyboard in the note, where its caret was.
    func focusNote() {
        guard let note, window != nil else {
            if let schedule { window?.makeFirstResponder(schedule.block.grid) }
            return
        }
        window?.makeFirstResponder(note.editor)
        if !note.restoreSelection() { note.editor.enter(from: .top, x: 0, scrolling: false) }
    }

    private func makeView(_ ref: NoteRef) -> DayView {
        let view = DayView(ref: ref, graph: session.graph, images: session.images, metrics: session.metrics)
        view.drawsRule = false
        view.editor.navigator = self
        view.onHeightChange = { [weak self] _ in self?.setNeedsRelayout() }
        view.onSave = { [weak self, weak view] in
            guard let view else { return }
            self?.session.noteSaved(view)
        }
        document.addSubview(view)
        session.noteShown(view)
        return view
    }

    private func letGo(_ view: DayView) {
        view.save()
        view.removeFromSuperview()
        session.noteLeft(view)
        note = nil
    }

    private func makeSchedule(_ day: Day) -> TimeBlocksPage {
        let store = TimeBlocksPage.Store(
            flush: { [weak self] in self?.session.save() },
            read: { [weak self] path in self?.session.graph.read(path: path) },
            write: { [weak self] writes in self?.session.write(writes) },
            openNote: { [weak self] path in
                guard let self else { return }
                onOpenPath?(path, self, true)
            })
        let page = TimeBlocksPage(store: store, day: day, typography: session.face.typography())
        page.onScrollTo = { [weak self] y in self?.scroll(toY: y + 12, animated: false) }
        return page
    }

    private func updateBar() {
        let ref = ref
        let (title, detail) = Self.name(of: ref, session: session)
        chrome.show(title: title, detail: detail, metrics: session.metrics)
        chrome.canGoBack = history.canGoBack
        chrome.canGoForward = history.canGoForward
        chrome.isDay = ref.day != nil || GraphPaths.week(fromWeeklyPath: ref.path) != nil
        chrome.face = ref.day != nil ? place.face : nil
        chrome.linkedCount = place.face == .schedule && ref.day != nil ? nil : shownSources?.count
        setTucked(false)
        needsLayout = true
    }

    /// What the bar calls a note: a day as people say it, its date beside;
    /// a week by its days; any other note its title, and how long ago.
    static func name(of ref: NoteRef, session: Session) -> (String, String?) {
        if let week = GraphPaths.week(fromWeeklyPath: ref.path) { return ("Week \(week.week)", OpenQuickly.weekRange(week)) }
        guard let day = ref.day, let date = day.date else {
            let entry = session.index.entry(ref.path)
            return (session.name(of: ref.path).title, entry.map { CardSurface.ago($0.modified) })
        }
        let today = Day.today
        func format(_ template: String) -> String {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: date)
        }
        let near = (today.adding(-6)...today.adding(6)).contains(day)
        let name = day == today ? "Today" : day == today.adding(-1) ? "Yesterday" : day == today.adding(1) ? "Tomorrow"
            : format(near ? "EEEE" : day.year == today.year ? "MMMMd" : "MMMMdyyyy")
        return (name, format(day.year == today.year ? "EEEEMMMMd" : "EEEEMMMMdyyyy"))
    }

    // MARK: What links here

    private func showLinked(_ sources: [BacklinkSource]?) {
        guard place.face == .outline || ref.day == nil, let note else { return }
        if sources == shownSources, !linked.isEmpty || sources?.isEmpty != false { return }
        // Not while typed in there: once the keyboard leaves.
        if isTypingInLinked {
            linkedStale = true
            return
        }
        linked.forEach { $0.removeFromSuperview() }
        linkedHeader?.removeFromSuperview()
        linked = []
        linkedHeader = nil
        shownSources = sources
        var blocks: [ColumnBlock] = [note]
        if let sources, !sources.isEmpty {
            let header = InlineBacklinksHeader(count: sources.count, metrics: session.metrics)
            document.addSubview(header)
            linkedHeader = header
            linked = sources.map(makeLinked)
            blocks += [header] + linked
        }
        self.blocks = blocks
        updateBar()
        relayout()
    }

    private func makeLinked(_ source: BacklinkSource) -> BacklinkBlock {
        let root = session.graph.root
        let name = session.name(of: source.path)
        let text = session.graph.read(path: source.path) ?? ""
        let slices = TaskSlice.slices(holding: source.contexts.map(\.link), path: source.path, in: text)
        let block = BacklinkBlock(path: source.path, slices: slices, editable: OutlineMarkdown.roundTrips(text),
                                  name: name.title, detail: name.detail,
                                  folded: SessionState.shared.backlinkFolded(root, to: ref.path, from: source.path),
                                  metrics: session.metrics, face: session.face, images: session.images, navigator: self)
        for editor in block.editors {
            editor.onEdit = { [weak self] editor in self?.writeBack(editor) }
            editor.onResize = { [weak self] in self?.relayout() }
            editor.view.onRestyle = { [weak self] in self?.relayout() }
            editor.onLeave = { [weak self] in
                guard let self, linkedStale else { return }
                linkedStale = false
                showLinked(session.backlinks(to: ref.path) { [weak self] in self?.showLinked($0) })
            }
        }
        let target = ref.path
        block.onFold = { [weak self] folded in
            SessionState.shared.setBacklinkFolded(root, to: target, from: source.path, folded)
            self?.relayout()
        }
        block.onOpen = { [weak self] beside in
            guard let self else { return }
            onOpenPath?(source.path, self, beside)
        }
        document.addSubview(block)
        return block
    }

    private var isTypingInLinked: Bool {
        guard let editor = window?.firstResponder as? OutlineTextView else { return false }
        return linked.contains { $0.editors.contains { $0.view === editor } }
    }

    /// A place a note links here from, edited here: written back into that note.
    private func writeBack(_ editor: TaskEditor) {
        let path = editor.slice.path
        guard let source = session.graph.read(path: path) else { return }
        let rows = editor.rowsInNote
        guard let updated = editor.slice.writing(rows, into: source) else { return }
        do {
            try session.graph.write(updated, path: path)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        session.index.refresh(path)
        let delta = rows.count - editor.slice.count
        editor.slice.count = rows.count
        for other in linked.flatMap(\.editors) where other !== editor && other.slice.path == path && other.slice.start > editor.slice.start {
            other.slice.start += delta
        }
        relayout()
    }

    private func scrollToLinked() {
        guard let linkedHeader else { return }
        scroll(toY: linkedHeader.frame.minY, animated: true)
    }

    // MARK: Changes from elsewhere

    /// Notes changed on disk: those shown, as they now are.
    func notesChanged(_ paths: Set<String>) {
        if let note, paths.contains(note.ref.path) { note.reloadIfChanged() }
        if let schedule { schedule.reload() }
        showLinked(session.backlinks(to: ref.path) { [weak self] in self?.showLinked($0) })
        updateBar()
        relayout()
    }

    func tick() { schedule?.tick() }

    func typographyChanged() {
        note?.metrics = session.metrics
        schedule?.setTypography(session.face.typography())
        let sources = shownSources
        shownSources = nil
        showLinked(sources)
        updateBar()
        relayout()
    }

    func saveNotes() {
        note?.save()
        saveScroll()
    }

    func noteMoved(from old: String, to new: String) {
        history.rename(old, to: new)
        guard note?.ref.path == old else { return updateBar() }
        let selection = note?.editor.selectedRange()
        let typing = note.map { window?.firstResponder === $0.editor } ?? false
        if let note { letGo(note) }
        show()
        if let editor = note?.editor, let selection {
            if typing { window?.makeFirstResponder(editor) }
            editor.setSelectedRange(NSRange(location: min(selection.location, (editor.string as NSString).length), length: 0))
        }
        onMoved?(self)
    }

    func discard(_ path: String) {
        if note?.ref.path == path { note?.discard() }
    }

    /// A note gone to the Trash: back from it, or to today.
    func noteTrashed(_ path: String) {
        history.forget(path)
        guard place.path == path else { return updateBar() }
        note?.removeFromSuperview()
        note = nil
        if history.canGoBack {
            history.goBack()
            history.forget(path)
        } else {
            history = PaneHistory(PanePlace(.day(.today)))
        }
        show()
        onMoved?(self)
    }

    // MARK: Its menu

    private func showMenu(from button: NSView) {
        onActivate?(self)
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Note" })?.submenu?.copy() as? NSMenu else { return }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Sync Now", action: #selector(PrismWindow.syncNow(_:)), keyEquivalent: ""))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private var monthPopover: NSPopover?

    /// A day's ⌄: its month, a day chosen gone to — in place, its face kept.
    private func showMonth(from view: NSView) {
        onActivate?(self)
        monthPopover?.close()
        let shown = ref.day ?? GraphPaths.week(fromWeeklyPath: place.path)?.monday ?? .today
        let calendar = CalendarView(month: NoteCalendar.Month(shown), marks: NoteCalendar.marks(graph: session.graph, index: session.index),
                                    weeks: NoteCalendar.weeksWithNotes(index: session.index), face: session.face)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = CalendarView.size
        let controller = NSViewController()
        controller.view = calendar
        popover.contentViewController = controller
        calendar.onChoose = { [weak self, weak popover] day in
            popover?.close()
            guard let self else { return }
            replace(PanePlace(.day(day), face: place.face))
        }
        calendar.onChooseWeek = { [weak self, weak popover] week in
            popover?.close()
            self?.go(PanePlace(path: GraphPaths.weeklyPath(for: week)))
        }
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        monthPopover = popover
    }

    /// Where ⌘K drops from: the name's capsule.
    var titleAnchor: NSView { chrome.titleCapsule }

    // MARK: Out of the way

    private var lastScrollY: CGFloat = 0
    private var travel: CGFloat = 0

    /// The floating controls tucked away — read down, typed in — or back.
    private func setTucked(_ tucked: Bool) {
        chrome.setTucked(tucked)
        edge.isHidden = scroll.contentView.bounds.minY <= 2 || tucked
    }

    /// Typed in: the controls out of the way of the writing.
    @objc private func typed(_ note: Notification) {
        guard let view = note.object as? NSView, view.isDescendant(of: self) else { return }
        setTucked(true)
    }

    /// The pointer moved: up to the pane's top, the controls back.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if chrome.isTucked, convert(event.locationInWindow, from: nil).y < PaneChrome.height + 16 { setTucked(false) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        // The page the whole height: the controls float over its top.
        chrome.frame = NSRect(x: 0, y: 0, width: bounds.width, height: PaneChrome.height)
        edge.frame = NSRect(x: 0, y: 0, width: bounds.width, height: PaneChrome.height + 18)
        scroll.frame = bounds
        leftRule.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height)
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

    /// The blocks one under another, the one at the top kept where it is.
    func relayout() {
        let width = scroll.contentSize.width
        guard width > 0 else { return }
        // Under the floating controls, to begin with.
        var y: CGFloat = PaneChrome.height - 8
        for block in blocks {
            let height = block.desiredHeight(width: width)
            let frame = NSRect(x: 0, y: y, width: width, height: height)
            if block.frame != frame { block.frame = frame }
            y += height
        }
        y += 160
        let size = NSSize(width: width, height: max(y, scroll.contentSize.height))
        if document.frame.size != size { document.setFrameSize(size) }
    }

    func scroll(toY y: CGFloat, animated: Bool) {
        let target = NSPoint(x: 0, y: max(0, min(y, document.frame.height - scroll.contentSize.height)))
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                scroll.contentView.animator().setBoundsOrigin(target)
            }
        } else {
            scroll.contentView.scroll(to: target)
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Read down: the controls tucked away; read back up, or at the top, back.
    @objc private func scrolled() {
        let y = scroll.contentView.bounds.minY
        let delta = y - lastScrollY
        lastScrollY = y
        if y <= 2 {
            travel = 0
            return setTucked(false)
        }
        travel = (delta > 0) == (travel > 0) ? travel + delta : delta
        if travel > 24 { setTucked(true) } else if travel < -12 { setTucked(false) } else { edge.isHidden = chrome.isTucked }
    }

    private func saveScroll() {
        guard place.face == .outline || ref.day == nil else { return }
        SessionState.shared.setOffset(session.graph.root, ref, Double(scroll.contentView.bounds.minY))
    }

    /// Whether a note is shown here.
    func shows(_ ref: NoteRef) -> Bool { note?.ref == ref }

    override func mouseDown(with event: NSEvent) {
        onActivate?(self)
        super.mouseDown(with: event)
    }

    // MARK: OutlineTextViewNavigator

    func outlineView(_ view: OutlineTextView, leaveThrough edge: OutlineTextView.Edge, x: CGFloat) {
        view.enter(from: edge, x: edge == .top ? 0 : .greatestFiniteMagnitude)
    }

    func outlineView(_ view: OutlineTextView, open url: URL, inSplit: Bool) {
        onOpenURL?(url, self, inSplit)
    }

    // MARK: Scripts

    var scheduleForScript: TimeBlocksPage? { schedule }
}

/// A pane's controls, floating on glass over its top: at the left, back and
/// forward; in the middle, what is shown — clicked, the way to go anywhere,
/// a day's ‹ › and ⌄ about it; at the right, a day's faces, what links
/// here, a warning when there is something to look at, the note's menu,
/// and, beside another pane, its ×. Tucked away, they are not there to the
/// pointer.
final class PaneChrome: NSView {
    /// The row they float in, at the pane's top.
    static let height: CGFloat = 2 * PrismWindow.barMiddle
    private static let capsule: CGFloat = 34

    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onFace: ((DayFace) -> Void)?
    var onLinked: (() -> Void)?
    var onMenu: ((NSView) -> Void)?
    var onClose: (() -> Void)?
    var onTitle: ((NSView) -> Void)?
    var onStep: ((Int) -> Void)?
    var onMonth: ((NSView) -> Void)?
    var onStatus: ((NSView) -> Void)?

    private let left = GlassCapsule()
    private let middle = GlassCapsule()
    var titleCapsule: NSView { middle }
    private let right = GlassCapsule()
    private let back = CloseButton(symbol: "chevron.left", pointSize: 13, toolTip: "Back (⌘[)")
    private let forward = CloseButton(symbol: "chevron.right", pointSize: 13, toolTip: "Forward (⌘])")
    private let title = TitleLabel()
    private let earlier = CloseButton(symbol: "chevron.left", pointSize: 10, toolTip: "The Day Before (⌃⌘←)")
    private let later = CloseButton(symbol: "chevron.right", pointSize: 10, toolTip: "The Day After (⌃⌘→)")
    private let month = CloseButton(symbol: "chevron.down", pointSize: 10, toolTip: "The Month")
    private let faces = NSSegmentedControl(images: [
        NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "Outline")!,
        NSImage(systemSymbolName: "calendar.day.timeline.left", accessibilityDescription: "Schedule")!,
    ], trackingMode: .selectOne, target: nil, action: nil)
    private let linked = NSButton()
    private let warning = CloseButton(symbol: "exclamationmark.triangle.fill", pointSize: 12, toolTip: "")
    private let menuButton = CloseButton(symbol: "ellipsis", pointSize: 13, toolTip: "This Note")
    private let close = CloseButton(symbol: "xmark", pointSize: 11, toolTip: "Close This Pane (⌘W)")
    private(set) var isTucked = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// Room at the left: the window's buttons.
    var leading: CGFloat = 0 { didSet { needsLayout = true } }
    var canGoBack = false { didSet { back.isEnabled = canGoBack; needsLayout = true } }
    var canGoForward = false { didSet { needsLayout = true } }
    var closable = false { didSet { needsLayout = true } }
    /// A day, or a week: stepped through, a month to pick from.
    var isDay = false { didSet { needsLayout = true } }
    var face: DayFace? {
        didSet {
            faces.selectedSegment = face == .schedule ? 1 : 0
            needsLayout = true
        }
    }
    var linkedCount: Int? {
        didSet {
            linked.title = linkedCount.map { "\($0)" } ?? ""
            styleLinked()
            needsLayout = true
        }
    }
    var status: String? {
        didSet {
            warning.toolTip = status
            needsLayout = true
        }
    }
    private var metrics: OutlineMetrics?

    init() {
        super.init(frame: .zero)
        for capsule in [left, middle, right] { addSubview(capsule) }
        for (button, action) in [(back, #selector(backClicked)), (forward, #selector(forwardClicked)), (earlier, #selector(earlierClicked)),
                                 (later, #selector(laterClicked)), (month, #selector(monthClicked)), (menuButton, #selector(menuClicked)),
                                 (close, #selector(closeClicked)), (warning, #selector(warningClicked))] {
            button.contentTintColor = Ink.text
            button.target = self
            button.action = action
        }
        warning.contentTintColor = .systemOrange
        left.content.addSubview(back)
        left.content.addSubview(forward)
        title.onClick = { [weak self] in
            guard let self else { return }
            onTitle?(middle)
        }
        for view in [earlier, title, later, month] as [NSView] { middle.content.addSubview(view) }
        faces.segmentStyle = .automatic
        faces.controlSize = .small
        faces.target = self
        faces.action = #selector(faceChosen)
        faces.setToolTip("The day as written (⌥⌘O)", forSegment: 0)
        faces.setToolTip("The day's hours (⌥⌘S)", forSegment: 1)
        linked.isBordered = false
        linked.target = self
        linked.action = #selector(linkedClicked)
        linked.image = NSImage(systemSymbolName: "arrow.turn.up.left", accessibilityDescription: "Linked from")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        linked.imagePosition = .imageLeading
        linked.contentTintColor = Ink.text
        linked.toolTip = "What links here"
        for view in [faces, linked, warning, menuButton, close] as [NSView] { right.content.addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(title text: String, detail when: String?, metrics: OutlineMetrics) {
        self.metrics = metrics
        title.show(title: text, detail: when, metrics: metrics)
        styleLinked()
        needsLayout = true
    }

    private func styleLinked() {
        guard let metrics else { return }
        let typography = metrics.typography
        linked.attributedTitle = NSAttributedString(string: linked.title, attributes: [
            .font: Typography.font(typography.bodyFamily, face: typography.bodyFace, size: 13), .foregroundColor: Ink.text,
        ])
    }

    @objc private func backClicked() { onBack?() }
    @objc private func forwardClicked() { onForward?() }
    @objc private func earlierClicked() { onStep?(-1) }
    @objc private func laterClicked() { onStep?(1) }
    @objc private func monthClicked() { onMonth?(month) }
    @objc private func menuClicked() { onMenu?(menuButton) }
    @objc private func closeClicked() { onClose?() }
    @objc private func linkedClicked() { onLinked?() }
    @objc private func warningClicked() { onStatus?(warning) }
    @objc private func faceChosen() { onFace?(faces.selectedSegment == 1 ? .schedule : .outline) }

    /// Out of the way, read down into the page; back, read up.
    func setTucked(_ tucked: Bool) {
        guard tucked != isTucked else { return }
        isTucked = tucked
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            for capsule in [left, middle, right] { capsule.animator().alphaValue = tucked ? 0 : 1 }
        }
    }

    override func layout() {
        super.layout()
        let side = Self.capsule
        let y = ((Self.height - side) / 2).rounded()
        // At the left: back, and forward when there is a way forward.
        var x: CGFloat = 4
        back.frame = NSRect(x: x, y: 4, width: 28, height: side - 8)
        x = back.frame.maxX
        forward.isHidden = !canGoForward
        if canGoForward {
            forward.frame = NSRect(x: x, y: 4, width: 28, height: side - 8)
            x = forward.frame.maxX
        }
        left.frame = NSRect(x: max(12, leading), y: y, width: x + 4, height: side)
        // At the right, from the edge in: ×, ⋯, the warning, what links here, the faces.
        var widths: [(NSView, CGFloat)] = []
        if !faces.isHidden { faces.sizeToFit() }
        faces.isHidden = face == nil
        if !faces.isHidden { widths.append((faces, faces.frame.width + 6)) }
        linked.isHidden = (linkedCount ?? 0) == 0
        if !linked.isHidden {
            linked.sizeToFit()
            widths.append((linked, linked.frame.width + 8))
        }
        warning.isHidden = status == nil
        if !warning.isHidden { widths.append((warning, 28)) }
        widths.append((menuButton, 28))
        close.isHidden = !closable
        if closable { widths.append((close, 26)) }
        var rx: CGFloat = 4
        for (view, width) in widths {
            let height = view === faces ? faces.frame.height : side - 8
            view.frame = NSRect(x: rx + (view === faces ? 2 : 0), y: ((side - height) / 2).rounded(), width: width - (view === faces ? 6 : 0), height: height)
            rx += width
        }
        right.frame = NSRect(x: bounds.width - 12 - (rx + 4), y: y, width: rx + 4, height: side)
        // In the middle — of the pane, as far as the others leave room — what is shown.
        let room = right.frame.minX - 10 - (left.frame.maxX + 10)
        let arrows: CGFloat = isDay ? 22 : 0
        let want = title.fittingWidth + 28 + 2 * arrows + (isDay ? 22 : 0)
        let width = max(0, min(want, room, 460))
        middle.isHidden = width < 90
        var mx = min(max(left.frame.maxX + 10, ((bounds.width - width) / 2).rounded()), right.frame.minX - 10 - width)
        mx = max(mx, left.frame.maxX + 10)
        middle.frame = NSRect(x: mx, y: y, width: width, height: side)
        earlier.isHidden = !isDay
        later.isHidden = !isDay
        month.isHidden = !isDay
        var tx: CGFloat = 8
        if isDay {
            earlier.frame = NSRect(x: 6, y: 6, width: 20, height: side - 12)
            tx = earlier.frame.maxX + 2
        }
        let trail: CGFloat = isDay ? 6 + 20 + 2 + 20 : 8
        title.frame = NSRect(x: tx, y: 0, width: max(0, width - tx - trail), height: side)
        if isDay {
            later.frame = NSRect(x: title.frame.maxX + 2, y: 6, width: 20, height: side - 12)
            month.frame = NSRect(x: later.frame.maxX + 2, y: 6, width: 20, height: side - 12)
        }
    }

    /// Only the capsules are its own, to the pointer — none, tucked away.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isTucked else { return nil }
        let local = convert(point, from: superview)
        guard [left, middle, right].contains(where: { !$0.isHidden && $0.frame.contains(local) }) else { return nil }
        return super.hitTest(point)
    }
}

/// A capsule of glass, what it holds over it.
final class GlassCapsule: NSView {
    private let glass = NSGlassEffectView()
    let content = FlippedView()
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: .zero)
        addSubview(glass)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        glass.frame = bounds
        glass.cornerRadius = bounds.height / 2
        content.frame = bounds
    }
}

/// What a pane shows, named in its middle capsule: the name, and — a day's
/// date, a note's age — after it. Clicked: the way to go anywhere.
final class TitleLabel: NSView {
    var onClick: (() -> Void)?
    private var name = NSAttributedString()
    private var detail = NSAttributedString()

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func show(title: String, detail when: String?, metrics: OutlineMetrics) {
        let typography = metrics.typography
        name = NSAttributedString(string: title, attributes: [
            .font: typography.headingFont(size: 14, weight: .bold), .foregroundColor: Ink.text,
        ])
        detail = NSAttributedString(string: when.map { "  " + $0 } ?? "", attributes: [
            .font: Typography.font(typography.bodyFamily, face: typography.bodyFace, size: 12.5), .foregroundColor: Ink.secondary,
        ])
        toolTip = "Go to… (⌘K)"
        needsDisplay = true
    }

    var fittingWidth: CGFloat { ceil(name.size().width + detail.size().width) }

    override func draw(_ dirtyRect: NSRect) {
        let right = bounds.width
        let whole = NSMutableAttributedString(attributedString: name)
        whole.append(detail)
        let height = whole.size().height
        let width = min(ceil(whole.size().width), right - 8)
        let x = max(0, ((right - width) / 2).rounded())
        whole.draw(with: NSRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: width, height: height),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }
}

/// The page fading out under the floating controls, once anything has
/// gone up under them: so they read over it.
final class EdgeFade: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [Ink.paper, Ink.paper.withAlphaComponent(0.85), Ink.paper.withAlphaComponent(0)],
                   atLocations: [0, 0.55, 1], colorSpace: .sRGB)?.draw(in: bounds, angle: 90)
    }
}

/// A hairline, in the rule's ink.
final class RuleView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Ink.rule.setFill()
        bounds.fill()
    }
}
