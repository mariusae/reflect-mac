import ReflectCore
import UIKit

/// A row's inline Markdown as styled text: emphasis, code and struck text
/// drawn, their marks taken out; links, `[[links]]` and tags made links the
/// app follows itself; pictures taken out, to be shown beneath.
enum InlineText {
    struct Rendered {
        var text: AttributedString
        var images: [ImageReference]
    }

    static func render(_ source: String) -> Rendered {
        let ns = source as NSString
        let spans = InlineMarkup.spans(in: ns, range: NSRange(location: 0, length: ns.length))
        let styled = NSMutableAttributedString(string: source)
        var hidden: [NSRange] = []
        var images: [ImageReference] = []

        func add(_ intent: InlinePresentationIntent, _ range: NSRange) {
            let current = (styled.attribute(.inlinePresentationIntent, at: range.location, effectiveRange: nil) as? NSNumber)
                .map { InlinePresentationIntent(rawValue: $0.uintValue) } ?? []
            styled.addAttribute(.inlinePresentationIntent, value: NSNumber(value: current.union(intent).rawValue), range: range)
        }

        for span in spans {
            switch span.kind {
            case .strong: add(.stronglyEmphasized, span.content)
            case .emphasis: add(.emphasized, span.content)
            case .strikethrough: add(.strikethrough, span.content)
            case .code: add(.code, span.content)
            case .highlight:
                styled.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.4), range: span.content)
            case .link(let target), .url(let target):
                if let url = URL(string: target) { styled.addAttribute(.link, value: url, range: span.content) }
            case .wikiLink(let target):
                styled.addAttribute(.link, value: Link.note(target), range: span.content)
            case .tag:
                let name = String(ns.substring(with: span.range).dropFirst())
                styled.addAttribute(.link, value: Link.tag(name), range: span.range)
            case .image(let reference):
                images.append(reference)
            case .imageText, .comment:
                break
            }
            hidden += span.markup
        }
        // Marks inside marks — a link in a picture — are cut once.
        var merged: [NSRange] = []
        for range in hidden.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        // The marks out, last first, so the ranges before stay put.
        for range in merged.reversed() where NSMaxRange(range) <= styled.length {
            styled.deleteCharacters(in: range)
        }
        // UIKit's scope, which has the highlighter's ground as well as the rest.
        let text = (try? AttributedString(styled, including: \.uiKit)) ?? AttributedString(styled.string)
        return Rendered(text: text, images: images)
    }

    /// The app's own links, followed by `NoteLinks`.
    enum Link {
        static let scheme = "reflect"

        static func note(_ target: String) -> URL {
            var components = URLComponents()
            components.scheme = scheme
            components.host = "note"
            components.queryItems = [URLQueryItem(name: "title", value: target)]
            return components.url!
        }

        static func tag(_ name: String) -> URL {
            var components = URLComponents()
            components.scheme = scheme
            components.host = "tag"
            components.queryItems = [URLQueryItem(name: "name", value: name)]
            return components.url!
        }
    }
}
