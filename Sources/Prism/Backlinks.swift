import AppKit
import ReflectCore
import PrismCore
import ReflectUI

/// What a column is made of: blocks one under another, each as tall as it
/// says it wants to be at the column's width — a day, a note, a note's
/// backlinks — each with its marks for the scrubber.
@MainActor
protocol ColumnBlock: NSView {
    func desiredHeight(width: CGFloat) -> CGFloat
    /// The block's marks, from its top: among other notes — in the
    /// timeline, the inbox — its own name too.
    func scrubMarks(listed: Bool) -> [ScrubMark]
}

extension DayView: ColumnBlock {
    func scrubMarks(listed: Bool) -> [ScrubMark] {
        let name = Column.name(of: ref)
        var marks: [ScrubMark] = []
        if listed {
            marks.append(ScrubMark(y: 0, title: name.title, detail: name.detail, rank: 3,
                                   isWeek: GraphPaths.week(fromWeeklyPath: ref.path) != nil))
        }
        marks += Self.outlineMarks(in: editor).map {
            ScrubMark(y: $0.y, title: $0.title, detail: listed ? name.title : nil, rank: $0.rank)
        }
        return marks
    }

    /// Where each heading is in an outline, and each topic — a top-level
    /// item with items under it — from the top of the view it is in.
    static func outlineMarks(in editor: OutlineTextView) -> [(y: CGFloat, title: String, rank: Int)] {
        guard let layout = editor.layoutManager, let container = editor.textContainer else { return [] }
        let rows = editor.rows
        let ranges = editor.paragraphRanges
        var marks: [(CGFloat, String, Int)] = []
        for (i, row) in rows.enumerated() where i < ranges.count {
            let rank: Int
            if case .heading = row.kind {
                rank = 2
            } else if row.depth == 0, row.kind.isListItem, row.isFolded || (i + 1 < rows.count && rows[i + 1].depth > 0) {
                rank = 1
            } else {
                continue
            }
            let title = InlineMarkup.plainText(row.text)
            guard !title.isEmpty else { continue }
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: ranges[i].location, length: max(1, ranges[i].length)),
                                           actualCharacterRange: nil)
            let y = editor.frame.minY + editor.textContainerOrigin.y + layout.boundingRect(forGlyphRange: glyphs, in: container).minY
            marks.append((y, title, rank))
        }
        return marks
    }
}

/// A column's name, in small capitals, and how many are in it in a pill
/// beside it — the rest is clear from what is under it.
final class ColumnLabel: NSView {
    private let label = NSTextField(labelWithString: "")
    private let pill = NSView()
    private let number = NSTextField(labelWithString: "")
    var metrics: OutlineMetrics { didSet { if metrics.typography != oldValue.typography || metrics.fontSize != oldValue.fontSize { style() } } }
    private var title: String
    /// How many: none shown while nil or naught.
    var count: Int? { didSet { if count != oldValue { style() } } }

    override var isFlipped: Bool { true }

    init(_ title: String, metrics: OutlineMetrics) {
        self.title = title
        self.metrics = metrics
        super.init(frame: .zero)
        pill.wantsLayer = true
        number.alignment = .center
        pill.addSubview(number)
        addSubview(label)
        addSubview(pill)
        style()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var size: CGFloat { round(metrics.fontSize * 0.68) }

    private func style() {
        let typography = metrics.typography
        label.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [
            .font: Typography.font(typography.headingFamily, face: typography.headingFace, size: size, weight: .semibold),
            .foregroundColor: Ink.secondary, .kern: 1.0,
        ])
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        number.attributedStringValue = NSAttributedString(string: count.map(String.init) ?? "", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
            .foregroundColor: Ink.secondary, .paragraphStyle: centred,
        ])
        pill.isHidden = (count ?? 0) == 0
        needsLayout = true
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ceil(label.intrinsicContentSize.height) + 4)
    }

    override func layout() {
        super.layout()
        let labelSize = label.intrinsicContentSize
        let height = ceil(labelSize.height) + 4
        // Room for the last letter's spacing too, which the label leaves out.
        let width = ceil(label.attributedStringValue.size().width) + 6
        label.frame = NSRect(x: 0, y: 2, width: width, height: ceil(labelSize.height))
        let numberSize = number.intrinsicContentSize
        let pillWidth = max(height, ceil(numberSize.width) + 12)
        pill.frame = NSRect(x: label.frame.maxX + 2, y: 0, width: pillWidth, height: height)
        // Across the whole pill, centred: a label's own inset sets a
        // narrow one's figures off to the right.
        number.frame = NSRect(x: 0, y: ((height - ceil(numberSize.height)) / 2).rounded(), width: pillWidth, height: ceil(numberSize.height))
        pill.layer?.cornerRadius = height / 2
    }

    override func updateLayer() {
        super.updateLayer()
        effectiveAppearance.performAsCurrentDrawingAppearance { pill.layer?.backgroundColor = Ink.rule.cgColor }
    }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The head of a column of many — the inbox, the tasks: its name, and how
/// many there are in it.
final class InboxHeader: NSView, ColumnBlock {
    private let label: ColumnLabel
    var metrics: OutlineMetrics { didSet { label.metrics = metrics; needsLayout = true } }
    var count = 0 { didSet { label.count = count } }

    override var isFlipped: Bool { true }

    init(metrics: OutlineMetrics, title: String = "Inbox") {
        self.metrics = metrics
        label = ColumnLabel(title, metrics: metrics)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var column: NSRect {
        let column = min(metrics.columnWidth, bounds.width - 48)
        return NSRect(x: ((bounds.width - column) / 2).rounded(), y: 0, width: column, height: 0)
    }

    func desiredHeight(width: CGFloat) -> CGFloat {
        round(metrics.fontSize * 1.2) + label.intrinsicContentSize.height + round(metrics.fontSize * 0.2)
    }

    override func layout() {
        super.layout()
        let x = column.minX + metrics.indent - 2
        label.frame = NSRect(x: x, y: round(metrics.fontSize * 1.2), width: column.maxX - x, height: label.intrinsicContentSize.height)
    }

    func scrubMarks(listed: Bool) -> [ScrubMark] { [] }
}

/// Over a topic's backlinks, under the topic: how many notes link to it.
final class InlineBacklinksHeader: NSView, ColumnBlock {
    private let label: ColumnLabel
    private let metrics: OutlineMetrics

    override var isFlipped: Bool { true }

    init(count: Int, metrics: OutlineMetrics) {
        self.metrics = metrics
        label = ColumnLabel("Backlinks", metrics: metrics)
        label.count = count
        super.init(frame: .zero)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func desiredHeight(width: CGFloat) -> CGFloat { round(metrics.fontSize * 2) + label.intrinsicContentSize.height }

    override func layout() {
        super.layout()
        let column = min(metrics.columnWidth, bounds.width - 48)
        let x = ((bounds.width - column) / 2).rounded() + metrics.indent - 2
        label.frame = NSRect(x: x, y: round(metrics.fontSize * 1.6), width: bounds.width - x - 24, height: label.intrinsicContentSize.height)
    }

    func scrubMarks(listed: Bool) -> [ScrubMark] {
        [ScrubMark(y: round(metrics.fontSize * 1.6), title: "Backlinks", detail: nil, rank: 2)]
    }
}

/// The head of a backlinks column: the note whose links these are, and how
/// many notes link to it.
final class BacklinksHeader: NSView, ColumnBlock {
    private let kicker: ColumnLabel
    private let title = NSTextField(labelWithString: "")
    private let metrics: OutlineMetrics
    var onOpen: ((_ newColumn: Bool) -> Void)?

    override var isFlipped: Bool { true }

    init(note: String, count: Int?, metrics: OutlineMetrics) {
        self.metrics = metrics
        kicker = ColumnLabel("Backlinks", metrics: metrics)
        kicker.count = count
        super.init(frame: .zero)
        let typography = metrics.typography
        title.stringValue = note
        title.font = Typography.font(typography.headingFamily, face: typography.headingFace,
                                     size: round(metrics.fontSize * 1.45), weight: .bold)
        title.lineBreakMode = .byTruncatingTail
        addSubview(kicker)
        addSubview(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func column(_ width: CGFloat) -> NSRect {
        let column = min(metrics.columnWidth, width - 48)
        return NSRect(x: ((width - column) / 2).rounded(), y: 0, width: column, height: 0)
    }

    func desiredHeight(width: CGFloat) -> CGFloat {
        round(metrics.fontSize * 2.2) + ceil(kicker.intrinsicContentSize.height) + 4 + ceil(title.intrinsicContentSize.height)
            + round(metrics.fontSize * 0.6)
    }

    override func layout() {
        super.layout()
        let column = column(bounds.width)
        let x = column.minX + metrics.indent - 2
        var y = round(metrics.fontSize * 2.2)
        let kickerHeight = ceil(kicker.intrinsicContentSize.height)
        kicker.frame = NSRect(x: x, y: y, width: column.maxX - x, height: kickerHeight)
        y += kickerHeight + 4
        title.frame = NSRect(x: x, y: y, width: column.maxX - x, height: ceil(title.intrinsicContentSize.height))
    }

    override func mouseUp(with event: NSEvent) {
        if title.frame.contains(convert(event.locationInWindow, from: nil)) {
            onOpen?(event.modifierFlags.contains(.command))
        }
    }

    func scrubMarks(listed: Bool) -> [ScrubMark] { [] }
}

/// A note among others — linking to one, or found by a search: its name — a
/// click opens it, ⌘-click in a column of its own — and the rows where it
/// links, or the words were found, each with what is under it, editable.
final class BacklinkBlock: NSView, ColumnBlock {
    let path: String
    /// What each place in it is called, counted: a link, a match.
    private let unit: String
    private let name: String
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    /// Each place it links from: the path to it, and it, editable there.
    private let places: [(path: TaskPath?, editor: TaskEditor)]
    var editors: [TaskEditor] { places.map(\.editor) }
    private let metrics: OutlineMetrics
    private let disclosure = NSButton()
    private let linkCount: String?
    var onOpen: ((_ newColumn: Bool) -> Void)?
    /// Folded or unfolded: told, to remember it and lay the column out again.
    var onFold: ((Bool) -> Void)?
    /// Its links hidden, its name alone shown.
    private(set) var folded: Bool

    override var isFlipped: Bool { true }

    /// `slices`: where in the linking note its links are; `editable`,
    /// whether what is typed there can go back to it.
    init(path: String, slices: [TaskSlice], editable: Bool, name: String, detail: String?, folded: Bool, unit: String = "link",
         highlight: [String] = [], metrics: OutlineMetrics, face: Typeface, images: ImageStore, navigator: OutlineTextViewNavigator) {
        self.path = path
        self.unit = unit
        self.name = name
        self.metrics = metrics
        self.folded = folded
        linkCount = detail
        places = slices.map { slice in
            let editor = TaskEditor(slice: slice, metrics: metrics, images: images, navigator: navigator)
            editor.highlight = highlight
            editor.view.isEditable = editable
            let path = slice.crumbs.isEmpty ? nil : TaskPath(steps: slice.crumbs, face: face, size: metrics.fontSize)
            return (path, editor)
        }
        super.init(frame: .zero)
        let typography = metrics.typography
        title.stringValue = name
        title.font = Typography.font(typography.headingFamily, face: typography.headingFace,
                                     size: round(metrics.fontSize * 1.08), weight: .semibold)
        title.textColor = Ink.text
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = "Open “\(name)” (⌘-click: in the column beside; ⇧⌘-click: in a new one)"
        self.detail.stringValue = detail ?? ""
        self.detail.font = Typography.font(typography.bodyFamily, face: typography.bodyFace, size: round(metrics.fontSize * 0.82))
        self.detail.textColor = Ink.secondary
        addSubview(title)
        addSubview(self.detail)
        for place in places {
            if let path = place.path {
                path.onClick = { [weak self] newColumn in self?.onOpen?(newColumn) }
                addSubview(path)
            }
            addSubview(place.editor.view)
        }
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.contentTintColor = Ink.faint
        disclosure.target = self
        disclosure.action = #selector(toggle)
        addSubview(disclosure)
        showFolded()
    }

    func toggleForScript() { toggle() }

    @objc private func toggle() {
        folded.toggle()
        showFolded()
        onFold?(folded)
    }

    /// Shows it folded, or open: the chevron, the links, and — folded — how
    /// many links there are, beside its name.
    private func showFolded() {
        disclosure.image = NSImage(systemSymbolName: folded ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: round(metrics.fontSize * 0.62), weight: .semibold))
        disclosure.toolTip = folded ? "Show the links" : "Hide the links"
        for place in places {
            place.path?.isHidden = folded
            place.editor.view.isHidden = folded
        }
        let count = max(places.count, 1)
        detail.stringValue = folded ? [linkCount, "\(count) \(count == 1 ? unit : unit + (unit.hasSuffix("ch") ? "es" : "s"))"].compactMap { $0 }.joined(separator: " · ")
            : linkCount ?? ""
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func column(_ width: CGFloat) -> NSRect {
        let column = min(metrics.columnWidth, width - 48)
        return NSRect(x: ((width - column) / 2).rounded(), y: 0, width: column, height: 0)
    }

    private var top: CGFloat { round(metrics.fontSize * 1.4) }
    private var titleHeight: CGFloat { ceil(title.intrinsicContentSize.height) }
    private var spacing: CGFloat { round(metrics.fontSize * 0.5) }

    func desiredHeight(width: CGFloat) -> CGFloat {
        let column = column(width)
        var height = top + titleHeight + spacing
        if !folded {
            for place in places {
                if let path = place.path { height += path.height + 2 }
                height += place.editor.height(width: column.width) + spacing
            }
        }
        return height + round(metrics.fontSize * (folded ? 0.3 : 0.8))
    }

    override func layout() {
        super.layout()
        let column = column(bounds.width)
        let x = column.minX + metrics.indent - 2
        let chevron = round(metrics.fontSize * 1.2)
        disclosure.frame = NSRect(x: x - chevron - 4, y: top + round((titleHeight - chevron) / 2), width: chevron, height: chevron)
        let detailWidth = ceil(detail.intrinsicContentSize.width) + 4
        title.frame = NSRect(x: x, y: top, width: max(40, column.maxX - x - detailWidth - 8), height: titleHeight)
        let size = title.attributedStringValue.size()
        let detailHeight = ceil(detail.intrinsicContentSize.height)
        detail.frame = NSRect(x: min(title.frame.maxX, x + ceil(size.width) + 10), y: title.frame.maxY - detailHeight - 1,
                              width: detailWidth, height: detailHeight)
        var y = top + titleHeight + spacing
        for place in places where !folded {
            if let path = place.path {
                path.frame = NSRect(x: x, y: y, width: column.maxX - x, height: path.height)
                y += path.height + 2
            }
            let height = place.editor.height(width: column.width)
            place.editor.view.frame = NSRect(x: column.minX, y: y, width: column.width, height: height)
            y += height + spacing
        }
    }

    override func mouseUp(with event: NSEvent) {
        if title.frame.contains(convert(event.locationInWindow, from: nil)) {
            onOpen?(event.modifierFlags.contains(.command))
        }
    }

    func scrubMarks(listed: Bool) -> [ScrubMark] {
        [ScrubMark(y: 0, title: name, detail: places.count > 1 ? "\(places.count) \(unit + (unit.hasSuffix("ch") ? "es" : "s"))" : nil, rank: 3)]
    }
}
