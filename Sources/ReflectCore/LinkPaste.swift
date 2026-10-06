import Foundation

/// A link pasted on words: the words made a link to it — `[words](address)`
/// — or, when they are a link's words already, that link pointed there.
/// The Mac's and the phone's, the same.
public enum LinkPaste {
    /// Text that is a web or mail address and nothing else, trimmed.
    public static func address(in text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme), scheme == "mailto" || url.host != nil else { return nil }
        return text
    }

    /// A row's text with the words chosen in it — a range of it, in UTF-16 —
    /// linked to an address, and where the caret goes after: the link's end.
    /// Nil when nothing is chosen, when it spans lines, or when it is an
    /// address itself.
    public static func link(_ row: String, selection: NSRange, to address: String) -> (text: String, caret: Int)? {
        let text = row as NSString
        guard selection.length > 0, NSMaxRange(selection) <= text.length else { return nil }
        let words = text.substring(with: selection)
        guard !words.contains("\n"), !words.contains("\u{2028}"), self.address(in: words) == nil else { return nil }
        // Brackets and spaces in an address would end its Markdown early.
        let target = address.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
        let spans = InlineMarkup.spans(in: text, range: NSRange(location: 0, length: text.length))
        if let span = spans.first(where: { span in
            guard case .link = span.kind else { return false }
            return NSLocationInRange(selection.location, span.content) && NSMaxRange(selection) <= NSMaxRange(span.content)
        }), let close = span.markup.last {
            // Already a link's words: only where it goes changes.
            let old = NSRange(location: close.location + 2, length: max(0, close.length - 3))
            return (text.replacingCharacters(in: old, with: target), NSMaxRange(span.range) - old.length + (target as NSString).length)
        }
        let escaped = words.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let markdown = "[\(escaped)](\(target))"
        return (text.replacingCharacters(in: selection, with: markdown), selection.location + (markdown as NSString).length)
    }
}
