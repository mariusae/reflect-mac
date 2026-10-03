import AppKit
import PDFKit
import ReflectCore

/// A PDF in the graph linked from a note, shown under its link: a page at a
/// time, with the way to the page before and after, the way out to Preview,
/// and a grip to make it larger or smaller. Which page it is at and the size
/// it was given are kept, for each PDF, as how this Mac shows the notes.
///
/// A view of its own over the room its line is given, which the text
/// system lays out as it does a picture's.
@MainActor
package final class PDFPreview: NSView {
    package let source: String
    package let url: URL
    private let root: URL
    private let document: PDFDocument?
    private let page = PageView()
    private let bar = NSView()
    private let previous = NSButton()
    private let next = NSButton()
    private let label = NSTextField(labelWithString: "")
    private let open = NSButton()
    private let grip = Grip()

    /// Told, as the grip is dragged, of the size asked for.
    package var onResize: ((CGSize) -> Void)?

    package static let barHeight: CGFloat = 32
    package static let defaultWidth: CGFloat = 520
    package static let minimum = CGSize(width: 260, height: 180)

    package init(source: String, url: URL, root: URL) {
        self.source = source
        self.url = url
        self.root = root
        document = PDFDocument(url: url)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        page.document = document
        page.onDoubleClick = { [weak self] in self?.openInPreview() }
        addSubview(page)

        for (button, symbol, label, action) in [(previous, "chevron.left", "Previous Page", #selector(showPrevious)),
                                                (next, "chevron.right", "Next Page", #selector(showNext))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.target = self
            button.action = action
            button.toolTip = label
            bar.addSubview(button)
        }
        self.label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        self.label.textColor = .secondaryLabelColor
        bar.addSubview(self.label)
        open.title = "Open in Preview"
        open.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
        open.imagePosition = .imageLeading
        open.bezelStyle = .accessoryBarAction
        open.isBordered = false
        open.font = .systemFont(ofSize: 12)
        open.contentTintColor = .secondaryLabelColor
        open.target = self
        open.action = #selector(openInPreview)
        bar.addSubview(open)
        grip.onDrag = { [weak self] start, delta in
            self?.onResize?(CGSize(width: start.width + delta.width, height: start.height + delta.height))
        }
        grip.startSize = { [weak self] in self?.frame.size ?? .zero }
        bar.addSubview(grip)
        addSubview(bar)

        let remembered = SessionState.shared.pdf(root, source)?.page ?? 0
        show(page: min(max(remembered, 0), max(0, pageCount - 1)), remembering: false)
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package override var isFlipped: Bool { true }

    package var pageCount: Int { document?.pageCount ?? 0 }
    package var pageIndex: Int { page.index }

    package override func layout() {
        super.layout()
        let height = Self.barHeight
        page.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - height))
        bar.frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        previous.frame = NSRect(x: 6, y: 4, width: 26, height: 24)
        next.frame = NSRect(x: 32, y: 4, width: 26, height: 24)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 64, y: (height - label.frame.height) / 2)
        grip.frame = NSRect(x: bounds.width - 18, y: height - 18, width: 16, height: 16)
        open.sizeToFit()
        open.frame = NSRect(x: grip.frame.minX - open.frame.width - 6, y: (height - open.frame.height) / 2,
                            width: open.frame.width, height: open.frame.height)
    }

    package override func updateLayer() {
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    package override var wantsUpdateLayer: Bool { true }

    package override func resetCursorRects() {
        // Not the text's I-beam: this is not text.
        addCursorRect(bounds, cursor: .arrow)
    }

    // MARK: Pages

    @objc package func showPrevious() { show(page: page.index - 1) }
    @objc package func showNext() { show(page: page.index + 1) }

    package func show(page index: Int, remembering: Bool = true) {
        guard pageCount > 0 else {
            label.stringValue = document == nil ? "Cannot be read" : "No pages"
            previous.isEnabled = false
            next.isEnabled = false
            return
        }
        let index = min(max(index, 0), pageCount - 1)
        page.index = index
        label.stringValue = "\(index + 1) of \(pageCount)"
        previous.isEnabled = index > 0
        next.isEnabled = index < pageCount - 1
        needsLayout = true
        if remembering { SessionState.shared.setPDF(root, source) { $0.page = index } }
    }

    @objc package func openInPreview() {
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        guard FileManager.default.fileExists(atPath: preview.path) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The size a PDF is shown at before it is fitted to its column: the
    /// size it was given, else its first page's shape at the usual width.
    package static func size(of url: URL, source: String, root: URL, aspects: inout [String: CGFloat]) -> CGSize {
        if let state = SessionState.shared.pdf(root, source), let width = state.width, let height = state.height {
            return CGSize(width: width, height: height)
        }
        let aspect: CGFloat
        if let known = aspects[source] {
            aspect = known
        } else {
            let size = PDFDocument(url: url)?.page(at: 0).map(PageView.shownSize(of:)) ?? CGSize(width: 612, height: 792)
            aspect = size.width > 0 ? size.height / size.width : 1.3
            aspects[source] = aspect
        }
        let width = defaultWidth
        return CGSize(width: width, height: min(720, (width * aspect).rounded()) + barHeight)
    }
}

/// One page of a PDF, fitted and centred, drawn from a rendering at the
/// screen's resolution, made again only when the page or its size changes.
private final class PageView: NSView {
    var document: PDFDocument?
    var index = 0 {
        didSet { if index != oldValue { rendered = nil; needsDisplay = true } }
    }
    var onDoubleClick: (() -> Void)?
    private var rendered: (key: String, image: NSImage)?

    override var isFlipped: Bool { true }

    /// A page's size as it is shown: turned, when it is turned.
    package static func shownSize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox).size
        return page.rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let page = document?.page(at: index) else { return }
        let natural = Self.shownSize(of: page)
        let area = bounds.insetBy(dx: 10, dy: 10)
        guard natural.width > 0, natural.height > 0, area.width > 0, area.height > 0 else { return }
        let scale = min(area.width / natural.width, area.height / natural.height)
        let size = CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
        let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let backing = window?.backingScaleFactor ?? 2
        let key = "\(index)@\(Int(size.width))x\(Int(size.height))x\(backing)"
        if rendered?.key != key {
            let image = page.thumbnail(of: NSSize(width: size.width * backing, height: size.height * backing), for: .cropBox)
            image.size = size
            rendered = (key, image)
        }
        NSColor.white.setFill()
        rect.fill()
        rendered?.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5)).stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }
}

/// The corner a preview is made larger or smaller by.
private final class Grip: NSView {
    var onDrag: ((_ start: CGSize, _ delta: CGSize) -> Void)?
    var startSize: (() -> CGSize)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setStroke()
        for inset in [4.0, 8.0, 12.0] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: bounds.maxX - 2, y: bounds.minY + inset))
            line.line(to: NSPoint(x: bounds.minX + inset, y: bounds.maxY - 2))
            line.lineWidth = 1
            line.stroke()
        }
    }

    override var isFlipped: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, let start = startSize?() else { return }
        let origin = event.locationInWindow
        // Followed until the button comes up, so the drag is the grip's alone.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = next.locationInWindow
            onDrag?(start, CGSize(width: point.x - origin.x, height: origin.y - point.y))
            if next.type == .leftMouseUp { break }
        }
    }
}

extension ImageStore {
    /// Whether a source is a PDF in the graph.
    package func isPDF(_ source: String) -> Bool {
        source.lowercased().hasSuffix(".pdf") && graphFile(source) != nil
    }

    /// The size a PDF in the graph is shown at, before fitting to its column.
    package func pdfSize(_ source: String) -> CGSize? {
        guard source.lowercased().hasSuffix(".pdf"), let file = graphFile(source) else { return nil }
        return MainActor.assumeIsolated {
            PDFPreview.size(of: file, source: source, root: root, aspects: &pdfAspects)
        }
    }
}
