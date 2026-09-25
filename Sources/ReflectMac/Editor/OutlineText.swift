import AppKit
import ReflectCore

extension NSAttributedString.Key {
    /// The row a paragraph is, as a `RowStyle`. Every character of a
    /// paragraph, its line break included, carries the same one.
    static let outlineRow = NSAttributedString.Key("ReflectOutlineRow")
}

/// What a paragraph of the editor is: a row, less its text, which is the
/// paragraph's. Immutable, so that undo can put an old one back.
final class RowStyle: NSObject {
    let row: Row

    init(_ row: Row) {
        var row = row
        row.text = ""
        self.row = row
    }

    func with(_ change: (inout Row) -> Void) -> RowStyle {
        var row = row
        change(&row)
        return RowStyle(row)
    }
}

/// The editor's text is the outline's: one paragraph a row, each ending in a
/// line break — the last one too, so that every row has a character to carry
/// its style. Lines within a row are broken with U+2028.
enum OutlineText {
    static let lineSeparator = "\u{2028}"

    static func attributed(_ rows: [Row]) -> NSMutableAttributedString {
        let text = NSMutableAttributedString()
        for row in rows {
            let paragraph = row.text.replacingOccurrences(of: "\n", with: lineSeparator) + "\n"
            text.append(NSAttributedString(string: paragraph, attributes: [.outlineRow: RowStyle(row)]))
        }
        return text
    }

    /// The character range of each paragraph, its line break included.
    static func paragraphs(_ text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        let length = text.length
        while start < length {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: start, length: length - start))
            let end = found.location == NSNotFound ? length : found.location + 1
            ranges.append(NSRange(location: start, length: end - start))
            start = end
        }
        return ranges
    }

    static func style(_ text: NSAttributedString, at location: Int) -> RowStyle {
        guard text.length > 0 else { return RowStyle(.blank) }
        return text.attribute(.outlineRow, at: min(location, text.length - 1), effectiveRange: nil) as? RowStyle
            ?? RowStyle(.blank)
    }

    static func rows(_ text: NSAttributedString) -> [Row] {
        let string = text.string as NSString
        return paragraphs(string).map { range in
            var row = style(text, at: range.location).row
            var body = string.substring(with: range)
            if body.hasSuffix("\n") { body.removeLast() }
            row.text = body.replacingOccurrences(of: lineSeparator, with: "\n")
            return row
        }
    }
}
