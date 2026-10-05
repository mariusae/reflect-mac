import UIKit
import ReflectCore

/// What a link to a post or a video shows, under the row it is in: an X or
/// Threads post, or a YouTube video.
enum PhoneCard {
    case post(Tweet)
    case video(Video)
}

/// The cards links show: sent for off the main thread, kept on disk and in
/// memory, and `.prismImageLoaded` told — with the link — when one, or a
/// picture on one, comes in, so the rows showing it are drawn again.
enum PhoneCards {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: PhoneCard?] = [:]
    nonisolated(unsafe) private static var fetching: Set<String> = []
    nonisolated(unsafe) private static var pictures: [String: UIImage] = [:]
    nonisolated(unsafe) private static var picturesFetching: Set<String> = []

    /// Whether a link is one a card could be shown for.
    static func isCardLink(_ source: String) -> Bool {
        Tweet.key(from: source) != nil || Video.id(from: source) != nil
    }

    /// The card a link shows, when it is in; else nil, and sent for.
    nonisolated static func lookup(_ source: String) -> PhoneCard? {
        guard isCardLink(source) else { return nil }
        lock.lock()
        if let card = known[source] {
            lock.unlock()
            return card
        }
        guard !fetching.contains(source) else {
            lock.unlock()
            return nil
        }
        // On disk from before: read now.
        if let card = readCached(source) {
            known[source] = card
            lock.unlock()
            wantPictures(card, for: source)
            return card
        }
        fetching.insert(source)
        lock.unlock()
        Task.detached(priority: .utility) {
            let card = await fetch(source)
            lock.lock()
            fetching.remove(source)
            known[source] = card
            lock.unlock()
            if let card {
                wantPictures(card, for: source)
                await MainActor.run { NotificationCenter.default.post(name: .prismImageLoaded, object: source) }
            }
        }
        return nil
    }

    // MARK: Kept on disk

    private static let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Cards")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func file(_ source: String) -> URL? {
        if let id = Tweet.id(from: source) { return directory.appendingPathComponent("tweet-\(id).json") }
        if let path = Tweet.threadsPath(from: source) {
            return directory.appendingPathComponent("threads-" + path.replacingOccurrences(of: "/", with: "-") + ".html")
        }
        if let id = Video.id(from: source) { return directory.appendingPathComponent("youtube-\(id).json") }
        return nil
    }

    private static func parse(_ data: Data, _ source: String) -> PhoneCard? {
        if let id = Tweet.id(from: source) { return Tweet(json: data, id: id).map(PhoneCard.post) }
        if let path = Tweet.threadsPath(from: source) {
            return Tweet(threadsEmbed: String(decoding: data, as: UTF8.self), path: path).map(PhoneCard.post)
        }
        if let id = Video.id(from: source) { return Video(json: data, id: id).map(PhoneCard.video) }
        return nil
    }

    private static func readCached(_ source: String) -> PhoneCard? {
        guard let file = file(source), let data = try? Data(contentsOf: file) else { return nil }
        return parse(data, source)
    }

    private static let agent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    private static func get(_ url: URL) async -> (Data, URL?)? {
        var request = URLRequest(url: url)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 200) else { return nil }
        return (data, response.url)
    }

    private static func fetch(_ source: String) async -> PhoneCard? {
        var endpoint: URL?
        if let id = Tweet.id(from: source) {
            endpoint = Tweet.endpoint(for: id)
        } else if var path = Tweet.threadsPath(from: source) {
            // A share link: where it leads, first.
            if path.hasPrefix("share/"), let url = URL(string: "https://www.threads.com/" + path),
               let (_, final) = await get(url), let resolved = final.flatMap({ Tweet.threadsPath(from: $0.absoluteString) }) {
                path = resolved
            }
            endpoint = URL(string: "https://www.threads.com/" + path + "/embed")
        } else if let id = Video.id(from: source) {
            endpoint = Video.endpoint(for: id)
        }
        guard let endpoint, let (data, _) = await get(endpoint), let card = parse(data, source) else { return nil }
        if let file = file(source) { try? data.write(to: file, options: .atomic) }
        return card
    }

    // MARK: Pictures on cards

    private static func wantPictures(_ card: PhoneCard, for source: String) {
        let urls: [String] = switch card {
        case .post(let post): [post.user.avatar, post.media?.url].compactMap { $0 }
        case .video(let video): [video.thumbnail].compactMap { $0 }
        }
        for url in urls { _ = picture(url, for: source) }
    }

    /// A picture on a card, when it is in; else sent for, the link told when it is.
    nonisolated static func picture(_ url: String, for source: String) -> UIImage? {
        lock.lock()
        if let image = pictures[url] {
            lock.unlock()
            return image
        }
        guard !picturesFetching.contains(url), let remote = URL(string: url) else {
            lock.unlock()
            return nil
        }
        picturesFetching.insert(url)
        lock.unlock()
        Task.detached(priority: .utility) {
            let image = await get(remote).flatMap { UIImage(data: $0.0) }.flatMap { $0.preparingThumbnail(of: fitting($0.size, 900)) }
            lock.lock()
            picturesFetching.remove(url)
            if let image { pictures[url] = image }
            lock.unlock()
            if image != nil {
                await MainActor.run { NotificationCenter.default.post(name: .prismImageLoaded, object: source) }
            }
        }
        return nil
    }

    private static func fitting(_ size: CGSize, _ longest: CGFloat) -> CGSize {
        let scale = min(1, longest / max(size.width, size.height, 1))
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

// MARK: - Drawing

/// Draws a card at a width — as wide as there is room for, no wider than a
/// card is — its height worked out by the same measures that draw it.
enum PhoneCardView {
    static let widest: CGFloat = 440
    private static let padding: CGFloat = 12
    private static let avatarSize: CGFloat = 36

    private static var nameFont: UIFont { .systemFont(ofSize: 15, weight: .semibold) }
    private static var bylineFont: UIFont { .systemFont(ofSize: 13) }
    private static var textFont: UIFont { .systemFont(ofSize: 15) }

    private static func body(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.1
        return NSAttributedString(string: text, attributes: [.font: textFont, .foregroundColor: Ink.text, .paragraphStyle: paragraph])
    }

    private static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil(body(text).boundingRect(with: CGSize(width: width - 2 * padding, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
    }

    private static func mediaHeight(_ media: Tweet.Media?, width: CGFloat) -> CGFloat {
        guard let media, media.width > 0 else { return 0 }
        return min(260, (width - 2 * padding) * media.height / media.width).rounded()
    }

    private static func videoTitle(_ video: Video, width: CGFloat) -> CGFloat {
        let font = nameFont
        let full = ceil((video.title as NSString).boundingRect(with: CGSize(width: width - 2 * padding, height: .greatestFiniteMagnitude),
                                                               options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                               attributes: [.font: font], context: nil).height)
        return min(full, ceil(font.lineHeight) * 2 + 1)
    }

    static func size(_ card: PhoneCard, room: CGFloat) -> CGSize {
        let width = min(widest, room)
        switch card {
        case .post(let post):
            var height = padding + avatarSize + 8 + textHeight(post.text, width: width) + padding
            let media = mediaHeight(post.media, width: width)
            if media > 0 { height += media + 8 }
            return CGSize(width: width, height: height)
        case .video(let video):
            return CGSize(width: width, height: (width * 9 / 16).rounded() + padding + videoTitle(video, width: width) + 4 + 17 + padding)
        }
    }

    static func draw(_ card: PhoneCard, in rect: CGRect, source: String) {
        let frame = UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 12)
        Ink.paper.setFill()
        frame.fill()
        Ink.rule.setStroke()
        frame.lineWidth = 1
        frame.stroke()
        switch card {
        case .post(let post): drawPost(post, in: rect, source: source)
        case .video(let video): drawVideo(video, in: rect, source: source)
        }
    }

    private static func fill(_ image: UIImage?, in frame: CGRect, corner: CGFloat, corners: UIRectCorner = .allCorners) {
        let context = UIGraphicsGetCurrentContext()
        context?.saveGState()
        UIBezierPath(roundedRect: frame, byRoundingCorners: corners, cornerRadii: CGSize(width: corner, height: corner)).addClip()
        if let image {
            let scale = max(frame.width / image.size.width, frame.height / image.size.height)
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: frame.midX - drawn.width / 2, y: frame.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
        } else {
            Ink.shelf.setFill()
            UIRectFill(frame)
        }
        context?.restoreGState()
    }

    private static func drawPost(_ post: Tweet, in rect: CGRect, source: String) {
        let width = rect.width
        let avatar = CGRect(x: rect.minX + padding, y: rect.minY + padding, width: avatarSize, height: avatarSize)
        fill(post.user.avatar.flatMap { PhoneCards.picture($0, for: source) }, in: avatar, corner: avatarSize / 2)
        let x = avatar.maxX + 10
        (post.user.name as NSString).draw(in: CGRect(x: x, y: avatar.minY, width: rect.maxX - x - padding - 24, height: 19),
                                          withAttributes: [.font: nameFont, .foregroundColor: Ink.text])
        var byline = post.site == .threads || post.user.screenName.isEmpty ? "" : "@" + post.user.screenName
        if let date = post.date { byline += (byline.isEmpty ? "" : " · ") + date.formatted(date: .abbreviated, time: .omitted) }
        if let when = post.when { byline += (byline.isEmpty ? "" : " · ") + when }
        (byline as NSString).draw(in: CGRect(x: x, y: avatar.minY + 19, width: rect.maxX - x - padding, height: 17),
                                  withAttributes: [.font: bylineFont, .foregroundColor: Ink.secondary])
        // The site's mark, at the top right.
        (post.site == .threads ? "@" : "𝕏" as NSString).draw(at: CGPoint(x: rect.maxX - padding - 14, y: rect.minY + padding - 1),
                                                         withAttributes: [.font: UIFont.systemFont(ofSize: 16, weight: .bold), .foregroundColor: Ink.text])
        var y = avatar.maxY + 8
        let text = textHeight(post.text, width: width)
        if text > 0 {
            body(post.text).draw(with: CGRect(x: rect.minX + padding, y: y, width: width - 2 * padding, height: text),
                                 options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            y += text
        }
        if let media = post.media {
            let frame = CGRect(x: rect.minX + padding, y: y + 8, width: width - 2 * padding, height: mediaHeight(media, width: width))
            fill(PhoneCards.picture(media.url, for: source), in: frame, corner: 8)
        }
    }

    private static func drawVideo(_ video: Video, in rect: CGRect, source: String) {
        let poster = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: (rect.width * 9 / 16).rounded())
        fill(video.thumbnail.flatMap { PhoneCards.picture($0, for: source) }, in: poster, corner: 12, corners: [.topLeft, .topRight])
        if let play = UIImage(systemName: "play.rectangle.fill",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 40)
                                  .applying(UIImage.SymbolConfiguration(paletteColors: [.white, UIColor(red: 1, green: 0, blue: 0, alpha: 0.9)]))) {
            play.draw(at: CGPoint(x: poster.midX - play.size.width / 2, y: poster.midY - play.size.height / 2))
        }
        let titleHeight = videoTitle(video, width: rect.width)
        // Up to two lines, the second cut short.
        (video.title as NSString).draw(with: CGRect(x: rect.minX + padding, y: poster.maxY + padding, width: rect.width - 2 * padding, height: titleHeight),
                                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                       attributes: [.font: nameFont, .foregroundColor: Ink.text], context: nil)
        let line = poster.maxY + padding + titleHeight + 4
        (video.author as NSString).draw(at: CGPoint(x: rect.minX + padding, y: line), withAttributes: [.font: bylineFont, .foregroundColor: Ink.secondary])
        let site = "YouTube" as NSString
        let siteSize = site.size(withAttributes: [.font: bylineFont])
        site.draw(at: CGPoint(x: rect.maxX - padding - siteSize.width, y: line),
                  withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Ink.secondary])
    }
}
