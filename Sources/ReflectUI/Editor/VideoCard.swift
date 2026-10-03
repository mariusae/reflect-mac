import AppKit
import ReflectCore

/// A YouTube video, as much of it as a card shows: from YouTube's oEmbed
/// answer, as Reflect's editor reads it.
package struct Video: Sendable {
    package var id: String
    package var title: String
    package var author: String
    package var thumbnail: String?

    /// The video a link names: `youtube.com/watch?v=…`, `youtu.be/…`, and
    /// `/shorts/`, `/live/` and `/embed/` ones — on `www.`, `m.` or `music.`.
    package static func id(from source: String) -> String? {
        guard let url = URL(string: source), var host = url.host?.lowercased() else { return nil }
        for prefix in ["www.", "m.", "music."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        let parts = url.path.split(separator: "/").map(String.init)
        var id: String?
        switch host {
        case "youtu.be":
            id = parts.first
        case "youtube.com", "youtube-nocookie.com":
            if parts.first == "watch" {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            } else if parts.count >= 2, ["shorts", "live", "embed", "v"].contains(parts[0]) {
                id = parts[1]
            }
        default:
            return nil
        }
        guard let id, id.count == 11, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return id
    }

    /// Where YouTube tells of a video.
    package static func endpoint(for id: String) -> URL? {
        let watch = "https://www.youtube.com/watch?v=\(id)"
        return URL(string: "https://www.youtube.com/oembed?format=json&url=" + (watch.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? watch))
    }

    /// Reads oEmbed's answer, or nil for anything else.
    package init?(json data: Data, id: String) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = root["title"] as? String else { return nil }
        self.id = id
        self.title = title
        author = root["author_name"] as? String ?? ""
        thumbnail = root["thumbnail_url"] as? String ?? "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"
    }
}

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
