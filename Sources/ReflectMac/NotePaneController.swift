import AppKit
import ReflectCore

/// One note on its own, in a scroll view: a note opened in the window, or
/// beside the timeline in the split view.
@MainActor
final class NotePaneController: NSViewController, OutlineTextViewNavigator {
    let ref: NoteRef
    let graph: Graph
    let images: ImageStore
    private(set) var noteView: DayView!
    private let scrollView = NSScrollView()
    private let document = FlippedView()

    /// Told when a link in the note is followed: where to, and whether to
    /// the split view.
    var onOpen: ((URL, _ inSplit: Bool) -> Void)?
    /// Told when the note is written.
    var onSave: ((NoteRef) -> Void)?

    var metrics: OutlineMetrics {
        didSet {
            noteView?.metrics = metrics
            refreshBacklinks()
        }
    }

    /// Where backlinks are found, and what opens them: set by the window.
    static var index: NoteIndex?
    static var openBacklink: ((_ path: String, _ link: String?, _ inSplit: Bool) -> Void)?

    /// A topic note's backlinks, under it — when it says it is one, or
    /// says nothing yet.
    private let backlinks = BacklinksView()
    private(set) var showsBacklinks = false
    private var backlinkGeneration = 0

    init(ref: NoteRef, graph: Graph, images: ImageStore, metrics: OutlineMetrics) {
        self.ref = ref
        self.graph = graph
        self.images = images
        self.metrics = metrics
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
        noteView = DayView(ref: ref, graph: graph, images: images, metrics: metrics)
        noteView.editor.navigator = self
        noteView.onHeightChange = { [weak self] _ in self?.view.needsLayout = true }
        noteView.onSave = { [weak self] in
            guard let self else { return }
            onSave?(ref)
            // Written into, or emptied: a topic, or no longer.
            refreshBacklinks()
        }
        document.addSubview(noteView)
        backlinks.isHidden = true
        backlinks.onOpen = { path, link, inSplit in Self.openBacklink?(path, link, inSplit) }
        document.addSubview(backlinks)
        view = scrollView
        refreshBacklinks()
    }

    /// Whether the note is a topic — `topic: true`, or a note that says
    /// nothing but its title — and, if so, what links to it, found in the
    /// background and shown under it.
    func refreshBacklinks() {
        guard isViewLoaded, let index = Self.index else { return }
        let isTopic = NoteIndex.entry(path: ref.path, source: noteView.savedText).isTopic
        let isEmpty = ref.day == nil && Backlinks.isEmpty(noteView.editor.rows)
        backlinkGeneration += 1
        guard isTopic || isEmpty else {
            if showsBacklinks {
                showsBacklinks = false
                backlinks.isHidden = true
                view.needsLayout = true
            }
            return
        }
        let generation = backlinkGeneration
        let path = ref.path
        DispatchQueue.global(qos: .userInitiated).async {
            let sources = index.backlinks(to: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, generation == backlinkGeneration else { return }
                    backlinks.show(sources, titles: { path in
                        index.entry(path).map { $0.day.map(OpenQuickly.dayTitle) ?? $0.title }
                            ?? GraphPaths.day(fromDailyPath: path).map(OpenQuickly.dayTitle) ?? path
                    }, fontSize: metrics.fontSize)
                    showsBacklinks = true
                    backlinks.isHidden = false
                    view.needsLayout = true
                }
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentView.bounds.width
        let visible = scrollView.documentVisibleRect.height
        guard showsBacklinks else {
            // The note fills the pane at least, so a click below its text
            // lands at its end.
            noteView.minimumHeight = visible
            let height = max(noteView.desiredHeight(width: width), visible)
            document.frame = NSRect(x: 0, y: 0, width: width, height: height)
            noteView.frame = document.bounds
            return
        }
        // The note, then what links to it, in the note's own column.
        noteView.minimumHeight = 0
        let noteHeight = noteView.desiredHeight(width: width)
        noteView.frame = NSRect(x: 0, y: 0, width: width, height: noteHeight)
        noteView.layoutSubtreeIfNeeded()
        let editor = noteView.editor
        let left = editor.frame.minX + editor.textContainerOrigin.x + metrics.indent
        let columnWidth = max(200, editor.frame.maxX - left - 16)
        let linksHeight = backlinks.height(forWidth: columnWidth)
        backlinks.frame = NSRect(x: left, y: noteHeight + 8, width: columnWidth, height: linksHeight)
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(noteHeight + 8 + linksHeight, visible))
    }

    /// Scrolls to the very end, backlinks and all. For scripts.
    func scrollToEnd() {
        document.scroll(NSPoint(x: 0, y: max(0, document.frame.height - scrollView.contentView.bounds.height)))
    }

    /// Puts the keyboard in the note, at the end of what is written.
    func focus() {
        view.window?.makeFirstResponder(noteView.editor)
        if !noteView.hasConflict { noteView.editor.enter(from: .bottom, x: .greatestFiniteMagnitude, scrolling: false) }
    }

    /// The note's title, as the window shows it.
    var noteTitle: String {
        NoteIndex.entry(path: ref.path, source: noteView.savedText).title
    }

    func save() { noteView.save() }
    func discard() { noteView.discard() }
    func reloadFromDisk() { noteView.reloadIfChanged() }

    // MARK: OutlineTextViewNavigator

    func outlineView(_ view: OutlineTextView, leaveThrough edge: OutlineTextView.Edge, x: CGFloat) {
        // A note on its own has nothing before or after it: the caret goes
        // to its start, or its end, as in any text.
        view.enter(from: edge, x: edge == .top ? 0 : .greatestFiniteMagnitude)
    }

    func outlineView(_ view: OutlineTextView, open url: URL, inSplit: Bool) {
        onOpen?(url, inSplit)
    }
}
