import AppKit
import ReflectCore

/// Every day, one after another, oldest at the top: the daily notes as one
/// long page, which grows at either end as it is scrolled.
///
/// Only the days on screen, and a screen's worth either side, are views; the
/// rest are heights, measured once seen and guessed before. Whatever a
/// change of height does to the days above, the day at the top of the
/// window stays where it is.
@MainActor
final class TimelineViewController: NSViewController, OutlineTextViewNavigator {
    let graph: Graph
    /// The pictures of every day, loaded once for all of them.
    let images: ImageStore
    var metrics: OutlineMetrics {
        didSet {
            measured = [:]
            for view in views.values { view.metrics = metrics }
            relayout()
        }
    }
    /// Told when a note is written.
    var onSave: (() -> Void)?

    private var first: Day
    private var last: Day
    private var noteLines: [Day: Int] = [:]
    private var measured: [Day: CGFloat] = [:]
    /// The top of each day, and the end of the last.
    private var offsets: [CGFloat] = []
    private var views: [Day: DayView] = [:]
    private let scrollView = NSScrollView()
    private let document = FlippedView()
    private var tiling = false
    private var lastWidth: CGFloat = 0

    /// How many days are added at an end the scroll comes near.
    private static let growth = 120

    init(graph: Graph, metrics: OutlineMetrics) {
        self.graph = graph
        images = ImageStore(root: graph.root)
        self.metrics = metrics
        let today = Day.today
        first = today.adding(-Self.growth)
        last = today.adding(Self.growth / 2)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = document
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        view = scrollView
        NotificationCenter.default.addObserver(self, selector: #selector(dayChanged(_:)),
                                               name: .NSCalendarDayChanged, object: nil)
        noteLines = graph.dailyNotes()
        recomputeOffsets()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentView.bounds.width
        if abs(width - lastWidth) > 0.5 {
            lastWidth = width
            measured = [:]
            relayout()
        }
    }

    // MARK: Days

    private var count: Int { offsets.count - 1 }

    private func index(of day: Day) -> Int {
        guard let from = first.date, let to = day.date else { return 0 }
        return Int((to.timeIntervalSince(from) / 86_400).rounded())
    }

    private func day(at index: Int) -> Day { first.adding(index) }

    /// The day at a height in the document.
    private func index(atY y: CGFloat) -> Int {
        var low = 0, high = count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if offsets[middle] <= y { low = middle } else { high = middle - 1 }
        }
        return max(0, low)
    }

    private func height(of day: Day) -> CGFloat {
        if let height = measured[day] { return height }
        let lines = CGFloat(max(noteLines[day] ?? 1, 1))
        let guess = metrics.fontSize * 5.4 + lines * metrics.fontSize * 1.62
        return max(guess, minimumHeight(of: day))
    }

    /// Today leaves room below it, so it can sit at the top of the window
    /// with space to write.
    private func minimumHeight(of day: Day) -> CGFloat {
        day == Day.today ? round(scrollView.documentVisibleRect.height * 0.6) : 0
    }

    private func recomputeOffsets() {
        let days = index(of: last) + 1
        var offsets = [CGFloat](repeating: 0, count: days + 1)
        var y: CGFloat = 0
        for index in 0..<days {
            offsets[index] = y
            y += height(of: day(at: index))
        }
        offsets[days] = y
        self.offsets = offsets
        let width = scrollView.contentView.bounds.width
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scrollView.contentView.bounds.height))
    }

    // MARK: Keeping the top still

    /// Makes a change that moves days up or down, keeping the day at the
    /// top of the window where it was.
    private func keepingTop(_ change: () -> Void) {
        let top = visibleTop
        // A point below the top: the clip view rounds its origin to the
        // pixel, which can leave the top a hair inside the day before.
        let anchor = count > 0 ? day(at: index(atY: top + 1)) : first
        let within = count > 0 ? top - offsets[index(of: anchor)] : 0
        change()
        recomputeOffsets()
        let index = index(of: anchor)
        guard index >= 0, index < count else { return }
        setVisibleTop(offsets[index] + within)
    }

    /// The top of what shows below the toolbar, which the scroll view runs
    /// under.
    private var visibleTop: CGFloat {
        scrollView.contentView.bounds.minY + scrollView.contentView.contentInsets.top
    }

    private func setVisibleTop(_ top: CGFloat) {
        let clip = scrollView.contentView
        let inset = clip.contentInsets.top
        let highest = max(-inset, document.frame.height - clip.bounds.height)
        let target = min(max(-inset, top - inset), highest)
        guard abs(target - clip.bounds.minY) > 0.5 else { return }
        clip.setBoundsOrigin(NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    private func relayout() {
        keepingTop {}
        tile()
    }

    /// At midnight, today is another day.
    @objc private func dayChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for view in views.values { view.updateTitle() }
            if Day.today > last { keepingTop { self.last = Day.today.adding(Self.growth) } }
            measured = [:]
            relayout()
        }
    }

    // MARK: Tiling

    @objc private func scrolled(_ notification: Notification) {
        tile()
        onScroll?()
    }

    /// Makes views for the days near the window, lets go of the rest, and
    /// grows the timeline when an end comes near.
    func tile() {
        guard !tiling, count > 0 else { return }
        tiling = true
        defer { tiling = false }

        let visible = scrollView.contentView.bounds
        let margin = max(visible.height, 400)
        if visible.minY < margin * 2 {
            keepingTop { first = first.adding(-Self.growth) }
        }
        if visible.maxY > offsets[count] - margin * 2 {
            keepingTop { last = last.adding(Self.growth) }
        }

        // Laying out a day can change its height, which moves the days
        // below it; a few passes settle it.
        for _ in 0..<4 {
            let visible = scrollView.contentView.bounds
            let range = index(atY: visible.minY - margin)...index(atY: visible.maxY + margin)
            var changed = false
            var keep = Set<Day>()
            for index in range {
                let day = day(at: index)
                keep.insert(day)
                let view = views[day] ?? makeView(for: day)
                let width = document.bounds.width
                view.minimumHeight = minimumHeight(of: day)
                let height = view.desiredHeight(width: width)
                if measured[day] != height {
                    measured[day] = height
                    changed = true
                }
            }
            if changed { keepingTop {} }
            for (day, view) in views where !keep.contains(day) {
                if let responder = view.window?.firstResponder as? NSView, responder.isDescendant(of: view) {
                    continue
                }
                view.save()
                view.removeFromSuperview()
                views[day] = nil
            }
            for (day, view) in views {
                let index = index(of: day)
                let frame = NSRect(x: 0, y: offsets[index], width: document.bounds.width, height: offsets[index + 1] - offsets[index])
                if view.frame != frame { view.frame = frame }
            }
            if !changed { break }
        }
    }

    private func makeView(for day: Day) -> DayView {
        let view = DayView(day: day, graph: graph, images: images, metrics: metrics)
        view.editor.navigator = self
        view.onHeightChange = { [weak self] view in self?.heightChanged(view) }
        view.onSave = { [weak self] in self?.onSave?() }
        views[day] = view
        document.addSubview(view)
        return view
    }

    private func heightChanged(_ view: DayView) {
        guard !tiling else { return }
        let height = view.desiredHeight(width: document.bounds.width)
        guard measured[view.day] != height else { return }
        keepingTop { measured[view.day] = height }
        tile()
    }

    // MARK: Where the app is

    /// Told when the window's place in the timeline moves.
    var onScroll: (() -> Void)?

    /// The day at the top of the window, and how far into it.
    var place: SessionState.Place {
        let index = index(atY: visibleTop + 1)
        return SessionState.Place(day: day(at: index).description, offset: Double(visibleTop - offsets[index]))
    }

    /// The day the keyboard is in, and what is selected there.
    var focusedSelection: SessionState.Focus? {
        guard let editor = view.window?.firstResponder as? OutlineTextView,
              let day = views.first(where: { $0.value.editor === editor })?.key else { return nil }
        let range = editor.selectedRange()
        return SessionState.Focus(day: day.description, location: range.location, length: range.length,
                                  rows: editor.selectedRows.map { _ in [editor.rowAnchor, editor.rowHead] })
    }

    /// Puts the window back where it was: the same day at the top, as far
    /// into it, and the caret where it was, wherever that is.
    func restore(_ place: SessionState.Place?, focus caret: SessionState.Focus?) {
        guard let place, let top = Day(place.day) else {
            focus(.today)
            return
        }
        scroll(to: top)
        for _ in 0..<3 {
            setVisibleTop(offsets[index(of: top)] + CGFloat(place.offset))
            tile()
        }
        guard let caret, let day = Day(caret.day), day >= first, day <= last else { return }
        // The keyboard's day need not be on screen; its view is made where
        // it is, and kept while it has the keyboard.
        let view = views[day] ?? makeView(for: day)
        tile()
        guard !view.hasConflict else { return }
        view.window?.makeFirstResponder(view.editor)
        view.editor.restoreSelection(location: caret.location, length: caret.length, rows: caret.rows)
    }

    // MARK: Going places

    /// Scrolls so that a day is at the top of the window.
    func scroll(to day: Day) {
        if day < first { keepingTop { first = day.adding(-Self.growth) } }
        if day > last { keepingTop { last = day.adding(Self.growth) } }
        // Days are guessed at until seen; settle the ones around the target
        // before landing on it.
        for _ in 0..<3 {
            setVisibleTop(offsets[index(of: day)])
            tile()
        }
    }

    /// The day's view, made if it is not on screen.
    func view(for day: Day) -> DayView {
        if let view = views[day] { return view }
        scroll(to: day)
        return views[day] ?? makeView(for: day)
    }

    /// Goes to a day, with its date at the top of the window, and puts the
    /// caret at the end of what is written there — or, when that is out of
    /// sight, at the start.
    func focus(_ day: Day) {
        scroll(to: day)
        let view = view(for: day)
        guard !view.hasConflict else { return }
        view.window?.makeFirstResponder(view.editor)
        view.editor.enter(from: .bottom, x: .greatestFiniteMagnitude, scrolling: false)
        let caret = view.editor.convert(view.editor.firstRectOfSelection, to: document)
        if !scrollView.contentView.bounds.contains(NSPoint(x: caret.minX, y: caret.maxY)) {
            view.editor.enter(from: .top, x: 0, scrolling: false)
        }
    }

    /// The day the keyboard is in, or else the one at the top of the window.
    var currentDay: Day {
        if let editor = view.window?.firstResponder as? OutlineTextView,
           let view = views.values.first(where: { $0.editor === editor }) {
            return view.day
        }
        return day(at: index(atY: visibleTop + 1))
    }

    @objc func goToToday(_ sender: Any?) { focus(.today) }
    @objc func goToPreviousDay(_ sender: Any?) { focus(currentDay.adding(-1)) }
    @objc func goToNextDay(_ sender: Any?) { focus(currentDay.adding(1)) }

    // MARK: OutlineTextViewNavigator

    func outlineView(_ view: OutlineTextView, leaveThrough edge: OutlineTextView.Edge, x: CGFloat) {
        guard let current = views.values.first(where: { $0.editor === view }) else { return }
        let next = current.day.adding(edge == .top ? -1 : 1)
        let target = views[next] ?? { () -> DayView in
            tile()
            return views[next] ?? makeView(for: next)
        }()
        target.window?.makeFirstResponder(target.editor)
        target.editor.enter(from: edge == .top ? .bottom : .top, x: x)
        if edge == .bottom {
            // Going down into a day shows its date along with its first line.
            target.scrollToVisible(NSRect(x: 0, y: 0, width: 1, height: target.editor.frame.minY + 1))
        }
    }

    func outlineView(_ view: OutlineTextView, open url: URL) {
        switch url.scheme {
        case "reflect-note":
            if let day = Day(url.path) {
                scroll(to: day)
            } else {
                NSSound.beep()
            }
        case nil, "":
            // A graph-relative path — `assets/report.pdf` — opens in the app
            // that opens it, as long as it is safely inside the graph.
            let path = url.path.removingPercentEncoding ?? url.path
            let segments = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.hasPrefix("assets/"), segments.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                NSSound.beep()
                return
            }
            let file = graph.root.appendingPathComponent(path)
            if !NSWorkspace.shared.open(file) {
                Log.shared.warning("files", "Could not open \(path)")
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        default:
            NSWorkspace.shared.open(url)
        }
    }

    /// For the script: the views there are, and where.
    func describeViews() -> String {
        let clip = scrollView.contentView.bounds
        var lines = ["clip \(clip) inset \(scrollView.contentView.contentInsets.top) doc \(document.frame.height)"]
        for (day, view) in views.sorted(by: { $0.key < $1.key }) {
            lines.append("\(day) frame y=\(view.frame.minY) h=\(view.frame.height) offset=\(offsets[index(of: day)]) editor=\(view.editor.frame)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Disk

    /// Writes every note with unsaved writing.
    func saveAll() {
        for view in views.values { view.save() }
    }

    /// Takes in notes changed on disk, by a sync or another app.
    func reloadFromDisk() {
        noteLines = graph.dailyNotes()
        keepingTop {
            for day in measured.keys where views[day] == nil { measured[day] = nil }
        }
        for view in views.values { view.reloadIfChanged() }
        tile()
    }
}

/// A view whose origin is at the top, as a document's is.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
