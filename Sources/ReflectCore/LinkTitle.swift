import Foundation

/// A web link's title — the words it shows — read, and set or taken away:
/// `[title](address)` with one, the address alone without.
public enum LinkTitle {
    /// The Markdown title that keeps a link's card from showing:
    /// `[text](address "no card")`.
    public static let noCard = "no card"

    /// A web link in a row's text, by its span there: where it goes, its
    /// title — empty for an address written out — and whether its card is hidden.
    public static func link(_ span: InlineSpan, in text: NSString) -> (address: String, title: String, hidesCard: Bool)? {
        switch span.kind {
        case .url(let address):
            return (address, "", false)
        case .link(let address):
            let shown = text.substring(with: span.content)
            // `<https://…>` shows its address: no title of its own.
            return (address, shown == address ? "" : shown, span.hidesCard)
        default:
            return nil
        }
    }

    /// A link to an address with a title, or none: `[title](address)` — what
    /// would end the address early there percent-encoded — or the address
    /// alone, as it was. Its card hidden, `"no card"` after the address —
    /// and, with no title, the address its own words.
    public static func markdown(address: String, title: String, hidesCard: Bool = false) -> String {
        let words = title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty || hidesCard else { return address }
        let target = address.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        let shown = words.isEmpty ? target : escaped(words)
        return hidesCard ? "[\(shown)](\(target) \"\(noCard)\")" : "[\(shown)](\(target))"
    }

    /// A title as a link's words can hold it: square brackets, which would
    /// end them, made round — as a captured page's title is.
    static func escaped(_ title: String) -> String {
        title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }

    /// A row's text with the web link at `location` retitled: the new text,
    /// and where the link now is in it. Nil when no web link is there.
    public static func retitling(_ text: String, at location: Int, to title: String) -> (text: String, range: NSRange)? {
        rewriting(text, at: location) { link in markdown(address: link.address, title: title, hidesCard: link.hidesCard) }
    }

    /// A row's text with the web link at `location`'s card shown or hidden:
    /// the new text, and where the link now is in it. Nil when no web link is there.
    public static func settingCard(_ text: String, at location: Int, hidden: Bool) -> (text: String, range: NSRange)? {
        rewriting(text, at: location) { link in markdown(address: link.address, title: link.title, hidesCard: hidden) }
    }

    /// Whether the web link at `location` has its card hidden; nil with no web link there.
    public static func hidesCard(_ text: String, at location: Int) -> Bool? {
        let ns = text as NSString
        return span(in: ns, at: location).flatMap { link($0, in: ns) }?.hidesCard
    }

    private static func span(in text: NSString, at location: Int) -> InlineSpan? {
        InlineMarkup.spans(in: text, range: NSRange(location: 0, length: text.length))
            .first(where: { NSLocationInRange(location, $0.range) || NSMaxRange($0.range) == location && $0.range.length > 0 })
    }

    private static func rewriting(_ text: String, at location: Int,
                                  _ replace: ((address: String, title: String, hidesCard: Bool)) -> String) -> (text: String, range: NSRange)? {
        let ns = text as NSString
        guard let span = span(in: ns, at: location), let link = link(span, in: ns) else { return nil }
        let replacement = replace(link)
        return (ns.replacingCharacters(in: span.range, with: replacement),
                NSRange(location: span.range.location, length: (replacement as NSString).length))
    }
}
