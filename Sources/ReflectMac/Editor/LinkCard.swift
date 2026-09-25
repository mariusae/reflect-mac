import AppKit
import ReflectCore

/// The card a link shows when the pointer rests on it.
///
/// For a link to the web: the page's icon, title and description, and its
/// address, to open or copy — and, for an address written out bare, to put
/// its title in its place, as `[Title](address)`. For a post on X, the post.
/// For a `[[link]]`, the note it leads to, as it reads; or, when there is no
/// such note yet, the offer to make one.
///
/// The card stays while the pointer is on the link or on the card, so its
/// buttons can be reached, and goes when it leaves both.
@MainActor
final class LinkCard: NSObject {
    static let shared = LinkCard()

    /// The note a `[[title]]` leads to, and what it says: the window sets
    /// this to its own way of following links.
    static var noteSource: ((String) -> (ref: NoteRef, text: String)?)?

    /// What is hovered: which link, where it is in the text, and what kind.
    struct Hover: Equatable {
        var url: URL
        var range: NSRange
        /// An address written out, which can take its page's title.
        var isBare: Bool
    }

    private let panel: HoverPanel
    private let content = FlippedView()
    private weak var owner: OutlineTextView?
    private(set) var shown: Hover?
    private var pendingShow: DispatchWorkItem?
    private var pendingHide: DispatchWorkItem?
    private var anchor: NSRect = .zero

    private static let width: CGFloat = 380
    private static let padding: CGFloat = 14

    private override init() {
        panel = HoverPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 80),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isFloatingPanel = true
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = background
        background.addSubview(content)
        panel.onExit = { [weak self] in self?.scheduleHide() }
        panel.onEnter = { [weak self] in self?.pendingHide?.cancel() }
    }

    // MARK: Showing and hiding

    /// The pointer is on a link: show its card after a moment.
    func hover(_ hover: Hover, in textView: OutlineTextView, anchor: NSRect) {
        pendingHide?.cancel()
        guard hover != shown || owner !== textView else { return }
        pendingShow?.cancel()
        let work = DispatchWorkItem { [weak self, weak textView] in
            MainActor.assumeIsolated {
                guard let self, let textView else { return }
                self.show(hover, in: textView, anchor: anchor)
            }
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (panel.isVisible ? 0.15 : 0.5), execute: work)
    }

    /// The pointer has left the link: hide the card, unless it goes onto it.
    func scheduleHide() {
        pendingShow?.cancel()
        guard panel.isVisible, pendingHide == nil || pendingHide!.isCancelled else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.panel.containsPointer else { return }
                self.hide()
            }
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func hide() {
        pendingShow?.cancel()
        pendingHide?.cancel()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        shown = nil
    }

    private func show(_ hover: Hover, in textView: OutlineTextView, anchor: NSRect) {
        owner = textView
        shown = hover
        self.anchor = anchor
        build(hover, in: textView)
        guard let window = textView.window else { return }
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        place()
        panel.orderFront(nil)
    }

    /// Below the link, or above it when there is no room below.
    private func place() {
        let height = content.frame.height
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - height - 6)
        if let screen = owner?.window?.screen?.visibleFrame {
            if origin.y < screen.minY { origin.y = anchor.maxY + 6 }
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - Self.width - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
        content.frame = NSRect(origin: .zero, size: NSSize(width: Self.width, height: height))
    }

    /// Builds the card again when what it shows arrives, if it still shows it.
    private func rebuild(_ hover: Hover) {
        guard shown == hover, let owner else { return }
        build(hover, in: owner)
        place()
    }

    // MARK: Building

    private func build(_ hover: Hover, in textView: OutlineTextView) {
        content.subviews.forEach { $0.removeFromSuperview() }
        var parts: [NSView] = []
        var buttons: [NSButton] = []

        if let title = hover.url.wikiTarget {
            buildNote(title: title, textView: textView, parts: &parts, buttons: &buttons)
        } else if hover.url.scheme == nil || hover.url.scheme == "" {
            parts.append(label(hover.url.absoluteString, font: .systemFont(ofSize: 13, weight: .semibold)))
            parts.append(label("A file in the graph", font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
            buttons.append(button("Open", symbol: "arrow.up.forward.app") { [weak self] in self?.follow(hover.url, split: false) })
        } else if Tweet.id(from: hover.url.absoluteString) != nil, let images = textView.images,
                  let tweet = images.tweet(hover.url.absoluteString) ?? { _ = images.naturalSize(hover.url.absoluteString); return nil }() {
            parts.append(TweetView(tweet: tweet, images: images, width: Self.width - 2 * Self.padding))
            buttons.append(button("Open", symbol: "safari") { [weak self] in self?.follow(hover.url, split: false) })
            buttons.append(copyButton(hover.url))
        } else {
            buildWeb(hover, textView: textView, parts: &parts, buttons: &buttons)
        }
        layout(parts, buttons: buttons)
    }

    private func buildWeb(_ hover: Hover, textView: OutlineTextView, parts: inout [NSView], buttons: inout [NSButton]) {
        let url = hover.url
        let address = (url.host ?? "") + (url.path.count > 1 ? url.path : "")
        var meta: PageMetadata?
        var loading = false
        if textView.isPrivateNote {
            // A private note's links are never looked up, as in Reflect.
        } else if let cached = LinkPreviewStore.shared.cached(url) {
            meta = cached
        } else {
            loading = true
            LinkPreviewStore.shared.load(url) { [weak self] _ in self?.rebuild(hover) }
        }

        var favicon: NSImage?
        if let iconURL = meta?.iconURL, let images = textView.images, images.naturalSize(iconURL.absoluteString) != nil {
            favicon = images.image(iconURL.absoluteString)
        } else if let iconURL = meta?.iconURL {
            textView.images?.whenLoaded(iconURL.absoluteString) { [weak self] in self?.rebuild(hover) }
        }
        parts.append(IconTitle(icon: favicon, title: meta?.title ?? (loading ? "Loading…" : url.host ?? url.absoluteString),
                               width: Self.width - 2 * Self.padding))
        if let description = meta?.description {
            parts.append(label(description, font: .systemFont(ofSize: 12), color: .secondaryLabelColor, lines: 3))
        }
        if textView.isPrivateNote {
            parts.append(label("This note is private, so its links are not looked up.", font: .systemFont(ofSize: 11),
                               color: .tertiaryLabelColor, lines: 2))
        }
        parts.append(label(address, font: .systemFont(ofSize: 11), color: .tertiaryLabelColor))

        buttons.append(button("Open", symbol: "safari") { [weak self] in self?.follow(url, split: false) })
        buttons.append(copyButton(url))
        if hover.isBare, let title = meta?.title {
            buttons.append(button("Use Title", symbol: "textformat") { [weak self] in
                self?.hide()
                textView.replaceLink(hover.range, with: title, url: url)
            })
        }
    }

    private func buildNote(title: String, textView: OutlineTextView, parts: inout [NSView], buttons: inout [NSButton]) {
        guard let found = Self.noteSource?(title) else {
            parts.append(label(title, font: .systemFont(ofSize: 13, weight: .semibold)))
            parts.append(label("There is no note by this name yet.", font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
            buttons.append(button("Make Note", symbol: "square.and.pencil") { [weak self] in
                guard let url = URL.wiki(title) else { return }
                self?.follow(url, split: false)
            })
            return
        }
        let entry = NoteIndex.entry(path: found.ref.path, source: found.text)
        let name = found.ref.day.map { OpenQuickly.dayTitle($0) } ?? entry.title
        parts.append(label(name, font: .systemFont(ofSize: 13, weight: .semibold)))
        // The note's own title heading is the card's name; the rest is shown.
        var outline = OutlineMarkdown.parse(found.text)
        if entry.titleIsHeading, let first = outline.rows.first, case .heading(1) = first.kind,
           NoteIndex.foldKey(first.text) == NoteIndex.foldKey(entry.title) {
            outline.rows.removeFirst()
        }
        if outline.rows.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.folded.isEmpty }) {
            parts.append(label("Empty note", font: .systemFont(ofSize: 12).adding(.italic), color: .tertiaryLabelColor))
        } else {
            parts.append(NotePreview(rows: outline.rows, images: textView.images, width: Self.width - 2 * Self.padding))
        }
        let url = URL.wiki(title)!
        buttons.append(button("Open", symbol: "arrow.right") { [weak self] in self?.follow(url, split: false) })
        buttons.append(button("Open in Split View", symbol: "rectangle.split.2x1") { [weak self] in self?.follow(url, split: true) })
    }

    private func follow(_ url: URL, split: Bool) {
        let owner = owner
        hide()
        if let owner { owner.navigator?.outlineView(owner, open: url, inSplit: split) }
    }

    private func copyButton(_ url: URL) -> NSButton {
        button("Copy", symbol: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }

    // MARK: Parts

    private func label(_ text: String, font: NSFont, color: NSColor = .labelColor, lines: Int = 1) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.maximumNumberOfLines = lines
        // Wrapped, with only the last line that fits cut short.
        field.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        field.cell?.truncatesLastVisibleLine = true
        field.isSelectable = false
        return field
    }

    private func button(_ title: String, symbol: String, action: @escaping () -> Void) -> NSButton {
        let button = ActionButton(title: title, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return button
    }

    private func layout(_ parts: [NSView], buttons: [NSButton]) {
        let inner = Self.width - 2 * Self.padding
        var y = Self.padding
        for part in parts {
            let height: CGFloat
            if let field = part as? NSTextField {
                height = ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 1000)).height ?? 16)
            } else if let preview = part as? SizedView {
                height = preview.height
            } else {
                part.frame = NSRect(x: 0, y: 0, width: inner, height: 40)
                part.layoutSubtreeIfNeeded()
                height = max(part.fittingSize.height, 18)
            }
            part.frame = NSRect(x: Self.padding, y: y, width: inner, height: height)
            content.addSubview(part)
            y += height + 6
        }
        if !buttons.isEmpty {
            y += 4
            var x = Self.padding
            for button in buttons {
                let size = button.fittingSize
                button.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
                content.addSubview(button)
                x += size.width + 6
            }
            y += buttons.map(\.fittingSize.height).max() ?? 0
        }
        content.frame = NSRect(x: 0, y: 0, width: Self.width, height: ceil(y + Self.padding))
    }
}

/// A page's icon, and its title beside it, over two lines at most.
private final class IconTitle: NSView, SizedView {
    let height: CGFloat

    init(icon: NSImage?, title: String, width: CGFloat) {
        let image = NSImageView(image: icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!)
        image.imageScaling = .scaleProportionallyUpOrDown
        if icon == nil { image.contentTintColor = .secondaryLabelColor }
        let field = NSTextField(wrappingLabelWithString: title)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byWordWrapping
        field.cell?.truncatesLastVisibleLine = true
        field.isSelectable = false
        let textWidth = width - 26
        let textHeight = ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 1000)).height ?? 17)
        height = max(textHeight, 18)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        image.frame = NSRect(x: 0, y: 0, width: 18, height: 18)
        field.frame = NSRect(x: 26, y: 0, width: textWidth, height: textHeight)
        addSubview(image)
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
}

/// A view that knows how tall it is.
protocol SizedView: NSView {
    var height: CGFloat { get }
}

/// A note, as the editor shows it, small, read only, and cut off with a
/// fade when it runs longer than the card.
private final class NotePreview: NSView, SizedView {
    private let editor = OutlineTextView(metrics: OutlineMetrics(fontSize: 12))
    let height: CGFloat
    private static let maxHeight: CGFloat = 220

    init(rows: [Row], images: ImageStore?, width: CGFloat) {
        editor.images = images
        if var first = rows.first {
            // The first row starts the card; the space before it is the card's.
            first.gap = []
            editor.load([first] + rows.dropFirst())
        } else {
            editor.load(rows)
        }
        editor.isEditable = false
        editor.isSelectable = false
        editor.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        editor.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        var used = editor.layoutManager?.usedRect(for: editor.textContainer!).height ?? 0
        if editor.layoutManager?.extraLineFragmentTextContainer != nil {
            used -= editor.layoutManager?.extraLineFragmentRect.height ?? 0
        }
        used = ceil(used)
        height = min(used, Self.maxHeight)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        editor.frame = NSRect(x: 0, y: 0, width: width, height: used)
        addSubview(editor)
        wantsLayer = true
        if used > Self.maxHeight {
            let fade = CAGradientLayer()
            fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            fade.locations = [0, 0.8, 1]
            // The view is flipped: its layer's top is y = 0.
            fade.startPoint = CGPoint(x: 0.5, y: 0)
            fade.endPoint = CGPoint(x: 0.5, y: 1)
            fade.frame = NSRect(x: 0, y: 0, width: width, height: height)
            layer?.mask = fade
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A post, drawn as its card, sized to the width it has.
private final class TweetView: NSView, SizedView {
    private let tweet: Tweet
    private let images: ImageStore
    let height: CGFloat

    init(tweet: Tweet, images: ImageStore, width: CGFloat) {
        self.tweet = tweet
        self.images = images
        let natural = TweetCard.size(of: tweet)
        height = ceil(natural.height * width / natural.width)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { TweetCard.draw(tweet, in: bounds, images: images) }
}

/// A button that runs a closure.
private final class ActionButton: NSButton {
    private var run: (() -> Void)?

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        run = action
        target = self
        self.action = #selector(fire(_:))
    }

    @objc private func fire(_ sender: Any?) { run?() }
}

/// The card's window: it never takes the keyboard, and says when the
/// pointer comes and goes.
final class HoverPanel: NSPanel {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var area: NSTrackingArea?

    override var canBecomeKey: Bool { false }

    var containsPointer: Bool { frame.contains(NSEvent.mouseLocation) }

    override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        guard let view = contentView else { return }
        if let area { view.removeTrackingArea(area) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        view.addTrackingArea(tracking)
        area = tracking
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
