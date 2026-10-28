import AppKit
import WebKit
import ReflectCore
import ReflectUI
import PrismCore

/// Prism Reader, on the Mac: a window of the inbox's links, read one at a
/// time, the oldest first — done with, the next; or snoozed, put off till
/// later. Read to the end of the queue, a rest — and when the first
/// snoozed one comes back. As the phone's app has it.
final class ReadingQueueWindow: NSWindowController, NSWindowDelegate {
    let session: Session
    private var reader: ReaderPane?
    /// The note shown.
    private var shownPath: String?
    /// The note begun — scrolled — kept in front till it is done or
    /// snoozed, whatever comes back from snoozing older; across launches
    /// too. This Mac's own: another device has its own.
    private var begun: String? {
        get { UserDefaults.standard.string(forKey: "Queue.begun") }
        set { UserDefaults.standard.set(newValue, forKey: "Queue.begun") }
    }

    private let root = WindowRoot()
    /// At the foot, on glass: Snooze, and Done.
    private let bar = GlassCapsule()
    private let snooze = CloseButton(symbol: "clock", pointSize: 14, toolTip: "Snooze: Bring It Back Later")
    private let done = CloseButton(symbol: "checkmark", pointSize: 14, toolTip: "Done: Out of the Inbox, and the Next (⌘↩)")
    private let rule = RuleView()
    private var barTucked = false

    /// Nothing left to read.
    private let rest = NSStackView()
    private let restDetail = NSTextField(wrappingLabelWithString: "")
    /// The first snoozed link back, while there is nothing to read: shown then.
    private var wake: Timer?

    private static let barHeight: CGFloat = 40
    private static let buttonWidth: CGFloat = 46

    init(session: Session) {
        self.session = session
        let window = HandScrollWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 900),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
        window.title = "Prism Reader"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Ink.paper
        window.minSize = NSSize(width: 480, height: 360)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = root
        if !window.setFrameUsingName("PrismReader") { window.center() }
        window.setFrameAutosaveName("PrismReader")
        root.layoutHandler = { [weak self] in self?.layoutWindow() }

        let mark = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 40, weight: .light)) ?? NSImage())
        mark.contentTintColor = Ink.secondary
        let restTitle = NSTextField(labelWithString: "All Read")
        restTitle.font = session.metrics.typography.headingFont(size: 20, weight: .bold)
        restTitle.textColor = Ink.text
        restDetail.font = .systemFont(ofSize: 13)
        restDetail.textColor = Ink.secondary
        restDetail.alignment = .center
        for view in [mark, restTitle, restDetail] { rest.addArrangedSubview(view) }
        rest.orientation = .vertical
        rest.alignment = .centerX
        rest.spacing = 8
        rest.setCustomSpacing(14, after: mark)
        rest.isHidden = true
        root.addSubview(rest)

        snooze.contentTintColor = Ink.text
        snooze.target = self
        snooze.action = #selector(showSnooze(_:))
        done.contentTintColor = Ink.text
        done.target = self
        done.action = #selector(finish(_:))
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = .command
        for view in [snooze, rule, done] as [NSView] { bar.content.addSubview(view) }
        root.addSubview(bar)

        window.onScrolledByHand = { [weak self] in self?.scrolledByHand() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        reader?.savePlace()
        wake?.invalidate()
        session.readingQueueClosed(self)
    }

    private func layoutWindow() {
        let bounds = root.bounds
        reader?.frame = bounds
        // At the foot's right: the reader's own ‹ › are in its controls at the top.
        let width = Self.buttonWidth * 2
        bar.frame = NSRect(x: bounds.width - 16 - width, y: bounds.height - 16 - Self.barHeight, width: width, height: Self.barHeight)
        snooze.frame = NSRect(x: 0, y: 0, width: Self.buttonWidth, height: Self.barHeight)
        rule.frame = NSRect(x: Self.buttonWidth, y: 10, width: 1, height: Self.barHeight - 20)
        done.frame = NSRect(x: Self.buttonWidth, y: 0, width: Self.buttonWidth, height: Self.barHeight)
        restDetail.preferredMaxLayoutWidth = min(360, bounds.width - 64)
        let size = rest.fittingSize
        rest.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 - 20, width: size.width, height: size.height)
    }

    // MARK: The queue

    /// The notes changed: the queue again — and the note read, its links again.
    func notesChanged(_ paths: Set<String>) {
        if let shownPath, paths.contains(shownPath) {
            reader?.refresh(ReaderPane.sources(of: shownPath, session: session))
        }
        refresh()
    }

    /// The queue as the notes now have it: the link begun, while it is
    /// still to be read; else the oldest.
    func refresh() {
        let (items, next) = ReadingQueue.items(index: session.index, root: session.graph.root)
        // Let go of only by Done or Snooze here: out of the queue for a
        // moment — a sync under way — it is still begun.
        let path = begun.flatMap { begun in items.contains { $0.path == begun } ? begun : nil } ?? items.first?.path
        if path != nil, path == shownPath { return }
        show(path, next: next)
    }

    private func show(_ path: String?, next: Date?) {
        if let old = reader {
            old.savePlace()
            old.removeFromSuperview()
        }
        reader = nil
        shownPath = path
        wake?.invalidate()
        wake = nil
        if let path, case let sources = ReaderPane.sources(of: path, session: session), !sources.isEmpty {
            let reader = ReaderPane(session: session, notePath: path, sources: sources)
            reader.standalone = true
            reader.footRoom = Self.barHeight + 24
            reader.onClose = { [weak self] _ in self?.close() }
            reader.onTucked = { [weak self] tucked in self?.setBarTucked(tucked) }
            root.addSubview(reader, positioned: .below, relativeTo: bar)
            self.reader = reader
            if window?.isKeyWindow == true { DispatchQueue.main.async { reader.focus() } }
        } else {
            restDetail.stringValue = ReadingQueue.restDetail(next: next)
            // Back on its own when the first is due, the window open.
            if let next {
                wake = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow + 1), repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            }
        }
        rest.isHidden = reader != nil
        bar.isHidden = reader == nil
        setBarTucked(false)
        root.needsLayout = true
    }

    /// Scrolled into by hand — the page, the PDF — and it is begun.
    private func scrolledByHand() {
        guard let shownPath, begun != shownPath else { return }
        begun = shownPath
    }

    // MARK: Done, or later

    /// Read: out of the inbox — unsnoozed, were it — and the next.
    @objc func finish(_ sender: Any?) {
        guard let path = shownPath else { return }
        begun = nil
        session.setFrontmatter(path, "inbox", nil)
        session.setFrontmatter(path, ReadingQueue.snoozeKey, nil)
        refresh()
    }

    /// Bring it back later: the times as of now.
    @objc private func showSnooze(_ sender: NSView) {
        let menu = NSMenu(title: "Bring It Back")
        let heading = NSMenuItem(title: "Bring It Back", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        for (i, snooze) in ReadingQueue.Snooze.allCases.enumerated() {
            let item = NSMenuItem(title: snooze.title, action: #selector(choseSnooze(_:)), keyEquivalent: "")
            item.subtitle = ReadingQueue.when(snooze.until(from: Date()))
            item.image = NSImage(systemSymbolName: snooze.symbol, accessibilityDescription: nil)
            item.tag = i
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func choseSnooze(_ item: NSMenuItem) {
        put(off: ReadingQueue.Snooze.allCases[item.tag])
    }

    /// Put off: back in the queue when its time comes, in its place by age.
    private func put(off snooze: ReadingQueue.Snooze) {
        guard let path = shownPath else { return }
        begun = nil
        session.setFrontmatter(path, ReadingQueue.snoozeKey, ReadingQueue.written(snooze.until(from: Date())))
        refresh()
    }

    /// Out of the way as the page is read down, with the reader's own.
    private func setBarTucked(_ tucked: Bool) {
        guard tucked != barTucked else { return }
        barTucked = tucked
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            bar.animator().alphaValue = tucked ? 0 : 1
        }
    }

    // MARK: Scripts

    var readerForScript: ReaderPane? { reader }

    func snapshot(to url: URL, done: @escaping () -> Void) {
        guard let view = window?.contentView else { return done() }
        ReaderSnapshot.take(view, reader: reader, over: bar.isHidden ? [] : [bar], to: url, done: done)
    }
}

/// A window told when what is in it is scrolled by hand: a wheel, a
/// trackpad, or a key that scrolls — not a page set where it was read to.
final class HandScrollWindow: NSWindow {
    var onScrolledByHand: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .scrollWheel where event.scrollingDeltaY != 0:
            onScrolledByHand?()
        case .keyDown where Self.scrollKeys.contains(event.keyCode) && !(firstResponder is NSTextView):
            onScrolledByHand?()
        default:
            break
        }
        super.sendEvent(event)
    }

    /// Space, ↑ ↓, Page Up, Page Down, Home, End.
    private static let scrollKeys: Set<UInt16> = [49, 125, 126, 116, 121, 115, 119]
}
