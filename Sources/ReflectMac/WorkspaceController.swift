import AppKit
import ReflectCore

/// What the window shows: the timeline, or a note in its place; and, slid
/// in over the right of either, a second note — the split view.
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
    /// The note in the split view.
    private(set) var split: NotePaneController?
    private let splitFrame = SplitFrameView()

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
            split?.metrics = metrics
        }
    }

    init(graph: Graph, timeline: TimelineViewController, index: NoteIndex) {
        self.graph = graph
        self.timeline = timeline
        self.index = index
        metrics = timeline.metrics
        super.init(nibName: nil, bundle: nil)
        timeline.onOpen = { [weak self] url, inSplit in self?.open(url, inSplit: inSplit) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = FlippedView(frame: NSRect(x: 0, y: 0, width: 900, height: 800))
        addChild(timeline)
        view.addSubview(timeline.view)
        splitFrame.onClose = { [weak self] in self?.closeSplit() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        (main?.view ?? timeline.view).frame = view.bounds
        if split != nil { splitFrame.frame = splitRect(open: true) }
    }

    private func splitRect(open: Bool) -> NSRect {
        let width = min(max(view.bounds.width * 0.46, 380), max(view.bounds.width - 140, 300))
        return NSRect(x: open ? view.bounds.width - width : view.bounds.width, y: 0, width: width, height: view.bounds.height)
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
            view.addSubview(pane.view, positioned: .below, relativeTo: split == nil ? nil : splitFrame)
            pane.view.frame = view.bounds
            main = pane
            timeline.view.isHidden = true
        } else {
            timeline.view.isHidden = false
        }
        onChange?()
    }

    @objc func goBack(_ sender: Any?) {
        guard let previous = back.popLast() else { NSSound.beep(); return }
        forward.append(current)
        move(to: previous, recording: false)
        if let main { main.focus() } else { view.window?.makeFirstResponder(timeline.view) }
    }

    @objc func goForward(_ sender: Any?) {
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

    /// Slides a note in from the right, over what is shown; or puts it in
    /// place of the one there.
    func openSplit(_ ref: NoteRef) {
        let wasOpen = split != nil
        split?.save()
        split?.view.removeFromSuperview()
        split?.removeFromParent()
        let pane = pane(for: ref)
        addChild(pane)
        split = pane
        splitFrame.content = pane.view
        if !wasOpen {
            view.addSubview(splitFrame)
            splitFrame.frame = splitRect(open: false)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                splitFrame.animator().frame = splitRect(open: true)
            }
        }
        pane.focus()
        onChange?()
    }

    @objc func closeSplit(_ sender: Any? = nil) {
        guard let pane = split else { return }
        pane.save()
        split = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            splitFrame.animator().frame = splitRect(open: false)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.split == nil else { return }
                self.splitFrame.removeFromSuperview()
                self.splitFrame.content = nil
                pane.removeFromParent()
            }
        })
        if let main { main.focus() } else { view.window?.makeFirstResponder(timeline.view) }
        onChange?()
    }

    // MARK: Links

    /// Follows a link: a note by title or alias — made, when there is none
    /// by that name, as Reflect does — a day, a file in the graph, or the web.
    func open(_ url: URL, inSplit: Bool) {
        switch url.scheme {
        case "reflect-note":
            let title = url.path
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

    func open(_ target: OpenQuickly.Target, inSplit: Bool) {
        switch target {
        case .note(let path): show(NoteRef(path: path), inSplit: inSplit)
        case .day(let day): show(.day(day), inSplit: inSplit)
        case .create(let title): if let path = create(title) { show(NoteRef(path: path), inSplit: inSplit) }
        }
    }

    // MARK: Disk

    func saveAll() {
        timeline.saveAll()
        main?.save()
        split?.save()
    }

    func reloadFromDisk() {
        timeline.reloadFromDisk()
        main?.reloadFromDisk()
        split?.reloadFromDisk()
    }

    /// The title of what is shown in the main place.
    var noteTitle: String? { main?.noteTitle }
}

/// The split view's frame: the note, a line and a shadow on its left edge,
/// and a button to put it away.
final class SplitFrameView: NSView {
    var onClose: (() -> Void)?
    private let close = NSButton()

    var content: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let content {
                addSubview(content, positioned: .below, relativeTo: close)
                needsLayout = true
            }
        }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = 14
            shadow.shadowOffset = NSSize(width: -2, height: 0)
            return shadow
        }()
        close.bezelStyle = .regularSquare
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Split View")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular).applying(.init(hierarchicalColor: .tertiaryLabelColor)))
        close.toolTip = "Close Split View (⌘W)"
        close.target = self
        close.action = #selector(closeClicked(_:))
        addSubview(close)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeClicked(_ sender: Any?) { onClose?() }

    override func layout() {
        super.layout()
        content?.frame = NSRect(x: 1, y: 0, width: bounds.width - 1, height: bounds.height)
        let top = (window?.contentLayoutRect.minY).map { _ in window!.frame.height - window!.contentLayoutRect.maxY } ?? 0
        close.frame = NSRect(x: bounds.width - 30, y: top + 8, width: 22, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }
}
