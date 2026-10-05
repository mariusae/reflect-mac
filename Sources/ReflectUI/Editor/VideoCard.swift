import AppKit
import ReflectCore

/// Draws a video as a card: its picture, a play button on it, its title,
/// and whose it is.
package enum VideoCard {
    package static let width: CGFloat = 440
    private static let padding: CGFloat = 12
    private static var posterHeight: CGFloat { (width * 9 / 16).rounded() }

    private static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private static let authorFont = NSFont.systemFont(ofSize: 13)

    private static func title(_ video: Video) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: video.title, attributes: [.font: titleFont, .foregroundColor: NSColor.labelColor,
                                                                    .paragraphStyle: paragraph])
    }

    /// The title's height: up to two lines.
    private static func titleHeight(_ video: Video) -> CGFloat {
        let full = ceil(title(video).boundingRect(with: NSSize(width: width - 2 * padding, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        return min(full, ceil(titleFont.ascender - titleFont.descender + titleFont.leading) * 2 + 2)
    }

    package static func size(of video: Video) -> CGSize {
        CGSize(width: width, height: posterHeight + padding + titleHeight(video) + 4 + 17 + padding)
    }

    /// Draws the card into a rectangle of its size, or shrunk to fit.
    package static func draw(_ video: Video, in rect: NSRect, images: ImageStore) {
        let natural = size(of: video)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: rect.width / natural.width)
        transform.concat()
        let bounds = NSRect(origin: .zero, size: natural)

        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.setFill()
        card.fill()

        // The picture, filling the top: cropped to 16:9, which takes off the
        // black bars YouTube's thumbnails come with.
        let poster = NSRect(x: 0, y: 0, width: width, height: posterHeight)
        NSGraphicsContext.saveGraphicsState()
        card.addClip()
        NSBezierPath(rect: poster).addClip()
        if let url = video.thumbnail, let image = images.image(url) {
            let size = image.size
            let scale = max(poster.width / size.width, poster.height / size.height)
            let drawn = NSSize(width: size.width * scale, height: size.height * scale)
            image.draw(in: NSRect(x: poster.midX - drawn.width / 2, y: poster.midY - drawn.height / 2, width: drawn.width, height: drawn.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            NSColor.black.withAlphaComponent(0.85).setFill()
            poster.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // YouTube's play button.
        let button = NSRect(x: poster.midX - 34, y: poster.midY - 24, width: 68, height: 48)
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: button, xRadius: 14, yRadius: 14).fill()
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: button.midX - 8, y: button.midY - 11))
        triangle.line(to: NSPoint(x: button.midX + 13, y: button.midY))
        triangle.line(to: NSPoint(x: button.midX - 8, y: button.midY + 11))
        triangle.close()
        NSColor.white.setFill()
        triangle.fill()

        var y = poster.maxY + padding
        let titleHeight = titleHeight(video)
        title(video).draw(with: NSRect(x: padding, y: y, width: width - 2 * padding, height: titleHeight),
                          options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        y += titleHeight + 4
        NSAttributedString(string: video.author, attributes: [.font: authorFont, .foregroundColor: NSColor.secondaryLabelColor])
            .draw(in: NSRect(x: padding, y: y, width: width - 2 * padding - 70, height: 17))
        let mark = NSAttributedString(string: "YouTube", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                                       .foregroundColor: NSColor.secondaryLabelColor])
        mark.draw(at: NSPoint(x: width - padding - mark.size().width, y: y + 1))

        NSColor.separatorColor.setStroke()
        card.lineWidth = 1
        card.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
