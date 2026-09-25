import Foundation

/// A stretch of inline Markdown in a row: what it is, the text it shows, and
/// the markup around that text, which the editor hides.
public struct InlineSpan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case strong, emphasis, strikethrough, code
        /// `[text](url)`, and `<url>`.
        case link(String)
        /// `[[title]]` or `[[title|text]]`.
        case wikiLink(String)
        /// A bare `https://…`; nothing to hide.
        case url(String)
        /// `![text](source)`, and the size Reflect's editor may note in a
        /// comment straight after it: `<!-- {"width":425,"height":270} -->`.
        /// Drawn as the picture; the Markdown is hidden, whole.
        case image(ImageReference)
        /// An image the app cannot show — a page, not a picture — left as
        /// the Markdown it is.
        case imageText
        /// `<!-- … -->`, hidden whole.
        case comment
        case tag
    }

    public var kind: Kind
    /// The span, markup included.
    public var range: NSRange
    /// The text it shows. Empty, at the span's start, for a comment.
    public var content: NSRange

    public var isImage: Bool { if case .image = kind { true } else { false } }

    /// The markup before and after the content, which is not shown.
    public var markup: [NSRange] {
        switch kind {
        case .url, .imageText, .tag: return []
        case .comment, .image: return [range]
        default:
            return [NSRange(location: range.location, length: content.location - range.location),
                    NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content))]
                .filter { $0.length > 0 }
        }
    }
}

/// Where an image comes from, and the size it is to be shown at, when the
/// note says.
public struct ImageReference: Equatable, Hashable, Sendable {
    public var source: String
    public var alt: String
    public var width: Double?
    public var height: Double?

    public init(source: String, alt: String = "", width: Double? = nil, height: Double? = nil) {
        self.source = source
        self.alt = alt
        self.width = width
        self.height = height
    }

    /// Reads `{"width":425,"height":270}`, either key alone, or neither.
    static func size(from json: String) -> (width: Double?, height: Double?) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        func number(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
        return (number("width"), number("height"))
    }
}

/// Finding the inline Markdown in a line of text.
///
/// Code comes first, since nothing inside it is Markdown; then links, whose
/// addresses are not either; then emphasis, which may sit inside a link's
/// text, or hold one, but never straddle its markup.
public enum InlineMarkup {
    private static let code = try! NSRegularExpression(pattern: #"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let comment = try! NSRegularExpression(pattern: #"<!--.*?-->"#)
    private static let image = try! NSRegularExpression(pattern: #"!\[([^\[\]\n]*)\]\(([^)\s]*)\)(?:<!--\s*(\{[^{}\n]*\})\s*-->)?"#)
    private static let wiki = try! NSRegularExpression(pattern: #"\[\[([^\[\]|\n]+)(?:\|([^\[\]\n]*))?\]\]"#)
    private static let link = try! NSRegularExpression(pattern: #"\[([^\[\]\n]+)\]\(([^)\s]*)\)"#)
    private static let autolink = try! NSRegularExpression(pattern: #"<(https?://[^\s<>]+)>"#)
    private static let url = try! NSRegularExpression(pattern: #"\bhttps?://[^\s<>\x{2028}]+[^\s<>.,;:!?)\]'"\x{2028}]"#)
    private static let tag = try! NSRegularExpression(pattern: #"(?<=^|\s)#\p{L}[\p{L}\p{N}/_-]*"#)
    private static let strong = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let strike = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let emphasis = try! NSRegularExpression(pattern: #"(?<![*_\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*_\w])"#)

    /// The spans in a range of text, outermost first where they nest.
    public static func spans(in text: NSString, range: NSRange) -> [InlineSpan] {
        var spans: [InlineSpan] = []
        let string = text as String

        func add(_ pattern: NSRegularExpression, _ make: (NSTextCheckingResult) -> InlineSpan?) {
            pattern.enumerateMatches(in: string, range: range) { match, _, _ in
                guard let match, let span = make(match), fits(span, among: spans) else { return }
                spans.append(span)
            }
        }
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String {
            text.substring(with: match.range(at: index))
        }

        add(code) { InlineSpan(kind: .code, range: $0.range, content: $0.range(at: 2)) }
        add(image) { match in
            let size = match.range(at: 3).location == NSNotFound ? (nil, nil) : ImageReference.size(from: group(match, 3))
            let reference = ImageReference(source: group(match, 2), alt: group(match, 1), width: size.0, height: size.1)
            return InlineSpan(kind: .image(reference), range: match.range, content: NSRange(location: match.range.location, length: 0))
        }
        add(comment) { InlineSpan(kind: .comment, range: $0.range, content: NSRange(location: $0.range.location, length: 0)) }
        add(wiki) { match in
            let label = match.range(at: 2)
            let content = label.location != NSNotFound && label.length > 0 ? label : match.range(at: 1)
            return InlineSpan(kind: .wikiLink(group(match, 1)), range: match.range, content: content)
        }
        add(link) { InlineSpan(kind: .link(group($0, 2)), range: $0.range, content: $0.range(at: 1)) }
        add(autolink) { InlineSpan(kind: .link(group($0, 1)), range: $0.range, content: $0.range(at: 1)) }
        add(url) { InlineSpan(kind: .url(text.substring(with: $0.range)), range: $0.range, content: $0.range) }
        add(tag) { InlineSpan(kind: .tag, range: $0.range, content: $0.range) }
        add(strong) { InlineSpan(kind: .strong, range: $0.range, content: $0.range(at: 2)) }
        add(strike) { InlineSpan(kind: .strikethrough, range: $0.range, content: $0.range(at: 1)) }
        add(emphasis) { InlineSpan(kind: .emphasis, range: $0.range, content: $0.range(at: 2)) }
        return spans.sorted { ($0.range.location, -$0.range.length) < ($1.range.location, -$1.range.length) }
    }

    /// Whether a span can stand beside those found before it: apart from
    /// each, or wholly inside the text of one, or holding one wholly in its
    /// own text. Nothing goes inside code, a URL, or an image.
    private static func fits(_ span: InlineSpan, among spans: [InlineSpan]) -> Bool {
        spans.allSatisfy { other in
            if NSIntersectionRange(span.range, other.range).length == 0 { return true }
            let opaque: Bool
            switch other.kind {
            case .code, .url, .image, .imageText, .comment, .tag: opaque = true
            default: opaque = false
            }
            if !opaque, contains(other.content, span.range) { return true }
            if contains(span.content, other.range) {
                if case .code = span.kind { return false }
                return true
            }
            return false
        }
    }

    private static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    /// The runs of hidden markup in a range, each run the markup of one
    /// span, in order.
    public static func hiddenRuns(in text: NSString, range: NSRange) -> [NSRange] {
        spans(in: text, range: range).flatMap(\.markup).sorted { $0.location < $1.location }
    }
}
