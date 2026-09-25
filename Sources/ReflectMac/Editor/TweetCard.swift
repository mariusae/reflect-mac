import AppKit
import ReflectCore

/// A post on X (Twitter), as much of it as a card shows.
struct Tweet: Codable, Sendable {
    struct User: Codable, Sendable {
        var name: String
        var screenName: String
        var avatar: String?
    }

    struct Media: Codable, Sendable {
        var url: String
        var width: Double
        var height: Double
        var isVideo: Bool
    }

    var id: String
    var text: String
    var date: Date?
    var user: User
    var media: Media?

    /// The post a link names: `https://x.com/who/status/123…`, or
    /// twitter.com's, with or without `www.` or `mobile.`.
    static func id(from source: String) -> String? {
        guard let url = URL(string: source), let host = url.host?.lowercased(),
              ["x.com", "twitter.com", "www.x.com", "www.twitter.com", "mobile.twitter.com", "mobile.x.com"].contains(host)
        else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 3, parts[1] == "status", parts[2].allSatisfy(\.isNumber) else { return nil }
        return String(parts[2])
    }

    /// Reads the embed endpoint's answer, or nil for one that is not a
    /// post — a deleted one, a private one.
    init?(json data: Data, id: String) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var text = root["text"] as? String,
              let user = root["user"] as? [String: Any],
              let name = user["name"] as? String, let screenName = user["screen_name"] as? String
        else { return nil }
        // The text runs past what is shown to the links of its media.
        if let range = root["display_text_range"] as? [Int], range.count == 2 {
            let scalars = Array(text.unicodeScalars)
            let upper = min(range[1], scalars.count)
            if range[0] < upper { text = String(String.UnicodeScalarView(scalars[range[0]..<upper])) }
        }
        if let entities = root["entities"] as? [String: Any], let urls = entities["urls"] as? [[String: Any]] {
            for link in urls {
                if let short = link["url"] as? String, let shown = link["display_url"] as? String {
                    text = text.replacingOccurrences(of: short, with: shown)
                }
            }
        }
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        date = (root["created_at"] as? String).flatMap { formatter.date(from: $0) }
        self.user = User(name: name, screenName: screenName,
                         avatar: (user["profile_image_url_https"] as? String)?.replacingOccurrences(of: "_normal.", with: "_bigger."))
        if let first = (root["mediaDetails"] as? [[String: Any]])?.first, let url = first["media_url_https"] as? String {
            let info = first["original_info"] as? [String: Any]
            media = Media(url: url,
                          width: (info?["width"] as? NSNumber)?.doubleValue ?? 16,
                          height: (info?["height"] as? NSNumber)?.doubleValue ?? 9,
                          isVideo: (first["type"] as? String).map { $0 != "photo" } ?? false)
        }
    }

    /// The embed endpoint for a post. Its `token` is worked out the way
    /// the embed code does, from the id.
    static func endpoint(for id: String) -> URL? {
        guard let number = Double(id) else { return nil }
        let token = base36(number / 1e15 * Double.pi).filter { $0 != "0" && $0 != "." }
        return URL(string: "https://cdn.syndication.twimg.com/tweet-result?id=\(id)&lang=en&token=\(token.isEmpty ? "a" : token)")
    }

    private static func base36(_ value: Double) -> String {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var whole = UInt64(value), fraction = value - Double(UInt64(value))
        var text = ""
        repeat {
            text.insert(digits[Int(whole % 36)], at: text.startIndex)
            whole /= 36
        } while whole > 0
        text += "."
        for _ in 0..<11 {
            fraction *= 36
            let digit = Int(fraction)
            text.append(digits[digit])
            fraction -= Double(digit)
        }
        return text
    }
}

/// Draws a post as a card: who, what, when, and its first picture.
///
/// The card is drawn fresh each time, so it takes the window's light or
/// dark look; its height is worked out by the same measures that draw it.
enum TweetCard {
    static let width: CGFloat = 440
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
    static func size(of tweet: Tweet) -> CGSize {
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
    static func draw(_ tweet: Tweet, in rect: NSRect, images: ImageStore) {
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
        var byline = "@\(tweet.user.screenName)"
        if let date = tweet.date { byline += " · " + dateFormatter.string(from: date) }
        NSAttributedString(string: byline, attributes: [.font: handleFont, .foregroundColor: NSColor.secondaryLabelColor])
            .draw(in: NSRect(x: textX, y: padding + 21, width: width - textX - padding, height: 17))
        NSAttributedString(string: "𝕏", attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .bold),
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
