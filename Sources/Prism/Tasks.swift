import AppKit
import ReflectCore
import PrismCore
import ReflectUI

typealias TaskSlice = NoteSlice

/// A task in the column, editable where it is: what is typed goes back to
/// its place in its note.
@MainActor
final class TaskEditor: NSObject, NSTextViewDelegate {
    let view: OutlineTextView
    var slice: TaskSlice
    /// Told, a moment after typing stops, to write it back.
    var onEdit: ((TaskEditor) -> Void)?
    /// Told as it is typed in: it may want another height.
    var onResize: (() -> Void)?
    /// Told when the keyboard leaves it: what changed meanwhile can be shown.
    var onLeave: (() -> Void)?
    /// Words to mark where they are — what a search found — as a
    /// highlighter would, never in the note itself.
    var highlight: [String] = [] { didSet { markHighlights() } }

    private func markHighlights() {
        guard let layout = view.layoutManager else { return }
        let text = view.string as NSString
        let all = NSRange(location: 0, length: text.length)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        for word in highlight where !word.isEmpty {
            var from = 0
            while from < text.length {
                let found = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive],
                                       range: NSRange(location: from, length: text.length - from))
                guard found.location != NSNotFound else { break }
                layout.addTemporaryAttribute(.backgroundColor, value: Ink.marked, forCharacterRange: found)
                from = NSMaxRange(found)
            }
        }
    }
    private var timer: Timer?

    init(slice: TaskSlice, metrics: OutlineMetrics, images: ImageStore, navigator: OutlineTextViewNavigator) {
        self.slice = slice
        view = OutlineTextView(metrics: metrics)
        super.init()
        view.images = images
        view.navigator = navigator
        view.load(slice.rows)
        view.delegate = self
    }

    /// The rows as edited, back at their depth in the note.
    var rowsInNote: [Row] {
        Row.unfold(view.rows).map { row in
            var row = row
            row.depth += slice.depth
            return row
        }
    }

    func textDidChange(_ notification: Notification) {
        if !highlight.isEmpty { markHighlights() }
        onResize?()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onEdit?(self)
            }
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        flush()
        onLeave?()
    }

    /// Writes now what is waiting to be written.
    func flush() {
        guard let timer, timer.isValid else { return }
        timer.invalidate()
        onEdit?(self)
    }

    func height(width: CGFloat) -> CGFloat {
        guard let layout = view.layoutManager, let container = view.textContainer else { return 0 }
        if abs(container.size.width - width) > 0.5 {
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        var height = layout.usedRect(for: container).height
        if layout.extraLineFragmentTextContainer != nil { height -= layout.extraLineFragmentRect.height }
        return ceil(max(height, view.metrics.fontSize * 1.4))
    }
}

/// The path to tasks, over them, as focusing shows it: the note, then
/// each item they are under. Clicked, the note opens on its own.
final class TaskPath: NSView {
    var onClick: ((_ newColumn: Bool) -> Void)?
    private let label = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    init(steps: [String], face: Typeface, size: CGFloat) {
        super.init(frame: .zero)
        let text = NSMutableAttributedString()
        let font = face.font(size: round(size * 0.8), weight: .medium)
        for (i, step) in steps.enumerated() {
            if i > 0 { text.append(NSAttributedString(string: "  ›  ", attributes: [.font: font, .foregroundColor: Ink.faint])) }
            text.append(NSAttributedString(string: step, attributes: [.font: font, .foregroundColor: Ink.secondary]))
        }
        label.attributedStringValue = text
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        toolTip = "Open “\(steps.first ?? "")” (⌘-click: in the column beside; ⇧⌘-click: in a new one)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var height: CGFloat { ceil(label.intrinsicContentSize.height) + 2 }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 1, width: bounds.width, height: ceil(label.intrinsicContentSize.height))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?(event.modifierFlags.contains(.command)) }
}

