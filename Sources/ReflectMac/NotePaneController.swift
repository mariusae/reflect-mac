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
        didSet { noteView?.metrics = metrics }
    }

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
        }
        document.addSubview(noteView)
        view = scrollView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentView.bounds.width
        let visible = scrollView.documentVisibleRect.height
        // The note fills the pane at least, so a click below its text lands
        // at its end.
        noteView.minimumHeight = visible
        let height = max(noteView.desiredHeight(width: width), visible)
        document.frame = NSRect(x: 0, y: 0, width: width, height: height)
        noteView.frame = document.bounds
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
    func reloadFromDisk() { noteView.reloadIfChanged() }

    // MARK: OutlineTextViewNavigator

    func outlineView(_ view: OutlineTextView, leaveThrough edge: OutlineTextView.Edge, x: CGFloat) {
        // A note on its own has nothing before or after it: the caret goes
        // to its start, or its end, as in any text.
        view.enter(from: edge, x: edge == .top ? 0 : .greatestFiniteMagnitude)
    }

    func outlineView(_ view: OutlineTextView, open url: URL) {
        onOpen?(url, NSApp.currentEvent?.modifierFlags.contains(.option) == true)
    }
}
