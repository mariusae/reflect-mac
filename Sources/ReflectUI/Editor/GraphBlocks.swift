import AppKit
import GraphKit
import ReflectCore

/// The graph an outline is in, for what it draws from it: what a
/// ```` ```query ```` block finds, a page `![[embedded]]`. `title` is the
/// page the outline is, which `{this}` stands for.
package struct OutlineGraph {
    package var pages: PageIndex
    package var title: String

    package init(pages: PageIndex, title: String) {
        self.pages = pages
        self.title = title
    }
}

extension OutlineGraph {
    /// The graph's pages, for every note shown: set by the app once they
    /// are read; `changed` posted when they change, to draw them again.
    @MainActor package static var pages: PageIndex? {
        didSet { NotificationCenter.default.post(name: changed, object: nil) }
    }

    package static let changed = Notification.Name("ReflectOutlineGraphChanged")
}

/// A block of text drawn under a row, from the graph: a query's results, or
/// a page embedded — framed, its titles links. It is laid out at whatever
/// width the row has, so it is measured there too.
package final class OutlineBlock: NSObject {
    package let text: NSAttributedString
    private static let padding: CGFloat = 10

    package init(text: NSAttributedString) {
        self.text = text
    }

    /// Its height at a width, frame and all.
    package func height(width: CGFloat) -> CGFloat {
        let inner = max(40, width - 2 * Self.padding)
        let used = text.boundingRect(with: NSSize(width: inner, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return ceil(used) + 2 * Self.padding
    }

    package func draw(in rect: NSRect, ink: TextInk) {
        let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 6, yRadius: 6)
        ink.text.withAlphaComponent(0.035).setFill()
        frame.fill()
        frame.lineWidth = 0.5
        ink.rule.setStroke()
        frame.stroke()
        text.draw(with: rect.insetBy(dx: Self.padding, dy: Self.padding), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    /// The link under a point in the rectangle it is drawn in.
    package func link(at point: NSPoint, in rect: NSRect) -> URL? {
        let inner = rect.insetBy(dx: Self.padding, dy: Self.padding)
        guard inner.contains(point) else { return nil }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: inner.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let local = NSPoint(x: point.x - inner.minX, y: point.y - inner.minY)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        let character = layout.characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        return storage.attribute(.link, at: character, effectiveRange: nil) as? URL
    }
}

/// What a row draws from the graph.
package enum GraphBlocks {
    /// The most a block lists; the rest are counted.
    private static let most = 40

    /// The query a code row is, if it is a ```` ```query ```` block.
    package static func query(in rowText: String) -> Query? {
        let lines = rowText.components(separatedBy: CharacterSet(charactersIn: "\n\u{2028}"))
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first.hasPrefix("```") || first.hasPrefix("~~~"),
              first.drop(while: { $0 == "`" || $0 == "~" }).trimmingCharacters(in: .whitespaces).lowercased() == "query" else { return nil }
        var body = Array(lines.dropFirst())
        if let last = body.last?.trimmingCharacters(in: .whitespaces), last.hasPrefix("```") || last.hasPrefix("~~~") { body.removeLast() }
        return Query(text: body.joined(separator: "\n"))
    }

    /// The page a row embeds, if all it says is `![[Title]]` — and the
    /// title is a page's, not a picture's.
    package static func embedded(in rowText: String) -> String? {
        let text = rowText.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("![["), text.hasSuffix("]]"), text.count > 5 else { return nil }
        var target = String(text.dropFirst(3).dropLast(2))
        if let bar = target.firstIndex(of: "|") { target = String(target[..<bar]) }
        target = target.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, !target.contains("]]"), !target.contains("[["),
              !["png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "pdf"].contains((target as NSString).pathExtension.lowercased())
        else { return nil }
        return target
    }

    // MARK: Drawing

    private struct Faces {
        var body: NSFont
        var bold: NSFont
        var label: [NSAttributedString.Key: Any]
        var ink: TextInk

        init(_ metrics: OutlineMetrics) {
            let size = round(metrics.fontSize * 0.9)
            body = Typography.font(metrics.typography.bodyFamily, face: metrics.typography.bodyFace, size: size)
            bold = NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask)
            ink = metrics.typography.ink
            label = [.font: NSFont.systemFont(ofSize: round(metrics.fontSize * 0.68), weight: .semibold),
                     .foregroundColor: ink.label, .kern: 0.6]
        }

        func plain(_ text: String, secondary: Bool = false) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: body, .foregroundColor: secondary ? ink.secondary : ink.text])
        }

        func link(_ title: String, shown: String? = nil, bold: Bool = false) -> NSAttributedString {
            var attributes: [NSAttributedString.Key: Any] = [.font: bold ? self.bold : body, .foregroundColor: NSColor.controlAccentColor]
            if let url = URL.wiki(title) { attributes[.link] = url }
            return NSAttributedString(string: shown ?? title, attributes: attributes)
        }
    }

    /// What a query finds, as its block says to show it.
    package static func results(of query: Query, in graph: OutlineGraph, metrics: OutlineMetrics) -> OutlineBlock {
        let faces = Faces(metrics)
        let found = query.run(in: graph.pages, this: graph.title)
        let text = NSMutableAttributedString()
        let count = found.count == 1 ? "1 page" : "\(found.count) pages"
        text.append(NSAttributedString(string: "\(query.summary) · \(count)".uppercased() + "\n", attributes: faces.label))
        let shown = Array(found.prefix(most))
        if found.isEmpty {
            text.append(faces.plain("Nothing found", secondary: true))
        } else {
            switch query.show {
            case .count:
                text.append(NSAttributedString(string: "\(found.count)", attributes: [.font: faces.bold, .foregroundColor: faces.ink.text]))
            case .inline:
                for (i, title) in shown.enumerated() {
                    if i > 0 { text.append(faces.plain(" · ", secondary: true)) }
                    text.append(faces.link(title, shown: shownTitle(title)))
                }
            case .table:
                let columns = query.columns.isEmpty ? ["tags"] : query.columns
                let style = NSMutableParagraphStyle()
                let step: CGFloat = 170
                style.tabStops = columns.indices.map { NSTextTab(textAlignment: .left, location: step * CGFloat($0 + 1)) }
                style.lineBreakMode = .byTruncatingTail
                let header = NSMutableAttributedString(string: (["Title"] + columns).joined(separator: "\t").uppercased() + "\n", attributes: faces.label)
                header.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: header.length))
                text.append(header)
                for (i, title) in shown.enumerated() {
                    let line = NSMutableAttributedString(attributedString: faces.link(title, shown: shownTitle(title)))
                    for column in columns { line.append(faces.plain("\t" + value(column, of: title, in: graph.pages), secondary: true)) }
                    if i < shown.count - 1 { line.append(faces.plain("\n")) }
                    line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
                    text.append(line)
                }
            case .list, .cards, .tree:
                for (i, title) in shown.enumerated() {
                    text.append(faces.plain("•  ", secondary: true))
                    text.append(faces.link(title, shown: shownTitle(title)))
                    if i < shown.count - 1 { text.append(faces.plain("\n")) }
                }
            }
            if found.count > shown.count { text.append(faces.plain("\nand \(found.count - shown.count) more", secondary: true)) }
        }
        return OutlineBlock(text: text)
    }

    /// A page embedded: its title, then what it says, plainly, up to a few lines.
    package static func embed(_ target: String, in graph: OutlineGraph, metrics: OutlineMetrics) -> OutlineBlock {
        let faces = Faces(metrics)
        let text = NSMutableAttributedString()
        // A saved river embedded: its name, bringing it back, then its cards.
        if let river = RiverLink.name(target) {
            text.append(NSAttributedString(string: "RIVER\n", attributes: faces.label))
            text.append(faces.link(target, shown: river, bold: true))
            guard let cards = RiverLink.cards(of: river, in: graph.pages.root) else {
                text.append(faces.plain(" isn't a saved river yet.", secondary: true))
                return OutlineBlock(text: text)
            }
            for card in cards.prefix(12) {
                text.append(faces.plain("\n• "))
                text.append(faces.link(card, shown: shownTitle(card)))
            }
            if cards.count > 12 { text.append(faces.plain("\nand \(cards.count - 12) more", secondary: true)) }
            if cards.isEmpty { text.append(faces.plain("\nNo cards.", secondary: true)) }
            return OutlineBlock(text: text)
        }
        guard let title = graph.pages.title(for: target), let page = graph.pages[title] else {
            text.append(NSAttributedString(string: "EMBEDDED\n", attributes: faces.label))
            text.append(faces.link(target, bold: true))
            text.append(faces.plain(" isn't written yet.", secondary: true))
            return OutlineBlock(text: text)
        }
        text.append(faces.link(title, shown: shownTitle(title), bold: true))
        let lines = page.text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("---") && !["-", "*", "+", ">"].contains($0) }
        let shown = lines.prefix(10).map { line -> String in
            var line = line
            for marker in ["- [ ] ", "- [x] ", "+ [ ] ", "+ [x] ", "- ", "* ", "> ", "#### ", "### ", "## ", "# "] where line.hasPrefix(marker) {
                line = (marker.contains("[") ? (marker.contains("x") ? "☑ " : "☐ ") : marker.hasPrefix("-") || marker.hasPrefix("*") ? "• " : "")
                    + line.dropFirst(marker.count)
                break
            }
            return InlineMarkup.plainText(line.replacingOccurrences(of: "![[", with: "[["))
        }.filter { !["", "•", "• "].contains($0.trimmingCharacters(in: .whitespaces)) }
        for line in shown { text.append(faces.plain("\n" + line)) }
        if lines.count > shown.count { text.append(faces.plain("\n…", secondary: true)) }
        return OutlineBlock(text: text)
    }

    private static func shownTitle(_ title: String) -> String {
        guard let day = Day(title), let date = day.date else { return title }
        return date.formatted(date: .complete, time: .omitted)
    }

    private static func value(_ column: String, of title: String, in pages: PageIndex) -> String {
        guard let page = pages[title] else { return "" }
        switch column.lowercased() {
        case "tags": return pages.tags(of: title).joined(separator: ", ")
        case "modified": return pages.entries[title]?.modified.formatted(date: .abbreviated, time: .omitted) ?? ""
        case "created": return page.created?.formatted(date: .abbreviated, time: .omitted) ?? ""
        default:
            switch page[field: column] {
            case .text(let text): return text
            case .list(let list): return list.joined(separator: ", ")
            case nil: return ""
            }
        }
    }
}

/// `> [!TIP] Title`: a quote that is a callout, as GitHub and Obsidian
/// write them — its bar and ground in its kind's colour, its kind a label.
package enum Callout {
    package static let key = NSAttributedString.Key("ReflectOutlineCallout")

    /// The kind a quote row's text opens with, and where its `[!KIND]` is in it.
    package static func marker(in text: NSString, paragraph: NSRange) -> (kind: String, range: NSRange)? {
        let body = text.substring(with: paragraph)
        let leading = body.prefix(while: { $0 == " " || $0 == ">" }).count
        let rest = body.dropFirst(leading)
        guard rest.hasPrefix("[!"), let close = rest.firstIndex(of: "]") else { return nil }
        let kind = rest[rest.index(rest.startIndex, offsetBy: 2)..<close]
        guard !kind.isEmpty, kind.allSatisfy({ $0.isLetter }) else { return nil }
        let length = (String(rest[..<close]) as NSString).length + 1
        return (String(kind), NSRange(location: paragraph.location + (String(body.prefix(leading)) as NSString).length, length: length))
    }

    package static func color(_ kind: String) -> NSColor {
        switch kind.lowercased() {
        case "tip", "success", "check", "done": .systemGreen
        case "warning", "caution", "attention": .systemOrange
        case "danger", "error", "bug", "failure": .systemRed
        case "important", "example": .systemPurple
        case "question", "help", "faq": .systemTeal
        default: .systemBlue
        }
    }

    /// Styles a callout's opening row: its marker a label in its colour,
    /// the brackets hidden unless the caret is in it.
    package static func style(_ storage: NSTextStorage, paragraph: NSRange, caret: Int?, metrics: OutlineMetrics) {
        let text = storage.string as NSString
        guard let (kind, range) = marker(in: text, paragraph: paragraph) else {
            // A quote under a callout's opening row is in it too.
            if paragraph.location > 0, let color = storage.attribute(key, at: paragraph.location - 1, effectiveRange: nil) as? NSColor {
                storage.addAttribute(key, value: color, range: paragraph)
                storage.addAttribute(.foregroundColor, value: metrics.typography.ink.text, range: paragraph)
            }
            return
        }
        let color = self.color(kind)
        storage.addAttribute(key, value: color, range: paragraph)
        storage.addAttribute(.foregroundColor, value: metrics.typography.ink.text, range: paragraph)
        let inMarker = caret.map { $0 >= range.location && $0 <= NSMaxRange(range) } ?? false
        let word = NSRange(location: range.location + 2, length: range.length - 3)
        storage.addAttributes([.foregroundColor: color, .font: NSFont.systemFont(ofSize: round(metrics.fontSize * 0.78), weight: .bold),
                               .kern: 0.8], range: word)
        if !inMarker {
            storage.addAttribute(.outlineHidden, value: true, range: NSRange(location: range.location, length: 2))
            storage.addAttribute(.outlineHidden, value: true, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
            storage.addAttribute(.outlineUppercase, value: true, range: word)
        }
        // The rest of the line, its title, bold.
        let after = NSMaxRange(range)
        var end = NSMaxRange(paragraph) - (text.substring(with: paragraph).hasSuffix("\n") ? 1 : 0)
        // The first line alone: the callout's body follows on lines of its own.
        let lineEnd = text.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\u{2028}"), options: [],
                                            range: NSRange(location: after, length: max(0, end - after)))
        if lineEnd.location != NSNotFound { end = lineEnd.location }
        if end > after {
            storage.addAttribute(.font, value: NSFontManager.shared.convert(metrics.font(for: Row(kind: .quote, text: "")), toHaveTrait: .boldFontMask),
                                 range: NSRange(location: after, length: end - after))
        }
    }
}
