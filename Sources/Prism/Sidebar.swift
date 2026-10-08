import AppKit
import PrismCore
import ReflectUI

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

/// The notes to hand, on a card that slides out from the window's left
/// edge when the pointer goes there, and back when it leaves; or pinned.
final class Sidebar: NSView {
    var onOpen: ((Place) -> Void)?
    private let card = NSView()
    private let scroll = NSScrollView()
    private let list = FlippedView()
    /// Headers and rows, top to bottom.
    private var entries: [NSView] = []

    static let width: CGFloat = 248

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 16
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.5
        addSubview(card)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        scroll.documentView = list
        card.addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var pinned = false { didSet { layer?.shadowOpacity = pinned ? 0 : 0.14 } }

    // The row under the pointer, lit — one at a time, found as the pointer
    // moves, so none is left lit by a move too quick to tell of leaving.

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) { light(at: event) }
    override func mouseEntered(with event: NSEvent) { light(at: event) }
    override func mouseExited(with event: NSEvent) { light(at: nil) }
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        light(at: event)
    }

    private func light(at event: NSEvent?) {
        let point = event.map { list.convert($0.locationInWindow, from: nil) }
        for case let row as SidebarRow in entries {
            row.hovering = point.map { row.frame.contains($0) } ?? false
        }
    }

    /// No row lit: the sidebar going away.
    func clearHover() { light(at: nil) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.borderColor = Ink.rule.cgColor
            card.layer?.backgroundColor = Ink.shelf.cgColor
        }
    }

    func show(_ sections: [(title: String, places: [Place])], current: String?, face: Typeface) {
        entries.forEach { $0.removeFromSuperview() }
        entries = []
        for section in sections where !section.places.isEmpty {
            let header = NSTextField(labelWithAttributedString: NSAttributedString(string: section.title.uppercased(), attributes: [
                .font: face.font(size: 10.5, weight: .semibold), .kern: 0.9, .foregroundColor: Ink.faint,
            ]))
            list.addSubview(header)
            entries.append(header)
            // Room for a thumbnail in each row, when any has a cover.
            let thumbnails = section.places.contains { $0.cover != nil }
            for place in section.places {
                let row = SidebarRow(place: place, face: face, selected: place.path == current, thumbnail: thumbnails)
                row.onClick = { [weak self] in self?.onOpen?(place) }
                list.addSubview(row)
                entries.append(row)
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.borderColor = Ink.rule.cgColor
            card.layer?.backgroundColor = Ink.shelf.cgColor
        }
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 44)
        let width = scroll.contentSize.width
        var y: CGFloat = 4
        for entry in entries {
            if entry is SidebarRow {
                entry.frame = NSRect(x: 8, y: y, width: width - 16, height: 28)
                y += 29
            } else {
                if y > 4 { y += 14 }
                entry.frame = NSRect(x: 18, y: y, width: width - 36, height: 16)
                y += 22
            }
        }
        list.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 12, scroll.contentSize.height))
    }
}

final class SidebarRow: NSView {
    var onClick: (() -> Void)?
    private let label: NSTextField
    private let badges = NoteBadges()
    private let selected: Bool
    /// Its cover, small before the name; nil with no room kept for one.
    private let thumbnail: CoverBanner?
    /// Whether the pointer is on it: the sidebar says, as it moves.
    var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    init(place: Place, face: Typeface, selected: Bool, thumbnail: Bool = false) {
        self.selected = selected
        label = NSTextField(labelWithString: place.title)
        self.thumbnail = thumbnail ? Place.thumbnail(place.cover) : nil
        super.init(frame: .zero)
        if let thumbnail = self.thumbnail { addSubview(thumbnail) }
        label.font = face.font(size: 13.5, weight: selected ? .medium : .regular)
        label.textColor = selected ? Ink.text : Ink.secondary
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        badges.flags = place.flags
        badges.size = 11
        addSubview(badges)
        toolTip = place.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        let marks = badges.intrinsicContentSize
        let room = marks.width > 0 ? marks.width + 8 : 0
        var x: CGFloat = 10
        if let thumbnail {
            let side: CGFloat = 18
            thumbnail.frame = NSRect(x: x, y: floor((bounds.height - side) / 2), width: side, height: side)
            x += side + 8
        }
        label.frame = NSRect(x: x, y: floor((bounds.height - height) / 2), width: bounds.width - x - 10 - room, height: height)
        badges.frame = NSRect(x: bounds.width - 10 - marks.width, y: floor((bounds.height - marks.height) / 2),
                              width: marks.width, height: marks.height)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering || selected else { return }
        (selected ? Ink.rule : Ink.hover).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
}
