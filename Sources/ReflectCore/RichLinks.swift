import Foundation

/// Cards for links beyond posts and videos: what a link leads to, said
/// richly — a podcast, a paper, a repository, a Google file, or any page by
/// what it says of itself. Found from the link alone where that is enough,
/// else from the service's own free answer, and kept on disk.
public enum RichLink: Codable, Equatable, Sendable {
    case article(Article)
    case google(GoogleFile)
    case podcast(Podcast)
    case paper(Paper)
    case repository(Repository)

    public struct Article: Codable, Equatable, Sendable {
        public var site: String
        public var title: String
        public var summary: String?
        public var image: String?
        public var icon: String?
    }

    public struct GoogleFile: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case document, presentation, spreadsheets, forms, drive }
        public var kind: Kind
    }

    public struct Podcast: Codable, Equatable, Sendable {
        public var show: String
        public var author: String?
        public var episode: String?
        public var artwork: String?
        public var seconds: Int?
        public var released: Date?
        public var genre: String?
    }

    public struct Paper: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var authors: [String]
        public var published: Date?
        public var summary: String?
    }

    public struct Repository: Codable, Equatable, Sendable {
        public var name: String
        public var description: String?
        public var stars: Int?
        public var language: String?
        /// An issue's or a pull request's, when the link is to one.
        public var item: Item?

        public struct Item: Codable, Equatable, Sendable {
            public var number: Int
            public var title: String
            public var state: String
            public var isPullRequest: Bool
            public var author: String?
        }
    }
}

/// What a link to a service names, from the link alone.
public enum RichLinkKind: Equatable, Sendable {
    case google(RichLink.GoogleFile.Kind)
    /// The show's id, and an episode's, when the link names one.
    case podcast(show: String, episode: String?)
    case paper(String)
    /// `owner/repo`, and an issue's or a pull request's number.
    case repository(String, Int?)
    /// Any other page: read for what it says of itself.
    case article

    /// What a link leads to, or nil for one no card is made for.
    public static func of(_ source: String) -> RichLinkKind? {
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let parts = url.path.split(separator: "/").map(String.init)
        switch host {
        case "docs.google.com":
            let kind = parts.first.flatMap(RichLink.GoogleFile.Kind.init(rawValue:)) ?? .document
            return .google(kind)
        case "drive.google.com":
            return .google(.drive)
        case "podcasts.apple.com":
            guard let show = parts.last(where: { $0.hasPrefix("id") }).map({ String($0.dropFirst(2)) }),
                  !show.isEmpty, show.allSatisfy(\.isNumber) else { return .article }
            let episode = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "i" }?.value
            return .podcast(show: show, episode: episode?.allSatisfy(\.isNumber) == true ? episode : nil)
        case "arxiv.org", "export.arxiv.org":
            guard parts.count >= 2, ["abs", "pdf", "html"].contains(parts[0]) else { return .article }
            var id = parts.dropFirst().joined(separator: "/")
            if id.hasSuffix(".pdf") { id.removeLast(4) }
            if let v = id.range(of: #"v\d+$"#, options: .regularExpression) { id.removeSubrange(v) }
            return id.isEmpty ? .article : .paper(id)
        case "github.com":
            guard parts.count >= 2, !["orgs", "settings", "notifications", "marketplace", "sponsors", "topics", "search"].contains(parts[0])
            else { return .article }
            let name = parts[0] + "/" + parts[1]
            if parts.count >= 4, ["issues", "pull"].contains(parts[2]), let number = Int(parts[3]) { return .repository(name, number) }
            return .repository(name, nil)
        default:
            // Sign-in pages, not what they lead to: no card.
            if Self.isPrivate(host) { return nil }
            // Nothing to say of a site's front page, nor of a file.
            if parts.isEmpty { return nil }
            if let last = parts.last?.lowercased(), [".pdf", ".png", ".jpg", ".jpeg", ".gif", ".zip", ".mp4", ".mov"].contains(where: last.hasSuffix) {
                return nil
            }
            return .article
        }
    }

    /// Hosts that answer only behind a sign-in: a card would say nothing.
    private static func isPrivate(_ host: String) -> Bool {
        ["internalfb.com", "fb.workplace.com", "fburl.com", "fb.quip.com", "l.workplace.com", "chat.google.com", "mail.google.com",
         "calendar.google.com", "localhost"].contains { host == $0 || host.hasSuffix("." + $0) }
            || host.hasSuffix(".instructure.com") || host.hasSuffix(".hotcrp.com")
    }

    /// Whether the card is known from the link alone, with nothing to fetch.
    public var isOffline: Bool { if case .google = self { true } else { false } }
}

public enum RichLinks {
    /// The card a link shows, from its cache in a folder: nil when not
    /// there; `.some(nil)` when it was looked for and there is none.
    public static func cached(_ source: String, in folder: URL) -> RichLink?? {
        guard let kind = RichLinkKind.of(source) else { return .some(nil) }
        if case .google(let file) = kind { return .some(.google(.init(kind: file))) }
        let file = cacheFile(source, in: folder)
        if FileManager.default.fileExists(atPath: file.path + ".gone") { return .some(nil) }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return .some(try? JSONDecoder().decode(RichLink.self, from: data))
    }

    /// The card a link shows, fetched and kept in the folder; nil for none
    /// — kept as none when the service says there is none.
    public static func load(_ source: String, in folder: URL) async -> RichLink? {
        if let known = cached(source, in: folder) { return known }
        guard let kind = RichLinkKind.of(source) else { return nil }
        let file = cacheFile(source, in: folder)
        let (card, definite) = await fetch(source, kind: kind)
        if let card, let data = try? JSONEncoder().encode(card) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        } else if definite {
            FileManager.default.createFile(atPath: file.path + ".gone", contents: nil)
        }
        return card
    }

    static func cacheFile(_ source: String, in folder: URL) -> URL {
        var hash: UInt64 = 14695981039346656037
        for byte in source.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return folder.appendingPathComponent("link-\(String(hash, radix: 16)).json")
    }

    // MARK: Fetching

    private static let safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    /// What link previewers send: sites that turn browsers away — Amazon,
    /// Instagram — answer it with the page's own preview.
    private static let previewer = "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"

    /// Fetched: the data, the final address, and whether the answer is a
    /// definite no — a 404 or a 410, not a network failure.
    private static func get(_ url: URL, agent: String = safari) async -> (data: Data?, url: URL?, gone: Bool) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (nil, nil, false) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        return ((200..<300).contains(status) ? data : nil, response.url, status == 404 || status == 410)
    }

    private static func fetch(_ source: String, kind: RichLinkKind) async -> (RichLink?, Bool) {
        switch kind {
        case .google(let file): return (.google(.init(kind: file)), true)
        case .podcast(let show, let episode): return await podcast(show: show, episode: episode)
        case .paper(let id): return await paper(id)
        case .repository(let name, let number): return await repository(name, number)
        case .article: return await article(source)
        }
    }

    private static func json(_ data: Data?) -> [String: Any]? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func podcast(show: String, episode: String?) async -> (RichLink?, Bool) {
        let iso = ISO8601DateFormatter()
        func results(_ query: String) async -> [[String: Any]]? {
            guard let url = URL(string: "https://itunes.apple.com/lookup?\(query)") else { return nil }
            return json(await get(url).data)?["results"] as? [[String: Any]]
        }
        guard let showResults = await results("id=\(show)"), let found = showResults.first else { return (nil, false) }
        var card = RichLink.Podcast(show: found["collectionName"] as? String ?? found["trackName"] as? String ?? "Podcast",
                                    author: found["artistName"] as? String,
                                    artwork: (found["artworkUrl600"] ?? found["artworkUrl100"]) as? String,
                                    genre: found["primaryGenreName"] as? String)
        if let episode, let episodes = await results("id=\(show)&entity=podcastEpisode&limit=200"),
           let item = episodes.first(where: { ($0["trackId"] as? Int).map(String.init) == episode }) {
            card.episode = item["trackName"] as? String
            card.seconds = (item["trackTimeMillis"] as? Int).map { $0 / 1000 }
            card.released = (item["releaseDate"] as? String).flatMap(iso.date(from:))
            if let art = (item["artworkUrl600"] ?? item["artworkUrl160"]) as? String { card.artwork = art }
        }
        return (.podcast(card), false)
    }

    private static func paper(_ id: String) async -> (RichLink?, Bool) {
        guard let url = URL(string: "https://export.arxiv.org/api/query?id_list=\(id)"),
              let data = await get(url).data else { return (nil, false) }
        let xml = String(decoding: data, as: UTF8.self)
        guard let entry = xml.range(of: "<entry>").map({ String(xml[$0.upperBound...]) }) else { return (nil, true) }
        func tag(_ name: String, in text: String) -> [String] {
            let pattern = "<\(name)[^>]*>([\\s\\S]*?)</\(name)>"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let ns = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
                ns.substring(with: $0.range(at: 1)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
        }
        guard let title = tag("title", in: entry).first, !title.isEmpty else { return (nil, true) }
        let authors = tag("author", in: entry).flatMap { tag("name", in: $0) }
        let published = tag("published", in: entry).first.flatMap { ISO8601DateFormatter().date(from: $0) }
        return (.paper(.init(id: id, title: title, authors: authors, published: published,
                             summary: tag("summary", in: entry).first.map { String($0.prefix(400)) })), false)
    }

    private static func repository(_ name: String, _ number: Int?) async -> (RichLink?, Bool) {
        guard let url = URL(string: "https://api.github.com/repos/\(name)") else { return (nil, true) }
        let answer = await get(url)
        guard let repo = json(answer.data) else { return (nil, answer.gone) }
        var card = RichLink.Repository(name: repo["full_name"] as? String ?? name, description: repo["description"] as? String,
                                       stars: repo["stargazers_count"] as? Int, language: repo["language"] as? String)
        if let number, let itemURL = URL(string: "https://api.github.com/repos/\(name)/issues/\(number)"),
           let item = json(await get(itemURL).data), let title = item["title"] as? String {
            let merged = (item["pull_request"] as? [String: Any])?["merged_at"] is String
            card.item = .init(number: number, title: title, state: merged ? "merged" : item["state"] as? String ?? "open",
                              isPullRequest: item["pull_request"] != nil,
                              author: (item["user"] as? [String: Any])?["login"] as? String)
        }
        return (.repository(card), false)
    }

    private static func article(_ source: String) async -> (RichLink?, Bool) {
        guard let url = URL(string: source), let host = url.host?.lowercased() else { return (nil, true) }
        let blocking = ["amazon.", "a.co", "instagram.com", "amzn."].contains { host.contains($0) }
        func read(_ agent: String) async -> (PageMetadata?, URL?, Bool) {
            let answer = await get(url, agent: agent)
            guard let data = answer.data else { return (nil, nil, answer.gone) }
            let html = String(decoding: data.prefix(600_000), as: UTF8.self)
            return (PageMetadata.parse(html: html, url: answer.url ?? url), answer.url, false)
        }
        var (found, final, gone) = await read(blocking ? previewer : safari)
        // Turned away as a browser — a paywall's bot check: as a previewer.
        if found == nil, !gone, !blocking { (found, final, gone) = await read(previewer) }
        guard let meta = found else { return (nil, gone) }
        let answer = (url: final, data: ())
        var site = meta.siteName ?? (answer.url ?? url).host ?? host
        if site.hasPrefix("www.") { site.removeFirst(4) }
        return (.article(.init(site: site, title: meta.title, summary: meta.description, image: meta.imageURL?.absoluteString,
                               icon: meta.iconURL?.absoluteString)), false)
    }
}

/// What a card shows, however it is drawn: the service, a title, a line or
/// two more, a line of facts, and a picture — the same on the Mac and the
/// phone.
public struct RichCardFace: Equatable, Sendable {
    public enum Picture: Equatable, Sendable {
        case none
        /// A page's picture, at the right.
        case thumbnail(String)
        /// A cover — a podcast's — square, at the left.
        case artwork(String)
    }

    public var service: String
    /// An SF Symbol for the service.
    public var symbol: String
    /// The service's colour, as sRGB.
    public var tint: (Double, Double, Double)?
    public var title: String
    public var detail: String?
    public var facts: String?
    public var picture: Picture
    /// A site's icon, before its name.
    public var icon: String?

    public static func == (a: RichCardFace, b: RichCardFace) -> Bool {
        a.service == b.service && a.title == b.title && a.detail == b.detail && a.facts == b.facts && a.picture == b.picture
    }

    /// A card's face; `linkText`, what the note calls the link, for a card
    /// that cannot read the file's own name.
    public init(_ card: RichLink, linkText: String?) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        icon = nil
        tint = nil
        detail = nil
        facts = nil
        picture = .none
        switch card {
        case .article(let page):
            service = page.site
            symbol = "globe"
            title = page.title
            detail = page.summary
            picture = page.image.map(Picture.thumbnail) ?? .none
            icon = page.icon
        case .google(let file):
            (service, symbol, tint) = switch file.kind {
            case .document: ("Google Docs", "doc.text.fill", (0.26, 0.52, 0.96))
            case .presentation: ("Google Slides", "rectangle.on.rectangle.angled.fill", (0.96, 0.71, 0.0))
            case .spreadsheets: ("Google Sheets", "tablecells.fill", (0.06, 0.62, 0.35))
            case .forms: ("Google Forms", "list.bullet.rectangle.fill", (0.40, 0.23, 0.72))
            case .drive: ("Google Drive", "externaldrive.fill", (0.26, 0.52, 0.96))
            }
            title = linkText.flatMap { $0.hasPrefix("http") ? nil : $0 } ?? "Untitled"
        case .podcast(let podcast):
            service = "Apple Podcasts"
            symbol = "waveform"
            tint = (0.6, 0.27, 0.93)
            title = podcast.episode ?? podcast.show
            detail = podcast.episode == nil ? podcast.author : [podcast.show, podcast.author].compactMap { $0 }.joined(separator: " · ")
            var bits: [String] = []
            if let released = podcast.released { bits.append(formatter.string(from: released)) }
            if let seconds = podcast.seconds, seconds > 0 {
                bits.append(seconds >= 3600 ? "\(seconds / 3600) hr \(seconds % 3600 / 60) min" : "\(max(1, seconds / 60)) min")
            }
            if podcast.episode == nil, let genre = podcast.genre { bits.append(genre) }
            facts = bits.isEmpty ? nil : bits.joined(separator: " · ")
            picture = podcast.artwork.map(Picture.artwork) ?? .none
        case .paper(let paper):
            service = "arXiv · " + paper.id
            symbol = "doc.richtext"
            tint = (0.70, 0.11, 0.11)
            title = paper.title
            let names = paper.authors.count > 3 ? paper.authors.prefix(3).joined(separator: ", ") + " et al." : paper.authors.joined(separator: ", ")
            detail = names.isEmpty ? nil : names
            facts = [paper.published.map { formatter.string(from: $0) }, paper.summary].compactMap { $0 }.joined(separator: " — ")
        case .repository(let repo):
            service = "GitHub"
            symbol = repo.item == nil ? "shippingbox" : repo.item?.isPullRequest == true ? "arrow.triangle.pull" : "smallcircle.filled.circle"
            if let item = repo.item {
                title = item.title
                detail = "\(repo.name) #\(item.number)"
                facts = [item.state.capitalized, item.author.map { "by " + $0 }].compactMap { $0 }.joined(separator: " · ")
            } else {
                title = repo.name
                detail = repo.description
                facts = [repo.language, repo.stars.map { "★ " + Self.count($0) }].compactMap { $0 }.joined(separator: " · ")
            }
        }
        if facts?.isEmpty == true { facts = nil }
    }

    private static func count(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000).replacingOccurrences(of: ".0k", with: "k") : String(n)
    }
}
