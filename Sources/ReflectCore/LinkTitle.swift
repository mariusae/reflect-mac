import Foundation

/// A web link's title — the words it shows — read, and set or taken away:
/// `[title](address)` with one, the address alone without.
public enum LinkTitle {
    /// A web link in a row's text, by its span there: where it goes, and
    /// its title — empty for an address written out.
    public static func link(_ span: InlineSpan, in text: NSString) -> (address: String, title: String)? {
        switch span.kind {
        case .url(let address):
            return (address, "")
        case .link(let address):
            let shown = text.substring(with: span.content)
            // `<https://…>` shows its address: no title of its own.
            return (address, shown == address ? "" : shown)
        default:
            return nil
        }
    }

    /// A link to an address with a title, or none: `[title](address)` — what
    /// would end the address early there percent-encoded — or the address
    /// alone, as it was.
    public static func markdown(address: String, title: String) -> String {
        let words = title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return address }
        let target = address.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return "[\(escaped(words))](\(target))"
    }

    /// A title as a link's words can hold it: square brackets, which would
    /// end them, made round — as a captured page's title is.
    static func escaped(_ title: String) -> String {
        title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }

    /// A row's text with the web link at `location` retitled: the new text,
    /// and where the link now is in it. Nil when no web link is there.
    public static func retitling(_ text: String, at location: Int, to title: String) -> (text: String, range: NSRange)? {
        let ns = text as NSString
        guard let span = InlineMarkup.spans(in: ns, range: NSRange(location: 0, length: ns.length))
                .first(where: { NSLocationInRange(location, $0.range) || NSMaxRange($0.range) == location && $0.range.length > 0 }),
              let link = link(span, in: ns) else { return nil }
        let replacement = markdown(address: link.address, title: title)
        return (ns.replacingCharacters(in: span.range, with: replacement),
                NSRange(location: span.range.location, length: (replacement as NSString).length))
    }
}
