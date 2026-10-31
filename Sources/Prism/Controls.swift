import AppKit
import PrismCore
import ReflectUI

/// One mark on the scrubber: a day or week, a heading, or a topic.
struct ScrubMark {
    var y: CGFloat
    var title: String
    var detail: String?
    /// 3 for a day or week, 2 for a heading, 1 for a topic.
    var rank: Int
    /// A week's mark, in a shade of its own.
    var isWeek = false
}

/// A place in the graph to go: a note, by its path.
struct Place: Equatable {
    var title: String
    var path: String
    var detail: String? = nil
    /// What its frontmatter says of it, shown beside its name.
    var flags: NoteFlags = []
    /// A row in it, gone to: what it is under, shown over it — the note,
    /// then the rows — and the edit it was.
    var trail: String? = nil
    var edit: RecentEdits.Edit? = nil
    /// A row of the note open, by index: Move to Heading's.
    var row: Int? = nil
    /// Its cover, shown small before its name.
    var cover: String? = nil
    /// Found by what it says: the words, to show where once it is open.
    var words: [String]? = nil

    /// A cover's picture, for the lists' thumbnails: the window's store's.
    @MainActor static var coverImage: ((String) -> NSImage?)?

    /// A thumbnail of a cover — or nothing, keeping its room — before a name.
    @MainActor static func thumbnail(_ cover: String?) -> CoverBanner {
        let view = CoverBanner()
        view.topOnly = false
        view.radius = 4
        view.image = cover.flatMap { coverImage?($0) }
        view.isHidden = cover == nil
        return view
    }
}

/// A column's ×, or an inbox note's: faint until the pointer is on it.
final class CloseButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    private lazy var restingTint = contentTintColor ?? Ink.faint

    init(symbol: String = "xmark", pointSize: CGFloat = 10, toolTip: String = "Close Column") {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: symbol == "xmark" ? .semibold : .regular))
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = symbol == "xmark" ? Ink.faint : Ink.secondary
        self.toolTip = toolTip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; contentTintColor = Ink.text }
    override func mouseExited(with event: NSEvent) { hovering = false; contentTintColor = restingTint }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            // Round, as the capsules it sits in are: a circle, or a pill.
            Ink.hover.setFill()
            let radius = min(bounds.width, bounds.height) / 2
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        super.draw(dirtyRect)
    }
}
