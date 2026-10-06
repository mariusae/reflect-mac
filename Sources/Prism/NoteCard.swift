import AppKit
import ReflectCore
import ReflectUI
import PrismCore

/// A note among others, not shown whole: its card with its name and when,
/// and — in summary — its first picture, what it is about, and a little of
/// what follows. Clicked, the note opens on its own.
final class NoteCardBlock: NSView, ColumnBlock {
    let ref: NoteRef
    let mode: CardMode
    private let card = CardSurface()
    private let title = NSTextField(labelWithString: "")
    private let when = NSTextField(labelWithString: "")
    private let picture = NSImageView()
    private let headline = NSTextField(wrappingLabelWithString: "")
    private let snippet = NSTextField(wrappingLabelWithString: "")
    private let metrics: OutlineMetrics
    private let images: ImageStore
    private var pictureSource: String?
    /// Clicked: the note alone — with ⌘, in the column beside.
    var onOpen: ((_ newColumn: Bool) -> Void)?
    /// Its picture came in: taller now.
    var onResize: (() -> Void)?

    override var isFlipped: Bool { true }

    init(ref: NoteRef, mode: CardMode, name: String, when: String?, source: String, metrics: OutlineMetrics, images: ImageStore) {
        self.ref = ref
        self.mode = mode
        self.metrics = metrics
        self.images = images
        super.init(frame: .zero)
        card.fill = Ink.card
        addSubview(card)
        let typography = metrics.typography
        title.stringValue = ref.day.map(Self.dayName) ?? name
        title.font = typography.headingFont(size: round(metrics.fontSize * 1.45), weight: .bold)
        title.textColor = ref.day == .today ? .controlAccentColor : Ink.text
        title.lineBreakMode = .byTruncatingTail
        self.when.stringValue = when ?? ""
        self.when.font = .systemFont(ofSize: round(metrics.fontSize * 0.85))
        self.when.textColor = Ink.secondary
        self.when.alignment = .right
        for view in [title, self.when] as [NSView] { addSubview(view) }
        guard mode == .summary else { return }
        let summary = NoteSummary.of(source, title: name)
        headline.stringValue = summary.headline ?? ""
        headline.font = Typography.font(typography.bodyFamily, face: typography.bodyFace, size: round(metrics.fontSize * 1.08))
        headline.textColor = Ink.text
        headline.maximumNumberOfLines = 3
        snippet.stringValue = summary.snippet
        snippet.font = Typography.font(typography.bodyFamily, face: typography.bodyFace, size: round(metrics.fontSize * 0.92))
        snippet.textColor = Ink.secondary
        snippet.maximumNumberOfLines = 2
        snippet.lineBreakMode = .byWordWrapping
        snippet.cell?.truncatesLastVisibleLine = true
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 8
        picture.layer?.masksToBounds = true
        pictureSource = summary.picture
        if let source = summary.picture {
            picture.image = images.image(source)
            if picture.image == nil {
                images.whenLoaded(source) { [weak self] in
                    guard let self else { return }
                    picture.image = images.image(source)
                    needsLayout = true
                    onResize?()
                }
            }
        }
        for view in [picture, headline, snippet] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A day as its note's header says it: its year only when not this one.
    private static func dayName(_ day: Day) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(day.year == Day.today.year ? "EEEEMMMMd" : "EEEEMMMMdyyyy")
        return formatter.string(from: day.date ?? Date())
    }

    private func column(_ width: CGFloat) -> NSRect {
        let column = min(metrics.columnWidth, width - 48)
        return NSRect(x: ((width - column) / 2).rounded(), y: 0, width: column, height: 0)
    }

    private var top: CGFloat { CardSurface.spacing + round(metrics.fontSize * 1.1) }
    private var bottom: CGFloat { CardSurface.spacing + round(metrics.fontSize * 1.1) }
    private static let pictureSide: CGFloat = 96

    /// Lays its parts out down a width, or only measures them.
    @discardableResult
    private func place(width: CGFloat, laying: Bool) -> CGFloat {
        let column = column(width)
        let x = column.minX + metrics.indent - 2
        let inner = column.maxX - x
        var y = top
        let titleHeight = ceil(title.intrinsicContentSize.height)
        if laying {
            card.frame = CardSurface.frame(column: column, in: bounds)
            let whenSize = when.intrinsicContentSize
            let whenWidth = ceil(whenSize.width) + 4
            when.frame = NSRect(x: column.maxX - whenWidth, y: y + round((titleHeight - whenSize.height) / 2) + 1, width: whenWidth,
                                height: ceil(whenSize.height))
            title.frame = NSRect(x: x, y: y, width: max(40, inner - whenWidth - 12), height: titleHeight)
        }
        y += titleHeight
        guard mode == .summary else { return y + bottom }
        if picture.image != nil {
            y += round(metrics.fontSize * 0.7)
            if laying { picture.frame = NSRect(x: x, y: y, width: Self.pictureSide, height: Self.pictureSide) }
            y += Self.pictureSide
        } else if laying {
            picture.frame = .zero
        }
        for label in [headline, snippet] where !label.stringValue.isEmpty {
            y += round(metrics.fontSize * 0.5)
            label.preferredMaxLayoutWidth = inner
            let height = ceil(label.sizeThatFits(NSSize(width: inner, height: .greatestFiniteMagnitude)).height)
            if laying { label.frame = NSRect(x: x - 2, y: y, width: inner + 4, height: height) }
            y += height
        }
        return y + bottom
    }

    func desiredHeight(width: CGFloat) -> CGFloat { place(width: width, laying: false) }

    override func layout() {
        super.layout()
        place(width: bounds.width, laying: true)
    }

    var stickyTitle: (title: String, when: String?, today: Bool)? {
        (Column.name(of: ref).title, Column.when(of: ref), ref.day == .today)
    }

    func scrubMarks(listed: Bool) -> [ScrubMark] {
        let name = Column.name(of: ref)
        return [ScrubMark(y: 0, title: name.title, detail: name.detail, rank: 3, isWeek: GraphPaths.week(fromWeeklyPath: ref.path) != nil)]
    }

    // MARK: The pointer

    override func resetCursorRects() { addCursorRect(card.frame, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard card.frame.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?(event.modifierFlags.contains(.command))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Open") { [weak self] in self?.onOpen?(false) })
        menu.addItem(.separator())
        for item in NoteCardBlock.showAsItems(ref.path) { menu.addItem(item) }
        return menu
    }

    /// Full, Summary, Collapsed: how a note's card shows it, the one it
    /// shows checked.
    static func showAsItems(_ path: String) -> [NSMenuItem] {
        let current = CardModes.mode(path)
        return [CardMode.full, .summary, .collapsed].map { mode in
            let item = ClosureMenuItem(title: "Show as \(mode.name)") { CardModes.set(mode, for: path) }
            item.state = mode == current ? .on : .off
            return item
        }
    }
}
