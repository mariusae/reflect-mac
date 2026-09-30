import AppKit
import ReflectCore

/// Links shown as Reflect's iPhone app shows them: in the accent colour, on
/// a pale pill of it — with, as Slack does, what kind of link it is before
/// it: the web, a page, or a day. A bare web address is shortened to where
/// it goes: its site, always, and the last part of its path — the rest of
/// it hidden, an ellipsis in its place — and shown whole while the caret is
/// in it. Tags are pills too, with no kind.
///
/// Nothing is written differently: the Markdown is the Markdown; only what
/// is shown of it changes. The icon takes the room of the link's first
/// hidden character, as a file pill's does.
final class LinkPill: NSObject {
    enum Kind { case web, page, day, tag }
    let kind: Kind
    /// Whether it has a hidden character to put its icon in: not a tag, nor
    /// an address shown whole.
    let hasLead: Bool

    init(_ kind: Kind, hasLead: Bool = true) {
        self.kind = kind
        self.hasLead = hasLead && kind != .tag
    }

    var symbol: String? {
        guard hasLead else { return nil }
        switch kind {
        case .web: return "link"
        case .page: return "doc.text"
        case .day: return "calendar"
        case .tag: return nil
        }
    }

    static func iconSide(for font: NSFont) -> CGFloat { (font.pointSize * 0.72).rounded() }

    /// The room before the text: the icon, and space either side of it.
    func leadWidth(for font: NSFont) -> CGFloat {
        symbol == nil ? 3 : 4 + Self.iconSide(for: font) + 3
    }

    static let tailWidth: CGFloat = 3
    static let ellipsis = "…"

    static func ellipsisWidth(for font: NSFont) -> CGFloat {
        ceil((ellipsis as NSString).size(withAttributes: [.font: font]).width)
    }

    static var tint: NSColor { .controlAccentColor }

    // MARK: Styling

    /// Marks a span as a pill: its lead, where the icon goes, on its first
    /// character, and its tail on its last — both hidden markup, laid out
    /// with room of their own.
    static func mark(_ storage: NSTextStorage, _ range: NSRange, kind: Kind) {
        guard range.length >= 2 else { return }
        let pill = LinkPill(kind)
        storage.addAttribute(.outlineLink, value: pill, range: range)
        // A tag's characters are all shown: no room of its own to take.
        guard pill.hasLead else { return }
        storage.addAttribute(.outlineLinkLead, value: pill, range: NSRange(location: range.location, length: 1))
        storage.addAttribute(.outlineLinkTail, value: pill, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
    }

    /// A bare web address, shortened unless the caret is in it: the scheme
    /// and `www.` hidden, and all the path but its first and last parts,
    /// and what follows the path. Its lead is the first hidden character.
    static func markBare(_ storage: NSTextStorage, _ range: NSRange, revealed: Int?) {
        let text = storage.string as NSString
        let address = text.substring(with: range)
        let parts = shortened(address)
        let shown = revealed.map { NSLocationInRange($0, range) || $0 == NSMaxRange(range) } ?? false
        guard !shown, parts.prefix > 0 else {
            // Whole, to be edited: all its characters shown, none to put an icon in.
            storage.addAttribute(.outlineLink, value: LinkPill(.web, hasLead: false), range: range)
            return
        }
        let pill = LinkPill(.web)
        storage.addAttribute(.outlineLink, value: pill, range: range)
        func hide(_ local: NSRange) {
            guard local.length > 0 else { return }
            storage.addAttribute(.outlineHidden, value: true, range: NSRange(location: range.location + local.location, length: local.length))
        }
        hide(NSRange(location: 0, length: parts.prefix))
        storage.addAttribute(.outlineLinkLead, value: pill, range: NSRange(location: range.location, length: 1))
        if let middle = parts.middle {
            hide(middle)
            storage.addAttribute(.outlineLinkEllipsis, value: pill, range: NSRange(location: range.location + middle.location, length: 1))
        }
        if let rest = parts.rest { hide(rest) }
    }

    /// What of an address is hidden: its first characters — scheme and
    /// `www.` — the middle of its path, between its first and last parts,
    /// and what follows its path. In the address's own characters.
    static func shortened(_ address: String) -> (prefix: Int, middle: NSRange?, rest: NSRange?) {
        let text = address as NSString
        let scheme = text.range(of: "://")
        guard scheme.location != NSNotFound else { return (0, nil, nil) }
        var hostStart = NSMaxRange(scheme)
        if text.length > hostStart + 4, text.substring(with: NSRange(location: hostStart, length: 4)).lowercased() == "www." {
            hostStart += 4
        }
        // Where the path ends: at a query or a fragment.
        var end = text.length
        for mark in ["?", "#"] {
            let found = text.range(of: mark, options: [], range: NSRange(location: hostStart, length: text.length - hostStart))
            if found.location != NSNotFound { end = min(end, found.location) }
        }
        // Not a trailing slash, either.
        while end > hostStart, text.character(at: end - 1) == 0x2F { end -= 1 }
        let rest = end < text.length ? NSRange(location: end, length: text.length - end) : nil
        let slash = text.range(of: "/", options: [], range: NSRange(location: hostStart, length: end - hostStart))
        guard slash.location != NSNotFound else { return (hostStart, nil, rest) }
        // The path's parts: a middle only for three or more.
        var starts: [Int] = []
        var at = slash.location
        while at < end {
            if text.character(at: at) == 0x2F { starts.append(at) }
            at += 1
        }
        guard starts.count >= 3 else { return (hostStart, nil, rest) }
        // Kept: `/first`, then `/…/last`: hidden from after the first part to the last slash.
        let hiddenStart = starts[1] + 1
        let hiddenEnd = starts[starts.count - 1]
        return (hostStart, NSRange(location: hiddenStart, length: hiddenEnd - hiddenStart), rest)
    }
}

extension NSAttributedString.Key {
    /// Over a link or tag shown as a pill: its `LinkPill`.
    static let outlineLink = NSAttributedString.Key("ReflectOutlineLink")
    /// On the hidden character laid out as room for a pill's icon.
    static let outlineLinkLead = NSAttributedString.Key("ReflectOutlineLinkLead")
    /// On the hidden character laid out as room after a pill's text.
    static let outlineLinkTail = NSAttributedString.Key("ReflectOutlineLinkTail")
    /// On the hidden character laid out as a shortened address's ellipsis.
    static let outlineLinkEllipsis = NSAttributedString.Key("ReflectOutlineLinkEllipsis")
}

extension OutlineLayoutManager {
    /// Draws the pills of the links in some characters: on each line a
    /// link runs across, a rounded rectangle round its piece, the kind's
    /// icon in its lead, and a shortened address's ellipsis.
    func drawLinkPills(in characters: NSRange, origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first, characters.length > 0 else { return }
        storage.enumerateAttribute(.outlineLink, in: characters) { value, range, _ in
            guard let pill = value as? LinkPill else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 15)
            var rects: [NSRect] = []
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in rects.append(rect) }
            let ascent = ceil(font.ascender), descent = ceil(-font.descender)
            var pieces: [NSRect] = []
            for rect in rects where rect.width > 0.5 {
                let glyph = glyphIndex(for: NSPoint(x: rect.minX + 1, y: rect.midY), in: container)
                let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let baseline = line.minY + location(forGlyphAt: glyph).y
                // A pill with no room of its own reaches a little past its text.
                let pad: CGFloat = pill.hasLead ? 1 : 3
                pieces.append(NSRect(x: rect.minX + origin.x - pad, y: baseline - ascent - 2 + origin.y,
                                     width: rect.width + 2 * pad, height: ascent + descent + 4))
            }
            LinkPill.tint.withAlphaComponent(0.12).setFill()
            for piece in pieces { NSBezierPath(roundedRect: piece, xRadius: 5, yRadius: 5).fill() }
            if let first = pieces.first, let symbol = pill.symbol {
                let side = LinkPill.iconSide(for: font)
                let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.9, weight: .medium)
                    .applying(.init(paletteColors: [LinkPill.tint]))
                if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                    let size = icon.size
                    icon.draw(in: NSRect(x: first.minX + 4 + (side - size.width) / 2, y: first.midY - size.height / 2,
                                         width: size.width, height: size.height),
                              from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
            // A shortened address's ellipsis, in the room its hidden middle has.
            storage.enumerateAttribute(.outlineLinkEllipsis, in: range) { value, at, _ in
                guard value != nil else { return }
                let glyph = glyphIndexForCharacter(at: at.location)
                let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let point = location(forGlyphAt: glyph)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: LinkPill.tint]
                (LinkPill.ellipsis as NSString).draw(at: NSPoint(x: line.minX + point.x + origin.x,
                                                                 y: line.minY + point.y - ascent + origin.y),
                                                     withAttributes: attributes)
            }
        }
    }
}
