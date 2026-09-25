import Foundation

/// What a web page says about itself, for a link's card — read by
/// Reflect's rules: the title from `og:title`, else the page's `<title>`;
/// the description from `og:description`, else `<meta name="description">`;
/// the icon from the page's declared raster icons, else `/favicon.ico`.
/// A page with no title has no card.
public struct PageMetadata: Equatable, Sendable, Codable {
    public var title: String
    public var description: String?
    public var siteName: String?
    public var iconURL: URL?

    static let maxTitle = 200
    static let maxDescription = 300

    /// Reads a page's HTML, fetched from `url` (after any redirects).
    public static func parse(html: String, url: URL) -> PageMetadata? {
        // Only the head matters, and a page can be long.
        let head = String(html.prefix(400_000))
        let metas = tags("meta", in: head)
        func meta(_ key: String, _ value: String) -> String? {
            metas.first { ($0[key] ?? "").lowercased() == value }?["content"].flatMap { normalize($0, limit: 500) }
        }
        let titleTag = head.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive])
            .map { String(head[$0]).replacingOccurrences(of: #"^<title[^>]*>|</title>$"#, with: "", options: [.regularExpression, .caseInsensitive]) }
        guard let title = (meta("property", "og:title") ?? meta("name", "twitter:title") ?? titleTag.flatMap { normalize($0, limit: 500) })
            .flatMap({ normalize($0, limit: maxTitle) }) else { return nil }
        let description = (meta("property", "og:description") ?? meta("name", "description"))
            .flatMap { normalize($0, limit: maxDescription) }
        return PageMetadata(title: title, description: description, siteName: meta("property", "og:site_name"),
                            iconURL: icon(in: head, pageURL: url))
    }

    private static func icon(in head: String, pageURL: URL) -> URL? {
        for link in tags("link", in: head) {
            let relations = (link["rel"] ?? "").lowercased().split(separator: " ")
            guard relations.contains("icon") || relations.contains("apple-touch-icon") || relations.contains("apple-touch-icon-precomposed"),
                  !(link["type"] ?? "").lowercased().contains("svg"), let href = link["href"],
                  let url = URL(string: decodeEntities(href), relativeTo: pageURL)?.absoluteURL,
                  url.scheme == "https" || url.scheme == "http", !url.path.lowercased().hasSuffix(".svg") else { continue }
            return url
        }
        return URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
    }

    /// The attributes of each `<name …>` tag in some HTML, keys lowercased.
    static func tags(_ name: String, in html: String) -> [[String: String]] {
        guard let tag = try? NSRegularExpression(pattern: "<\(name)\\b([^>]*)>", options: .caseInsensitive),
              let attribute = try? NSRegularExpression(pattern: #"([a-zA-Z_:-]+)\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'>]+))"#) else { return [] }
        let text = html as NSString
        return tag.matches(in: html, range: NSRange(location: 0, length: text.length)).map { match in
            let inside = text.substring(with: match.range(at: 1))
            var attributes: [String: String] = [:]
            for pair in attribute.matches(in: inside, range: NSRange(location: 0, length: (inside as NSString).length)) {
                let key = (inside as NSString).substring(with: pair.range(at: 1)).lowercased()
                let value = [3, 4, 5].compactMap { index -> String? in
                    let range = pair.range(at: index)
                    return range.location == NSNotFound ? nil : (inside as NSString).substring(with: range)
                }.first ?? ""
                attributes[key] = attributes[key] ?? value
            }
            return attributes
        }
    }

    /// Collapses whitespace and entities, and caps the length; nil if blank.
    static func normalize(_ value: String, limit: Int) -> String? {
        let collapsed = decodeEntities(value).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : String(collapsed.prefix(limit))
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'", "nbsp": " ",
                     "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“"]
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let semicolon = after.prefix(10).firstIndex(of: ";") else {
                result += "&"
                rest = after
                continue
            }
            let name = String(after[..<semicolon])
            if let character = named[name] {
                result += character
            } else if name.hasPrefix("#x"), let code = UInt32(name.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
            } else if name.hasPrefix("#"), let code = UInt32(name.dropFirst()), let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
            } else {
                result += "&" + name + ";"
            }
            rest = after[after.index(after: semicolon)...]
        }
        return result + rest
    }
}
