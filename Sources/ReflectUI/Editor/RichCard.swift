import AppKit
import ReflectCore

/// Draws a link's card — a page, a podcast, a paper, a repository, a Google
/// file — as one compact shape: the service over a title, a line or two
/// more, a line of facts; a page's picture at the right, a podcast's cover
/// at the left.
package enum RichCard {
    package static let width: CGFloat = 440
    private static let thumbnail: CGFloat = 76

    /// How a card is set: framed, in the system's face; or, on the flat page,
    /// unframed, in the notes' own — the site in small capitals over its
    /// title in Semibold, as a magazine heads a piece.
    private struct Style {
        var flat = false
        var padding: CGFloat = 12
        var serviceFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        var titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        var detailFont = NSFont.systemFont(ofSize: 12.5)
        var factsFont = NSFont.systemFont(ofSize: 11.5)
        var label: [NSAttributedString.Key: Any] = [:]

        init(_ typography: Typography?) {
            guard let typography, typography.flat else { return }
            flat = true
            padding = 4
            label = typography.label(size: 15)
            titleFont = typography.face(style: "Semibold", heading: true, size: 15) ?? typography.headingFont(size: 15, weight: .semibold)
            detailFont = Typography.font(typography.bodyFamily, face: typography.bodyFace, size: 13)
            factsFont = Typography.font(typography.bodyFamily, face: typography.bodyFace, size: 12)
            serviceFont = label[.font] as? NSFont ?? serviceFont
        }
    }

    private static func hasPicture(_ face: RichCardFace) -> Bool { face.picture != .none }

    /// Where the words go, across: clear of the picture.
    private static func textInsets(_ face: RichCardFace, _ style: Style) -> (left: CGFloat, right: CGFloat) {
        let padding = style.padding
        switch face.picture {
        case .none: return (padding, padding)
        case .thumbnail: return (padding, padding + thumbnail + 12)
        case .artwork: return (padding + thumbnail + 12, padding)
        }
    }

    private static func paragraph(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    /// A text's height, up to so many lines.
    private static func height(_ text: NSAttributedString, width: CGFloat, lines: Int, font: NSFont) -> CGFloat {
        let full = ceil(text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        // A line as the face sets it: some faces' lines are taller than their ascent and descent.
        let line = max(ceil(font.ascender - font.descender + font.leading), ceil(NSLayoutManager().defaultLineHeight(for: font)))
        return min(full, line * CGFloat(lines) + 1)
    }

    private struct Layout {
        var title: CGFloat
        var detail: CGFloat
        var facts: CGFloat
        var total: CGFloat
    }

    private static func layout(_ face: RichCardFace, _ style: Style) -> Layout {
        let insets = textInsets(face, style)
        let padding = style.padding
        let text = width - insets.left - insets.right
        let title = height(paragraph(face.title, font: style.titleFont, color: .labelColor), width: text, lines: 2, font: style.titleFont)
        let detail = face.detail.map { height(paragraph($0, font: style.detailFont, color: .secondaryLabelColor), width: text, lines: 2, font: style.detailFont) } ?? 0
        let facts = face.facts.map { height(paragraph($0, font: style.factsFont, color: .secondaryLabelColor), width: text, lines: 1, font: style.factsFont) } ?? 0
        var total = padding + 16 + 4 + title
        if detail > 0 { total += 3 + detail }
        if facts > 0 { total += 4 + facts }
        total += padding
        if hasPicture(face) { total = max(total, thumbnail + 2 * padding) }
        return Layout(title: title, detail: detail, facts: facts, total: ceil(total))
    }

    package static func size(of face: RichCardFace, typography: Typography? = nil) -> CGSize {
        CGSize(width: width, height: layout(face, Style(typography)).total)
    }

    /// Draws the card into a rectangle of its size, or shrunk to fit.
    package static func draw(_ face: RichCardFace, in rect: NSRect, images: ImageStore, typography: Typography? = nil) {
        let style = Style(typography)
        let padding = style.padding, corner: CGFloat = style.flat ? 0 : 8
        let measures = layout(face, style)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: rect.width / width)
        transform.concat()
        let bounds = NSRect(x: 0, y: 0, width: width, height: measures.total)
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        if !style.flat {
            NSColor.controlBackgroundColor.setFill()
            card.fill()
        }

        // The picture: a page's at the right, a cover at the left.
        switch face.picture {
        case .thumbnail(let url):
            drawPicture(images.image(url), in: NSRect(x: width - padding - thumbnail, y: padding, width: thumbnail, height: thumbnail), corner: corner)
        case .artwork(let url):
            drawPicture(images.image(url), in: NSRect(x: padding, y: padding, width: thumbnail, height: thumbnail), corner: corner)
        case .none:
            break
        }

        let insets = textInsets(face, style)
        let textWidth = width - insets.left - insets.right
        var x = insets.left
        var y = padding
        let titleFont = style.titleFont, detailFont = style.detailFont, factsFont = style.factsFont
        // The service: a site's icon, or the service's mark, then its name.
        let tint = face.tint.map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) } ?? NSColor.secondaryLabelColor
        if style.flat {
            // The site in small spaced capitals: no mark, no colour.
            var label = style.label
            let truncating = NSMutableParagraphStyle()
            truncating.lineBreakMode = .byTruncatingTail
            label[.paragraphStyle] = truncating
            NSAttributedString(string: face.service.uppercased(), attributes: label)
                .draw(with: NSRect(x: x, y: y, width: textWidth, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        } else if let icon = face.icon.flatMap({ images.image($0) }) {
            icon.draw(in: NSRect(x: x, y: y + 1, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            x += 19
        } else if let symbol = NSImage(systemSymbolName: face.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11.5, weight: .semibold).applying(.init(paletteColors: [tint]))) {
            let size = symbol.size
            symbol.draw(in: NSRect(x: x, y: y + (16 - size.height) / 2, width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += size.width + 5
        }
        if !style.flat {
            let service = NSMutableParagraphStyle()
            service.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: face.service, attributes: [.font: style.serviceFont, .foregroundColor: face.tint == nil ? NSColor.secondaryLabelColor : tint,
                                                                  .paragraphStyle: service])
                .draw(with: NSRect(x: x, y: y, width: insets.left + textWidth - x, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        y += 16 + 4
        x = insets.left
        paragraph(face.title, font: titleFont, color: .labelColor)
            .draw(with: NSRect(x: x, y: y, width: textWidth, height: measures.title), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        y += measures.title
        if let detail = face.detail, measures.detail > 0 {
            y += 3
            paragraph(detail, font: detailFont, color: .secondaryLabelColor)
                .draw(with: NSRect(x: x, y: y, width: textWidth, height: measures.detail), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
            y += measures.detail
        }
        if let facts = face.facts, measures.facts > 0 {
            y += 4
            paragraph(facts, font: factsFont, color: .tertiaryLabelColor)
                .draw(with: NSRect(x: x, y: y, width: textWidth, height: measures.facts), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        }

        if !style.flat {
            NSColor.separatorColor.setStroke()
            card.lineWidth = 1
            card.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawPicture(_ image: NSImage?, in frame: NSRect, corner: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: frame, xRadius: corner, yRadius: corner).addClip()
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = max(frame.width / image.size.width, frame.height / image.size.height)
            let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: frame.midX - drawn.width / 2, y: frame.midY - drawn.height / 2, width: drawn.width, height: drawn.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.2).setFill()
            frame.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
