import AppKit
import ReflectCore
import ReflectUI

/// A note in a line or two, as a list shows notes to choose among — the
/// inbox, the pinned: its cover, or a note's mark, small; its name; its
/// first words; how long since it changed; in the inbox, its Done.
final class NoteListRow: NSView, ColumnBlock {
    let ref: NoteRef
    var onChoose: ((NoteRef) -> Void)?
    var onDone: ((NoteRef) -> Void)?
    var isChosen = false { didSet { if isChosen != oldValue { needsDisplay = true } } }
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    private let picture: CoverBanner
    private let mark = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let words = NSTextField(labelWithString: "")
    private let age = NSTextField(labelWithString: "")
    private let done: CloseButton?

    static let height: CGFloat = 64
    override var isFlipped: Bool { true }

    init(ref: NoteRef, source: String, cover: String?, when: String?, inbox: Bool, metrics: OutlineMetrics, face: Typeface) {
        self.ref = ref
        picture = Place.thumbnail(cover)
        done = inbox ? CloseButton(symbol: "checkmark.circle", pointSize: 15, toolTip: "Done: Remove from Inbox") : nil
        super.init(frame: .zero)
        addSubview(picture)
        mark.image = NSImage(systemSymbolName: ref.day != nil ? "calendar" : "doc.text", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        mark.contentTintColor = Ink.secondary
        mark.wantsLayer = true
        mark.layer?.cornerRadius = 6
        mark.layer?.backgroundColor = Ink.text.withAlphaComponent(0.05).cgColor
        mark.isHidden = cover != nil
        addSubview(mark)
        name.stringValue = Column.name(of: ref).title
        name.font = face.typography().headingFont(size: 14, weight: .semibold)
        name.textColor = Ink.text
        words.stringValue = Self.firstWords(of: source)
        words.font = face.font(size: 12.5)
        words.textColor = Ink.secondary
        for label in [name, words] { label.lineBreakMode = .byTruncatingTail }
        age.attributedStringValue = NSAttributedString(string: (when ?? "").uppercased(), attributes: face.typography().label(size: 14))
        for view in [name, words, age] as [NSView] { addSubview(view) }
        if let done {
            done.target = self
            done.action = #selector(doneClicked)
            addSubview(done)
        }
        toolTip = name.stringValue
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// What it says first: its first row with words in it, not its title.
    private static func firstWords(of text: String) -> String {
        let rows = OutlineMarkdown.parse(text).rows
        let shown = rows.map { InlineMarkup.plainText($0.text).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if case .heading = rows.first?.kind { return shown.dropFirst().first ?? "" }
        return shown.first ?? ""
    }

    @objc private func doneClicked() { onDone?(ref) }

    func desiredHeight(width: CGFloat) -> CGFloat { Self.height }
    func scrubMarks(listed: Bool) -> [ScrubMark] { [] }

    override func layout() {
        super.layout()
        let side: CGFloat = 40, x: CGFloat = 16
        let tile = NSRect(x: x, y: (bounds.height - side) / 2, width: side, height: side)
        picture.frame = tile
        mark.frame = tile
        let ageSize = age.intrinsicContentSize
        let right = bounds.width - 14 - (done == nil ? 0 : 26)
        done?.frame = NSRect(x: bounds.width - 14 - 22, y: (bounds.height - 22) / 2, width: 22, height: 22)
        let ageWidth = ceil(age.attributedStringValue.size().width) + 6
        age.frame = NSRect(x: right - ageWidth, y: 13, width: ageWidth, height: ceil(ageSize.height))
        let textX = tile.maxX + 12
        name.frame = NSRect(x: textX, y: 11, width: max(0, age.frame.minX - 8 - textX), height: 19)
        words.frame = NSRect(x: textX, y: 32, width: max(0, right - textX), height: 17)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onChoose?(ref) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func draw(_ dirtyRect: NSRect) {
        guard isChosen || hovering else { return }
        (isChosen ? Ink.rule : Ink.hover).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 8, yRadius: 8).fill()
    }
}
