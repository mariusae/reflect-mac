import AppKit
import ReflectCore

/// Window ▸ Console: the app's log as it happens — syncs and how they
/// ended, every git command and what it said, files added, pictures that
/// would not load. Problems are coloured, and can be shown alone.
@MainActor
final class ConsoleWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ConsoleWindowController()

    private let textView = NSTextView()
    private let filter = NSSegmentedControl(labels: ["All", "Problems"], trackingMode: .selectOne, target: nil, action: nil)
    private var problemsOnly: Bool { filter.selectedSegment == 1 }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.title = "Console"
        window.setFrameAutosaveName("Console")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.backgroundColor = .textBackgroundColor
        scroll.documentView = textView

        filter.selectedSegment = 0
        filter.target = self
        filter.action = #selector(filterChanged(_:))
        filter.controlSize = .small
        let clear = NSButton(title: "Clear", target: self, action: #selector(clear(_:)))
        clear.controlSize = .small
        clear.bezelStyle = .push
        let reveal = NSButton(title: "Show Log File", target: self, action: #selector(revealLogFile(_:)))
        reveal.controlSize = .small
        reveal.bezelStyle = .push
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [filter, spacer, reveal, clear])
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        let content = NSStackView(views: [scroll, bar])
        content.orientation = .vertical
        content.spacing = 0
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = content
        if !window.setFrameUsingName("Console") { window.center() }

        NotificationCenter.default.addObserver(self, selector: #selector(added(_:)), name: Log.didAdd, object: nil)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Brings the console forward, at its latest entry.
    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        textView.scrollToEndOfDocument(nil)
    }

    // MARK: Entries

    private func line(_ entry: Log.Entry) -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let color: NSColor = switch entry.level {
        case .error: .systemRed
        case .warning: .systemOrange
        case .info: .labelColor
        }
        let text = NSMutableAttributedString(string: Self.time.string(from: entry.date) + "  ",
                                             attributes: [.font: mono, .foregroundColor: NSColor.tertiaryLabelColor])
        text.append(NSAttributedString(string: entry.category.padding(toLength: 7, withPad: " ", startingAt: 0),
                                       attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor]))
        text.append(NSAttributedString(string: entry.message + "\n", attributes: [.font: mono, .foregroundColor: color]))
        if let detail = entry.detail {
            let indented = detail.split(separator: "\n", omittingEmptySubsequences: false).map { "      " + $0 }.joined(separator: "\n")
            text.append(NSAttributedString(string: indented + "\n", attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return text
    }

    private func shows(_ entry: Log.Entry) -> Bool { !problemsOnly || entry.level != .info }

    private func reload() {
        let text = NSMutableAttributedString()
        for entry in Log.shared.entries where shows(entry) { text.append(line(entry)) }
        textView.textStorage?.setAttributedString(text)
        textView.scrollToEndOfDocument(nil)
    }

    @objc private func added(_ notification: Notification) {
        guard let entry = notification.object as? Log.Entry, shows(entry), window?.isVisible == true,
              let storage = textView.textStorage else { return }
        // Follows the end only if the end was showing.
        let atEnd = (textView.enclosingScrollView?.documentVisibleRect.maxY ?? 0) >= textView.bounds.maxY - 20
        storage.append(line(entry))
        if atEnd { textView.scrollToEndOfDocument(nil) }
    }

    @objc private func filterChanged(_ sender: Any?) { reload() }

    @objc private func clear(_ sender: Any?) {
        Log.shared.clear()
        reload()
    }

    @objc private func revealLogFile(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([Log.shared.fileURL])
    }

    func windowDidBecomeKey(_ notification: Notification) { reload() }
}
