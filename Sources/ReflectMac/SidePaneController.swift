import AppKit
import ReflectCore

/// The pane on the right: a note beside what the window shows, with its own
/// way back and forward — in the window's toolbar, over the pane, with its
/// title and a button to put it away.
///
/// Links followed in it open in it; with ⌘, in the main view.
@MainActor
final class SidePaneController: NSViewController {
    let graph: Graph
    let images: ImageStore
    var metrics: OutlineMetrics {
        didSet { pane?.metrics = metrics }
    }

    /// The note shown, and where it came from and went to.
    private(set) var pane: NotePaneController?
    private var back: [NoteRef] = []
    private var forward: [NoteRef] = []

    /// Told when a link is followed: where to, and whether to the main view.
    var onOpen: ((URL, _ inMain: Bool) -> Void)?
    /// Told when the note shown is written.
    var onSave: ((NoteRef) -> Void)?
    /// Told to put the pane away.
    var onClose: (() -> Void)?
    /// Told when what is shown changes.
    var onChange: (() -> Void)?

    private let content = NSView()

    init(graph: Graph, images: ImageStore, metrics: OutlineMetrics) {
        self.graph = graph
        self.images = images
        self.metrics = metrics
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        // Its edge, drawn: the split view's own hairline all but vanishes
        // between two notes alike, in the dark.
        let edge = EdgeLine()
        edge.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(edge)
        NSLayoutConstraint.activate([
            edge.topAnchor.constraint(equalTo: container.topAnchor),
            edge.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
        ])
        // Its way back and forward, title and close are in the window's
        // toolbar, over the pane: the note starts under it.
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    // MARK: What is shown

    var ref: NoteRef? { pane?.ref }
    var editor: OutlineTextView? { pane?.noteView.editor }

    /// Shows a note, the one there going into the way back.
    func show(_ ref: NoteRef) {
        guard ref != pane?.ref else { return }
        if let current = pane?.ref { back.append(current) }
        forward.removeAll()
        place(ref)
    }

    @objc func goBack(_ sender: Any?) {
        guard let previous = back.popLast() else { NSSound.beep(); return }
        if let current = pane?.ref { forward.append(current) }
        place(previous)
        pane?.focus()
    }

    @objc func goForward(_ sender: Any?) {
        guard let next = forward.popLast() else { NSSound.beep(); return }
        if let current = pane?.ref { back.append(current) }
        place(next)
        pane?.focus()
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Forgets where it has been: the pane put away starts afresh.
    func clear(saving: Bool = true) {
        if saving { pane?.save() } else { pane?.discard() }
        pane?.view.removeFromSuperview()
        pane?.removeFromParent()
        pane = nil
        back.removeAll()
        forward.removeAll()
        update()
    }

    private func place(_ ref: NoteRef) {
        _ = view
        pane?.save()
        pane?.view.removeFromSuperview()
        pane?.removeFromParent()
        let next = NotePaneController(ref: ref, graph: graph, images: images, metrics: metrics)
        next.onOpen = { [weak self] url, option in self?.onOpen?(url, option) }
        next.onSave = { [weak self] ref in
            self?.onSave?(ref)
            self?.update()
        }
        addChild(next)
        next.view.frame = content.bounds
        next.view.autoresizingMask = [.width, .height]
        content.addSubview(next.view)
        pane = next
        update()
    }

    private func update() {
        onChange?()
    }

    /// What the pane shows, for its title.
    var noteTitle: String {
        pane.map { $0.ref.day.map(OpenQuickly.dayTitle) ?? $0.noteTitle } ?? ""
    }


    func focus() { pane?.focus() }
    func save() { pane?.save() }

    func reloadFromDisk() {
        pane?.reloadFromDisk()
        update()
    }

    /// Whether the keyboard is somewhere in the pane.
    var hasFocus: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }
}

/// A pane's edge: a line in the separator colour.
private final class EdgeLine: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.separatorColor.cgColor }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
