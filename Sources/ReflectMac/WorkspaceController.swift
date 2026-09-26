import AppKit
import ReflectCore

/// What the window shows: the timeline, or a note in its place; and, in a
/// pane of its own on the right, a second note — the split view.
///
/// Going from one to another is kept, so Back and Forward retrace it. The
/// timeline is kept as it was while a note is shown, so going back to it
/// finds it where it was left.
@MainActor
final class WorkspaceController: NSViewController {
    let graph: Graph
    let timeline: TimelineViewController
    let index: NoteIndex

    /// The note in the main place, when it is not the timeline.
    private(set) var main: NotePaneController?
    /// The pane on the right, and its place in the window's split view.
    let side: SidePaneController
    let sideItem: NSSplitViewItem
    /// The note in the split view, while it is open.
    var split: NotePaneController? { sideItem.isCollapsed ? nil : side.pane }

    private var back: [NoteRef?] = []
    private var forward: [NoteRef?] = []

    /// Told when what is shown changes.
    var onChange: (() -> Void)?
    /// Told when a note shown here is written.
    var onSave: ((NoteRef) -> Void)?

    var metrics: OutlineMetrics {
        didSet {
            timeline.metrics = metrics
            main?.metrics = metrics
            side.metrics = metrics
        }
    }

    init(graph: Graph, timeline: TimelineViewController, index: NoteIndex) {
        self.graph = graph
        self.timeline = timeline
        self.index = index
        metrics = timeline.metrics
        side = SidePaneController(graph: graph, images: timeline.images, metrics: timeline.metrics)
        sideItem = NSSplitViewItem(inspectorWithViewController: side)
        sideItem.minimumThickness = 320
        sideItem.maximumThickness = 1200
        sideItem.canCollapse = true
        sideItem.isCollapsed = true
        // Up under the toolbar, whose items over it are the pane's own.
        sideItem.allowsFullHeightLayout = true
        super.init(nibName: nil, bundle: nil)
        timeline.onOpen = { [weak self] url, inSplit in self?.open(url, inSplit: inSplit) }
        // Links in the pane go on in it; with ⌘, to the main view.
        side.onOpen = { [weak self] url, inMain in self?.open(url, inSplit: !inMain) }
        side.onSave = { [weak self] ref in self?.onSave?(ref) }
        side.onClose = { [weak self] in self?.closeSplit() }
        side.onChange = { [weak self] in self?.onChange?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = FlippedView(frame: NSRect(x: 0, y: 0, width: 900, height: 800))
        addChild(timeline)
        view.addSubview(timeline.view)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        (main?.view ?? timeline.view).frame = view.bounds
    }

    // MARK: What is shown

    /// The note in the main place, or nil for the timeline.
    var current: NoteRef? { main?.ref }
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Shows a note — in the split view, or in the main place, where a day
    /// is shown in the timeline.
    func show(_ ref: NoteRef, inSplit: Bool) {
        if inSplit {
            openSplit(ref)
            return
        }
        move(to: ref, recording: true)
        if let day = ref.day { timeline.focus(day) } else { main?.focus() }
    }

    private func move(to ref: NoteRef?, recording: Bool) {
        let target: NoteRef? = ref?.day == nil ? ref : nil
        if recording && target != current {
            back.append(current)
            forward.removeAll()
        }
        guard target != current else { return }
        main?.save()
        main?.view.removeFromSuperview()
        main?.removeFromParent()
        main = nil
        if let target {
            let pane = pane(for: target)
            addChild(pane)
            view.addSubview(pane.view)
            pane.view.frame = view.bounds
            main = pane
            timeline.view.isHidden = true
        } else {
            timeline.view.isHidden = false
        }
        onChange?()
    }

    @objc func goBack(_ sender: Any?) {
        // In the pane, the pane's way back.
        if split != nil, side.hasFocus { side.goBack(sender); return }
        guard let previous = back.popLast() else { NSSound.beep(); return }
        forward.append(current)
        move(to: previous, recording: false)
        if let main { main.focus() } else { view.window?.makeFirstResponder(timeline.view) }
    }

    @objc func goForward(_ sender: Any?) {
        if split != nil, side.hasFocus { side.goForward(sender); return }
        guard let next = forward.popLast() else { NSSound.beep(); return }
        back.append(current)
        move(to: next, recording: false)
        main?.focus()
    }

    /// Back to the timeline, at today.
    func showToday() {
        move(to: nil, recording: true)
        timeline.focus(.today)
    }

    private func pane(for ref: NoteRef) -> NotePaneController {
        let pane = NotePaneController(ref: ref, graph: graph, images: timeline.images, metrics: metrics)
        pane.onOpen = { [weak self] url, inSplit in self?.open(url, inSplit: inSplit) }
        pane.onSave = { [weak self] ref in self?.onSave?(ref) }
        return pane
    }

    // MARK: The split view

    /// Shows a note in the pane on the right, opening the pane if it was
    /// put away; the note that was there goes into the pane's way back.
    func openSplit(_ ref: NoteRef) {
        if sideItem.isCollapsed {
            // Put away, the pane started afresh.
            side.clear()
            side.show(ref)
            makeRoomForSide()
            // Once the window has taken its new width.
            DispatchQueue.main.async { [self] in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    sideItem.animator().isCollapsed = false
                }
                // A hidden view takes no keyboard: once it shows.
                side.focus()
                onChange?()
            }
        } else {
            side.show(ref)
            side.focus()
        }
        onChange?()
    }

    /// Widens the window, as far as the screen lets it, so that the main
    /// view keeps its width beside the pane — rather than the pane pushing
    /// it narrower than it can be.
    private func makeRoomForSide() {
        guard let window = view.window, let screen = window.screen?.visibleFrame else { return }
        // The pane comes back as wide as it was.
        let wanted = Self.mainMinimum + max(sideItem.minimumThickness, side.view.frame.width, 400)
        let short = wanted - view.frame.width
        guard short > 0 else { return }
        var frame = window.frame
        frame.size.width = min(frame.width + short, screen.width)
        if frame.maxX > screen.maxX { frame.origin.x = max(screen.minX, screen.maxX - frame.width) }
        window.setFrame(frame, display: true, animate: false)
    }

    /// The narrowest the main view is made.
    static let mainMinimum: CGFloat = 520

    /// Puts the pane on the right away.
    @objc func closeSplit(_ sender: Any? = nil) {
        guard !sideItem.isCollapsed else { return }
        side.save()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            sideItem.animator().isCollapsed = true
        }
        if let main { main.focus() } else { view.window?.makeFirstResponder(timeline.view) }
        onChange?()
    }

    /// Lets a note go from wherever it is shown, it being gone: the main
    /// view goes back to the timeline, the pane is put away. Nothing of it
    /// is written again.
    func forget(_ path: String) {
        if split?.ref.path == path {
            side.clear(saving: false)
            sideItem.isCollapsed = true
        }
        if main?.ref.path == path {
            main?.discard()
            move(to: nil, recording: false)
        }
        back.removeAll { $0?.path == path }
        forward.removeAll { $0?.path == path }
        onChange?()
    }

    // MARK: Links

    /// Follows a link: a note by title or alias — made, when there is none
    /// by that name, as Reflect does — a day, a file in the graph, or the web.
    func open(_ url: URL, inSplit: Bool) {
        switch url.scheme {
        case "reflect-note":
            guard let title = url.wikiTarget else {
                NSSound.beep()
                return
            }
            if let path = index.resolve(title) {
                show(NoteRef(path: path), inSplit: inSplit)
            } else if let path = create(title) {
                show(NoteRef(path: path), inSplit: inSplit)
            }
        case nil, "":
            timeline.openAsset(url)
        default:
            NSWorkspace.shared.open(url)
        }
    }

    /// Makes a note for a title, and says what it did.
    func create(_ title: String) -> String? {
        // A note is made only with a name to make it by.
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            return nil
        }
        do {
            let path = try NoteCreation.create(title: title, in: graph.root)
            index.refresh(path)
            Log.shared.info("files", "Made \(path) for “\(title)”")
            onSave?(NoteRef(path: path))
            return path
        } catch {
            Log.shared.error("files", "Could not make a note for “\(title)”", detail: error.localizedDescription)
            presentError(error)
            return nil
        }
    }

    /// Opens what the chooser chose, and shows what its search found there.
    func open(_ target: OpenQuickly.Target, inSplit: Bool, found: OutlineTextView.Found? = nil) {
        let ref: NoteRef
        switch target {
        case .note(let path): ref = NoteRef(path: path)
        case .day(let day): ref = .day(day)
        case .create(let title):
            guard let path = create(title) else { return }
            ref = NoteRef(path: path)
        }
        show(ref, inSplit: inSplit)
        guard let found, let editor = editor(showing: ref, inSplit: inSplit) else { return }
        // Once the note is laid out where it is shown.
        DispatchQueue.main.async {
            editor.window?.makeFirstResponder(editor)
            editor.reveal(found)
        }
    }

    /// The editor a note is shown in, just after showing it.
    private func editor(showing ref: NoteRef, inSplit: Bool) -> OutlineTextView? {
        if inSplit { return side.editor }
        if let day = ref.day { return timeline.view(for: day).editor }
        return main?.noteView.editor
    }

    // MARK: Disk

    func saveAll() {
        timeline.saveAll()
        main?.save()
        side.save()
    }

    func reloadFromDisk() {
        timeline.reloadFromDisk()
        main?.reloadFromDisk()
        side.reloadFromDisk()
    }

    /// Topic notes shown look again at what links to them.
    func refreshBacklinks() {
        main?.refreshBacklinks()
        side.pane?.refreshBacklinks()
    }

    /// The title of what is shown in the main place.
    var noteTitle: String? { main?.noteTitle }
}
