import UIKit
import ReflectCore

/// What a link to a post or a video shows, under the row it is in: an X or
/// Threads post, or a YouTube video.
enum PhoneCard {
    case post(Tweet)
    case video(Video)
    /// Any other link's: a page, a podcast, a paper, a repository, a Google file.
    case rich(RichCardFace)
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

    // MARK: Other links

    nonisolated(unsafe) private static var richKnown: [String: RichLink?] = [:]
    nonisolated(unsafe) private static var linkTexts: [String: String] = [:]
    private static var linksFolder: URL { directory.appendingPathComponent("Links") }

    /// The card a link alone in its row shows — a page's, a podcast's — when
    /// it is in; else nil, and sent for. `text`: what the note calls it.
    nonisolated static func rich(_ source: String, text: String?) -> PhoneCard? {
        lock.lock()
        if let text, !text.isEmpty, text != source { linkTexts[source] = text }
        if let known = richKnown[source] {
            let face = known.map { RichCardFace($0, linkText: linkTexts[source]) }
            lock.unlock()
            return face.map(PhoneCard.rich)
        }
        if let cached = RichLinks.cached(source, in: linksFolder) {
            richKnown[source] = cached
            let face = cached.map { RichCardFace($0, linkText: linkTexts[source]) }
            lock.unlock()
            if let face { wantPictures(.rich(face), for: source) }
            return face.map(PhoneCard.rich)
        }
        guard RichLinkKind.of(source) != nil, !fetching.contains(source) else {
            lock.unlock()
            return nil
        }
        fetching.insert(source)
        lock.unlock()
        let folder = linksFolder
        Task.detached(priority: .utility) {
            let card = await RichLinks.load(source, in: folder)
            lock.lock()
            fetching.remove(source)
            richKnown[source] = card
            let face = card.map { RichCardFace($0, linkText: linkTexts[source]) }
            lock.unlock()
            if let face {
                wantPictures(.rich(face), for: source)
                await MainActor.run { NotificationCenter.default.post(name: .prismImageLoaded, object: source) }
            }
        }
        return nil
    }

    /// The card a link shows, when it is in; else nil, and sent for.
    nonisolated static func lookup(_ source: String) -> PhoneCard? {
        guard isCardLink(source) else {
            // Another link's: only once asked for, as alone in its row.
            lock.lock()
            defer { lock.unlock() }
            guard let known = richKnown[source], let card = known else { return nil }
            return .rich(RichCardFace(card, linkText: linkTexts[source]))
        }
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
        case .rich(let face):
            switch face.picture {
            case .thumbnail(let url), .artwork(let url): [url, face.icon].compactMap { $0 }
            case .none: [face.icon].compactMap { $0 }
            }
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
        case .rich(let face):
            return CGSize(width: width, height: richLayout(face, width: width).total)
        }
    }

    // MARK: Other links' cards

    private static let thumbnail: CGFloat = 72

    private static func richInsets(_ face: RichCardFace) -> (left: CGFloat, right: CGFloat) {
        switch face.picture {
        case .none: (padding, padding)
        case .thumbnail: (padding, padding + thumbnail + 12)
        case .artwork: (padding + thumbnail + 12, padding)
        }
    }

    private static func lines(_ text: String, font: UIFont, width: CGFloat, most: Int) -> CGFloat {
        let full = ceil((text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                        attributes: [.font: font], context: nil).height)
        return min(full, ceil(font.lineHeight) * CGFloat(most) + 1)
    }

    private static var richTitleFont: UIFont { .systemFont(ofSize: 15, weight: .semibold) }
    private static var richDetailFont: UIFont { .systemFont(ofSize: 13) }
    private static var richFactsFont: UIFont { .systemFont(ofSize: 12) }
    private static var richServiceFont: UIFont { .systemFont(ofSize: 12, weight: .semibold) }

    private static func richLayout(_ face: RichCardFace, width: CGFloat) -> (title: CGFloat, detail: CGFloat, facts: CGFloat, total: CGFloat) {
        let insets = richInsets(face)
        let text = width - insets.left - insets.right
        let title = lines(face.title, font: richTitleFont, width: text, most: 2)
        let detail = face.detail.map { lines($0, font: richDetailFont, width: text, most: 2) } ?? 0
        let facts = face.facts.map { lines($0, font: richFactsFont, width: text, most: 1) } ?? 0
        var total = padding + 17 + 4 + title
        if detail > 0 { total += 3 + detail }
        if facts > 0 { total += 4 + facts }
        total += padding
        if face.picture != .none { total = max(total, thumbnail + 2 * padding) }
        return (title, detail, facts, ceil(total))
    }

    private static func drawRich(_ face: RichCardFace, in rect: CGRect, source: String) {
        let measures = richLayout(face, width: rect.width)
        switch face.picture {
        case .thumbnail(let url):
            fill(PhoneCards.picture(url, for: source), in: CGRect(x: rect.maxX - padding - thumbnail, y: rect.minY + padding, width: thumbnail, height: thumbnail), corner: 8)
        case .artwork(let url):
            fill(PhoneCards.picture(url, for: source), in: CGRect(x: rect.minX + padding, y: rect.minY + padding, width: thumbnail, height: thumbnail), corner: 8)
        case .none:
            break
        }
        let insets = richInsets(face)
        let textWidth = rect.width - insets.left - insets.right
        var x = rect.minX + insets.left
        var y = rect.minY + padding
        let tint = face.tint.map { UIColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1) } ?? Ink.secondary
        if let icon = face.icon.flatMap({ PhoneCards.picture($0, for: source) }) {
            icon.draw(in: CGRect(x: x, y: y + 1, width: 15, height: 15))
            x += 20
        } else if let symbol = UIImage(systemName: face.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))?
            .withTintColor(tint, renderingMode: .alwaysOriginal) {
            symbol.draw(at: CGPoint(x: x, y: y + (17 - symbol.size.height) / 2))
            x += symbol.size.width + 5
        }
        (face.service as NSString).draw(with: CGRect(x: x, y: y, width: rect.minX + insets.left + textWidth - x, height: 17),
                                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: [.font: richServiceFont, .foregroundColor: face.tint == nil ? Ink.secondary : tint], context: nil)
        y += 17 + 4
        x = rect.minX + insets.left
        (face.title as NSString).draw(with: CGRect(x: x, y: y, width: textWidth, height: measures.title),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: [.font: richTitleFont, .foregroundColor: Ink.text], context: nil)
        y += measures.title
        if let detail = face.detail, measures.detail > 0 {
            y += 3
            (detail as NSString).draw(with: CGRect(x: x, y: y, width: textWidth, height: measures.detail),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: [.font: richDetailFont, .foregroundColor: Ink.secondary], context: nil)
            y += measures.detail
        }
        if let facts = face.facts, measures.facts > 0 {
            y += 4
            (facts as NSString).draw(with: CGRect(x: x, y: y, width: textWidth, height: measures.facts),
                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                     attributes: [.font: richFactsFont, .foregroundColor: Ink.faint], context: nil)
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
        case .rich(let face): drawRich(face, in: rect, source: source)
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
