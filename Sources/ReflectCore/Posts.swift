import Foundation

/// A post on X (Twitter), as much of it as a card shows.
public struct Tweet: Codable, Sendable {
    public struct User: Codable, Sendable {
        public var name: String
        public var screenName: String
        public var avatar: String?
    }

    public struct Media: Codable, Sendable {
        public var url: String
        public var width: Double
        public var height: Double
        public var isVideo: Bool
    }

    public var id: String
    public var text: String
    public var date: Date?
    public var user: User
    public var media: Media?
    /// Where it was posted.
    public var site: Site = .x
    /// When, as the site says it, where it gives no date to read.
    public var when: String?

    public enum Site: String, Codable, Sendable { case x, threads }

    /// The post a link names: `https://x.com/who/status/123…`, twitter.com's
    /// — with or without `www.` or `mobile.` — its `/i/web/status/123` and
    /// `/statuses/123`, and those of the sites that re-embed posts.
    public static func id(from source: String) -> String? {
        guard let url = URL(string: source), var host = url.host?.lowercased() else { return nil }
        for prefix in ["www.", "mobile.", "m."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        guard ["x.com", "twitter.com", "fxtwitter.com", "vxtwitter.com", "fixupx.com", "fixvx.com"].contains(host) else { return nil }
        let parts = url.path.split(separator: "/")
        guard let at = parts.firstIndex(where: { $0 == "status" || $0 == "statuses" }), at + 1 < parts.count,
              !parts[at + 1].isEmpty, parts[at + 1].allSatisfy(\.isNumber) else { return nil }
        return String(parts[at + 1])
    }

    /// Reads the embed endpoint's answer, or nil for one that is not a
    /// post. A post that was — deleted, withheld — is a card saying so, as
    /// the endpoint's tombstone does.
    public init?(json data: Data, id: String) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if root["__typename"] as? String == "TweetTombstone" {
            let said = ((root["tombstone"] as? [String: Any])?["text"] as? [String: Any])?["text"] as? String
            self.id = id
            text = (said ?? "This post is unavailable.").replacingOccurrences(of: " Learn more", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            user = User(name: "Post unavailable", screenName: "", avatar: nil)
            return
        }
        guard var text = root["text"] as? String,
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
    public static func endpoint(for id: String) -> URL? {
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

extension Tweet {
    /// A Threads post a link names, as the path to it: `@who/post/CODE`, or
    /// a share link's `share/CODE`, which leads to one.
    public static func threadsPath(from source: String) -> String? {
        guard let url = URL(string: source), var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard host == "threads.com" || host == "threads.net" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count >= 3, parts[0].hasPrefix("@"), parts[1] == "post", !parts[2].isEmpty {
            return parts[0...2].joined(separator: "/")
        }
        if parts.count >= 2, parts[0] == "share", !parts[1].isEmpty { return "share/" + parts[1] }
        return nil
    }

    /// Reads a Threads post's embed page: who, what, when, and its first
    /// picture — the post's own, or the preview of what it links.
    public init?(threadsEmbed html: String, path: String) {
        func text(_ fragment: String) -> String {
            var s = fragment.replacingOccurrences(of: "<br />", with: "\n").replacingOccurrences(of: "<br>", with: "\n")
            s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#064;", "@"), ("&#x27;", "'")] {
                s = s.replacingOccurrences(of: entity, with: character)
            }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func first(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }
        guard let name = first(#"class="HeaderLink"[^>]*><span>([^<]+)</span>"#) else { return nil }
        let body = first(#"class="BodyTextContainer">(.*?)</span></span>"#).map(text) ?? ""
        self.id = path
        self.text = body
        self.site = .threads
        self.when = first(#"class="Timestamp">([^<]+)<"#).map(text)
        let avatar = first(#"class="AvatarContainer"><img class="img" src="([^"]+)""#).map { $0.replacingOccurrences(of: "&amp;", with: "&") }
        self.user = User(name: text(name), screenName: text(name), avatar: avatar)
        let picture = first(#"class="(?:SingleInnerMediaContainer|MediaContainer)[^"]*"[^>]*>.*?<img[^>]+src="([^"]+)""#)
            ?? first(#"LinkAttachmentImage" style="background-image: url\(([^)]+)\)"#)
        if let picture {
            media = Media(url: picture.replacingOccurrences(of: "&amp;", with: "&"), width: 16, height: 9, isVideo: false)
        }
    }

    /// The key a post is kept under, from a link: an X post's id, a Threads post's path.
    public static func key(from source: String) -> String? {
        id(from: source) ?? threadsPath(from: source).map { "threads-" + $0.replacingOccurrences(of: "/", with: "-") }
    }
}

/// A YouTube video, as much of it as a card shows: from YouTube's oEmbed
/// answer, as Reflect's editor reads it.
public struct Video: Sendable {
    public var id: String
    public var title: String
    public var author: String
    public var thumbnail: String?

    /// The video a link names: `youtube.com/watch?v=…`, `youtu.be/…`, and
    /// `/shorts/`, `/live/` and `/embed/` ones — on `www.`, `m.` or `music.`.
    public static func id(from source: String) -> String? {
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
    public static func endpoint(for id: String) -> URL? {
        let watch = "https://www.youtube.com/watch?v=\(id)"
        return URL(string: "https://www.youtube.com/oembed?format=json&url=" + (watch.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? watch))
    }

    /// Reads oEmbed's answer, or nil for anything else.
    public init?(json data: Data, id: String) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = root["title"] as? String else { return nil }
        self.id = id
        self.title = title
        author = root["author_name"] as? String ?? ""
        thumbnail = root["thumbnail_url"] as? String ?? "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"
    }
}

