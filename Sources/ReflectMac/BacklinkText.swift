import AppKit
import ReflectCore
import ReflectUI

/// A backlink's context, as a little outline to read: bullets, numbers,
/// checkboxes and headings as they are in the note, the Markdown inside
/// them shown as what it means, and the link to the note picked out.
enum BacklinkText {
    /// The most rows shown, and the most of a row's text: a long context
    /// is clamped, as Reflect clamps its panel, and says what is left.
    static let rowLimit = 10
    static let textLimit = 320

    static func attributed(_ context: BacklinkContext, size: CGFloat = NSFont.smallSystemFontSize + 1,
                           rowLimit: Int = BacklinkText.rowLimit) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: size)
        let linked = linkKey(context.link)
        let shown = Array(context.rows.prefix(rowLimit))
        for (index, var row) in shown.enumerated() {
            if row.text.count > textLimit { row.text = String(row.text.prefix(textLimit)) + "…" }
            let marker: String
            switch row.kind {
            case .bullet:
                switch row.task {
                case .open?: marker = "☐"
                case .done?: marker = "☑"
                case nil: marker = "•"
                }
            case .ordered: marker = "\(row.number)\(row.marker)"
            case .quote: marker = "│"
            default: marker = ""
            }
            let indent = CGFloat(row.depth) * 14
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent + (marker.isEmpty ? 0 : 14)
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent + 14)]
            paragraph.paragraphSpacing = 2
            paragraph.lineBreakMode = .byWordWrapping
            var base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            if case .heading = row.kind { base[.font] = NSFont.boldSystemFont(ofSize: size) }
            if row.kind == .quote || row.task.map({ if case .done = $0 { true } else { false } }) == true {
                base[.foregroundColor] = NSColor.secondaryLabelColor
            }
            if !marker.isEmpty {
                result.append(NSAttributedString(string: marker + "\t", attributes: base.merging([.foregroundColor: NSColor.tertiaryLabelColor]) { $1 }))
            }
            result.append(inline(row.text, base: base, linked: linked))
            if index < shown.count - 1 { result.append(NSAttributedString(string: "\n", attributes: base)) }
        }
        if context.rows.count > shown.count {
            let more = context.rows.count - shown.count
            result.append(NSAttributedString(string: "\n⋯ \(more) more \(more == 1 ? "line" : "lines")", attributes: [
                .font: NSFont.systemFont(ofSize: size - 1), .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return result
    }

    /// The key of the note a `[[link]]` names.
    private static func linkKey(_ link: String) -> String? {
        let text = link as NSString
        for span in InlineMarkup.spans(in: text, range: NSRange(location: 0, length: text.length)) {
            if case .wikiLink(let target) = span.kind { return NoteIndex.foldKey(target) }
        }
        return nil
    }

    /// A row's text with its Markdown shown as what it means.
    private static let hardBreak = try! NSRegularExpression(pattern: #"\\\n"#)
    private static let escape = try! NSRegularExpression(pattern: #"\\([\\`*_{}\[\]()#+\-.!|~>])"#)

    private static func inline(_ text: String, base: [NSAttributedString.Key: Any], linked: String?) -> NSAttributedString {
        // A `\` at a line's end is a line break; `\*` and its kind, the character.
        var plain = text.hasSuffix("\\") ? String(text.dropLast()) : text
        plain = hardBreak.stringByReplacingMatches(in: plain, range: NSRange(location: 0, length: (plain as NSString).length), withTemplate: "\n")
        plain = escape.stringByReplacingMatches(in: plain, range: NSRange(location: 0, length: (plain as NSString).length), withTemplate: "$1")
        let flat = plain.replacingOccurrences(of: "\n", with: "\u{2028}")
        let string = NSMutableAttributedString(string: flat, attributes: base)
        let ns = flat as NSString
        let font = base[.font] as? NSFont ?? .systemFont(ofSize: 12)
        let spans = InlineMarkup.spans(in: ns, range: NSRange(location: 0, length: ns.length))
        var hidden: [NSRange] = []
        for span in spans {
            switch span.kind {
            case .strong:
                string.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: font.pointSize), range: span.content)
            case .emphasis:
                string.addAttribute(.font, value: font.adding(.italic), range: span.content)
            case .strikethrough:
                string.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                      .foregroundColor: NSColor.secondaryLabelColor], range: span.content)
            case .code:
                string.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular), range: span.content)
            case .highlight:
                string.addAttribute(.backgroundColor, value: NSColor.highlighter, range: span.content)
            case .wikiLink(let target):
                let isTarget = NoteIndex.foldKey(target) == linked
                string.addAttributes([.foregroundColor: NSColor.linkColor,
                                      .font: isTarget ? NSFont.boldSystemFont(ofSize: font.pointSize) : font], range: span.content)
            case .link, .url:
                string.addAttribute(.foregroundColor, value: NSColor.linkColor, range: span.content)
            case .tag:
                string.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: span.range)
            case .image, .imageText, .comment:
                break
            }
            hidden.append(contentsOf: span.markup)
        }
        // Markup out, a picture a word for it — from the end, so what is
        // before each change stays where it was.
        var edits: [(range: NSRange, with: String)] = spans.filter(\.isImage).map { ($0.range, "▢ picture") }
        edits += hidden.filter { run in !spans.contains { $0.isImage && NSIntersectionRange($0.range, run).length > 0 } }.map { ($0, "") }
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            string.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.with, attributes:
                base.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 }))
        }
        return string
    }
}
