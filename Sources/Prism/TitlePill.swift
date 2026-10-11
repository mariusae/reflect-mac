import AppKit
import ReflectUI

/// The note being read, named at the top of its column on a glass pill —
/// its cover small and round before the name, when it has one. Clicked,
/// the note's own menu: inbox, pin, cover, links, the Trash.
final class TitlePill: NSButton {
    private let glass = NSGlassEffectView()
    private let picture = CoverBanner()
    private let label = NSTextField(labelWithString: "")
    static let height: CGFloat = 34

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        glass.cornerRadius = Self.height / 2
        addSubview(glass)
        picture.topOnly = false
        picture.radius = 12
        addSubview(picture)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// What it names, in what, and the cover before it, if any.
    func show(_ name: String, font: NSFont, cover: NSImage?) {
        label.attributedStringValue = NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: Ink.text])
        picture.image = cover
        picture.isHidden = cover == nil
        setAccessibilityLabel(name)
        needsLayout = true
    }

    private var lead: CGFloat { picture.isHidden ? 16 : 5 + 24 + 8 }

    /// As wide as its name wants, within so much.
    func fittingWidth(within most: CGFloat) -> CGFloat {
        min(most, lead + ceil(label.attributedStringValue.size().width) + 18)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        picture.frame = NSRect(x: 5, y: (bounds.height - 24) / 2, width: 24, height: 24)
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: lead, y: ((bounds.height - height) / 2).rounded(), width: max(0, bounds.width - lead - 14), height: height)
    }
}
