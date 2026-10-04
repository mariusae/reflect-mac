import AppKit
import ReflectCore
import PrismCore
import ReflectUI

/// Days in the timeline with no note: a quiet `⋯` and the dates it stands
/// for, clicked to show the last few of them, empty, to write in.
final class GapView: NSView, ColumnBlock {
    let gap: TimelineGap
    private let dots = NSTextField(labelWithString: "⋯")
    private let label = NSTextField(labelWithString: "")
    private let metrics: OutlineMetrics
    private var hovering = false { didSet { if hovering != oldValue { style() } } }
    /// Told when clicked: some of its days to show.
    var onReveal: ((TimelineGap) -> Void)?

    override var isFlipped: Bool { true }

    init(gap: TimelineGap, metrics: OutlineMetrics) {
        self.gap = gap
        self.metrics = metrics
        super.init(frame: .zero)
        label.stringValue = Self.describe(gap)
        addSubview(dots)
        addSubview(label)
        style()
        toolTip = gap.count > Timeline.revealCount ? "Show the last \(Timeline.revealCount) of these days" : "Show these days"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `Sep 21 – 25 · 5 days`, or the one day it is.
    static func describe(_ gap: TimelineGap) -> String {
        guard let from = gap.from.date, let to = gap.to.date else { return "" }
        if gap.count == 1 {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
            return formatter.string(from: from)
        }
        let formatter = DateIntervalFormatter()
        formatter.dateTemplate = gap.from.year == gap.to.year ? "MMMd" : "MMMdyyyy"
        return formatter.string(from: from, to: to) + " · \(gap.count) days"
    }

    private func style() {
        let color = hovering ? Ink.text : Ink.secondary
        dots.font = .systemFont(ofSize: round(metrics.fontSize * 1.3), weight: .bold)
        dots.textColor = color
        label.font = Typography.font(metrics.typography.headingFamily, face: metrics.typography.headingFace,
                                     size: round(metrics.fontSize * 0.72), weight: .medium)
        label.textColor = hovering ? Ink.secondary : Ink.faint
        needsLayout = true
    }

    func desiredHeight(width: CGFloat) -> CGFloat { round(metrics.fontSize * 3) }

    override func layout() {
        super.layout()
        let column = min(metrics.columnWidth, bounds.width - 48)
        let x = ((bounds.width - column) / 2).rounded() + metrics.indent - 2
        let dotsSize = dots.intrinsicContentSize
        let labelSize = label.intrinsicContentSize
        let middle = (bounds.height / 2).rounded()
        dots.frame = NSRect(x: x, y: middle - dotsSize.height / 2 - 1, width: dotsSize.width, height: dotsSize.height)
        label.frame = NSRect(x: dots.frame.maxX + 8, y: middle - labelSize.height / 2, width: ceil(labelSize.width) + 4, height: labelSize.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onReveal?(gap) }
    }

    func scrubMarks(listed: Bool) -> [ScrubMark] { [] }
}
