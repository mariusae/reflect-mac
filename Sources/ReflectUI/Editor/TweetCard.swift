import AppKit
import ReflectCore

/// Draws a post as a card: who, what, when, and its first picture.
///
/// The card is drawn fresh each time, so it takes the window's light or
/// dark look; its height is worked out by the same measures that draw it.
package enum TweetCard {
    package static let width: CGFloat = 440
    private static let padding: CGFloat = 14
    private static let avatarSize: CGFloat = 40

    private static let nameFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private static let handleFont = NSFont.systemFont(ofSize: 13)
    private static let textFont = NSFont.systemFont(ofSize: 14)

    private static func body(_ tweet: Tweet) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.15
        return NSAttributedString(string: tweet.text, attributes: [.font: textFont, .foregroundColor: NSColor.labelColor,
                                                                   .paragraphStyle: paragraph])
    }

    private static func mediaHeight(_ tweet: Tweet) -> CGFloat {
        guard let media = tweet.media, media.width > 0 else { return 0 }
        return min(300, (width - 2 * padding) * media.height / media.width).rounded()
    }

    private static func textHeight(_ tweet: Tweet) -> CGFloat {
        guard !tweet.text.isEmpty else { return 0 }
        return ceil(body(tweet).boundingRect(with: NSSize(width: width - 2 * padding, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    /// The card's size, at its width.
    package static func size(of tweet: Tweet) -> CGSize {
        var height = padding + avatarSize + 10 + textHeight(tweet) + padding
        let media = mediaHeight(tweet)
        if media > 0 { height += media + 10 }
        return CGSize(width: width, height: height)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Draws the card into a rectangle of its size, or shrunk to fit a
    /// narrower column.
    package static func draw(_ tweet: Tweet, in rect: NSRect, images: ImageStore) {
        let natural = size(of: tweet)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: rect.width / natural.width)
        transform.concat()
        let bounds = NSRect(origin: .zero, size: natural)

        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.setFill()
        card.fill()
        NSColor.separatorColor.setStroke()
        card.lineWidth = 1
        card.stroke()

        let avatar = NSRect(x: padding, y: padding, width: avatarSize, height: avatarSize)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: avatar).addClip()
        if let url = tweet.user.avatar, let image = images.image(url) {
            image.draw(in: avatar, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            NSColor.quaternaryLabelColor.setFill()
            avatar.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        let textX = avatar.maxX + 10
        NSAttributedString(string: tweet.user.name, attributes: [.font: nameFont, .foregroundColor: NSColor.labelColor])
            .draw(in: NSRect(x: textX, y: padding + 1, width: width - textX - padding - 24, height: 18))
        var byline = tweet.user.screenName.isEmpty || tweet.site == .threads ? "" : "@\(tweet.user.screenName)"
        if let date = tweet.date { byline += (byline.isEmpty ? "" : " · ") + dateFormatter.string(from: date) }
        if let when = tweet.when { byline += (byline.isEmpty ? "" : " · ") + when }
        NSAttributedString(string: byline, attributes: [.font: handleFont, .foregroundColor: NSColor.secondaryLabelColor])
            .draw(in: NSRect(x: textX, y: padding + 21, width: width - textX - padding, height: 17))
        NSAttributedString(string: tweet.site == .threads ? "@" : "𝕏", attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .bold),
                                                   .foregroundColor: NSColor.labelColor])
            .draw(at: NSPoint(x: width - padding - 14, y: padding))

        var y = avatar.maxY + 10
        let text = textHeight(tweet)
        if text > 0 {
            body(tweet).draw(with: NSRect(x: padding, y: y, width: width - 2 * padding, height: text),
                             options: [.usesLineFragmentOrigin, .usesFontLeading])
            y += text
        }
        if let media = tweet.media {
            let frame = NSRect(x: padding, y: y + 10, width: width - 2 * padding, height: mediaHeight(tweet))
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).addClip()
            if let image = images.image(media.url) {
                // Filled, cropped to the frame, as the embed shows it.
                let size = image.size
                let scale = max(frame.width / size.width, frame.height / size.height)
                let drawn = NSSize(width: size.width * scale, height: size.height * scale)
                image.draw(in: NSRect(x: frame.midX - drawn.width / 2, y: frame.midY - drawn.height / 2,
                                      width: drawn.width, height: drawn.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                NSColor.quaternaryLabelColor.withAlphaComponent(0.2).setFill()
                frame.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            if media.isVideo, let play = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Video")?
                .withSymbolConfiguration(.init(pointSize: 44, weight: .regular)
                    .applying(.init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.55)]))) {
                play.draw(in: NSRect(x: frame.midX - play.size.width / 2, y: frame.midY - play.size.height / 2,
                                     width: play.size.width, height: play.size.height),
                          from: .zero, operation: .sourceOver, fraction: 0.9, respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
