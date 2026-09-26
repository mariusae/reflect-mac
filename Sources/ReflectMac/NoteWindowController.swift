import AppKit
import ReflectCore

/// A note in a window of its own, just for writing in: the note, its
/// title as the window's, and nothing else. Its size and place are kept
/// for it; links followed from it open in the main window.
@MainActor
final class NoteWindowController: NSWindowController, NSWindowDelegate {
    private(set) var pane: NotePaneController
    private let graph: Graph
    private let images: ImageStore

    /// Told when a link is followed: where to, and whether to the split view.
    var onOpen: ((URL, _ inSplit: Bool) -> Void)?
    /// Told when the note is written.
    var onSave: ((NoteRef) -> Void)?
    /// Told when the window has closed.
    var onClose: ((NoteWindowController) -> Void)?

    var ref: NoteRef { pane.ref }

    init(ref: NoteRef, graph: Graph, images: ImageStore, metrics: OutlineMetrics) {
        self.graph = graph
        self.images = images
        pane = NotePaneController(ref: ref, graph: graph, images: images, metrics: metrics)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.tabbingMode = .preferred
        window.minSize = NSSize(width: 360, height: 240)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        install(pane)
        // The note's view has no size of its own to give the window: a
        // page's, unless this note's window was sized before.
        window.setContentSize(NSSize(width: 760, height: 820))
        if !window.setFrameUsingName("Note " + ref.path) { window.center() }
        window.setFrameAutosaveName("Note " + ref.path)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func install(_ pane: NotePaneController) {
        pane.onOpen = { [weak self] url, inSplit in self?.onOpen?(url, inSplit) }
        pane.onSave = { [weak self] ref in
            self?.onSave?(ref)
            self?.showTitle()
        }
        window?.contentViewController = pane
        window?.representedURL = graph.url(for: pane.ref.path)
        showTitle()
    }

    private func showTitle() {
        window?.title = pane.ref.day.map(OpenQuickly.dayTitle) ?? pane.noteTitle
        window?.subtitle = graph.root.lastPathComponent
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        pane.focus()
    }

    var metrics: OutlineMetrics {
        get { pane.metrics }
        set { pane.metrics = newValue }
    }

    func save() { pane.save() }
    func reloadFromDisk() {
        pane.reloadFromDisk()
        showTitle()
    }

    /// The note moved to a new path — renamed — followed, its caret kept.
    func moved(to ref: NoteRef) {
        let selection = pane.noteView.editor.selectedRange()
        let focused = window?.isKeyWindow == true
        pane.discard()
        let next = NotePaneController(ref: ref, graph: graph, images: images, metrics: pane.metrics)
        pane = next
        install(next)
        window?.setFrameAutosaveName("Note " + ref.path)
        let editor = next.noteView.editor
        if let length = editor.textStorage?.length {
            let location = min(selection.location, length)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        }
        if focused { window?.makeFirstResponder(editor) }
    }

    /// Closes without writing: the note is gone.
    func closeDiscarding() {
        pane.discard()
        close()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        pane.save()
        onClose?(self)
    }

    func windowDidResignKey(_ notification: Notification) {
        pane.save()
    }
}
