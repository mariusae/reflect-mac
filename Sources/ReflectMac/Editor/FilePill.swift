import AppKit
import ReflectCore

/// A file in the graph linked from a note — `[name](assets/…)` — shown as
/// Reflect shows it: a pill, with the file's icon before its name and its
/// size after. The text stays the link it is; the icon and the size are
/// drawn in the room its hidden `[` and `]` are given.
final class FilePill: NSObject {
    let source: String
    let icon: NSImage
    let size: String

    init(source: String, icon: NSImage, size: String) {
        self.source = source
        self.icon = icon
        self.size = size
    }

    /// A symbol for a kind of file, by the kinds Reflect tells apart.
    static func symbol(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": "doc.richtext"
        case "zip", "tar", "gz", "tgz", "rar", "7z": "doc.zipper"
        case "doc", "docx", "pages": "doc.text"
        case "xls", "xlsx", "csv", "numbers": "tablecells"
        case "ppt", "pptx", "key": "rectangle.on.rectangle"
        case "mp3", "wav", "m4a", "flac", "ogg": "waveform"
        case "mp4", "mov", "mkv", "webm": "film"
        case "txt", "md": "doc.plaintext"
        default: "doc"
        }
    }

    static let iconSide: CGFloat = 15
    static let padding: CGFloat = 5

    /// The room before the name: the icon, and space either side of it.
    static var leadWidth: CGFloat { padding + iconSide + 4 }

    static func sizeFont(for font: NSFont) -> NSFont {
        .monospacedDigitSystemFont(ofSize: round(font.pointSize * 0.78), weight: .regular)
    }

    /// The room after the name: the size, and space either side of it.
    func tailWidth(for font: NSFont) -> CGFloat {
        let width = (size as NSString).size(withAttributes: [.font: Self.sizeFont(for: font)]).width
        return 6 + ceil(width) + Self.padding
    }
}

extension NSAttributedString.Key {
    /// Over a file link's Markdown: the `FilePill` it is shown as.
    static let outlineFile = NSAttributedString.Key("ReflectOutlineFile")
    /// On the hidden character laid out as room for the pill's icon, or its size.
    static let outlineFileLead = NSAttributedString.Key("ReflectOutlineFileLead")
    static let outlineFileTail = NSAttributedString.Key("ReflectOutlineFileTail")
}

extension ImageStore {
    /// The pill for a file in the graph, when a source names one that is there.
    func filePill(_ source: String) -> FilePill? {
        if let known = pills[source] { return known }
        guard let file = graphFile(source) else { return nil }
        let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let symbol = FilePill.symbol(forExtension: file.pathExtension)
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular).applying(.init(hierarchicalColor: .secondaryLabelColor)))
            ?? NSWorkspace.shared.icon(forFile: file.path)
        let pill = FilePill(source: source, icon: icon,
                            size: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        pills[source] = pill
        return pill
    }
}

extension OutlineLayoutManager {
    /// Draws the pills of the file links in some characters.
    func drawFilePills(in characters: NSRange, origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first, characters.length > 0 else { return }
        storage.enumerateAttribute(.outlineFile, in: characters) { value, range, _ in
            guard let pill = value as? FilePill else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 15)
            var rects: [NSRect] = []
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in rects.append(rect) }
            // Each line's piece of the pill, around the text on that line.
            let ascent = ceil(font.ascender), descent = ceil(-font.descender)
            var pieces: [NSRect] = []
            for rect in rects {
                let glyph = glyphIndex(for: NSPoint(x: rect.minX + 1, y: rect.midY), in: container)
                let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let baseline = line.minY + location(forGlyphAt: glyph).y
                pieces.append(NSRect(x: rect.minX + origin.x, y: baseline - ascent - 3 + origin.y,
                                     width: rect.width, height: ascent + descent + 6))
            }
            NSColor.quaternaryLabelColor.withAlphaComponent(0.2).setFill()
            for piece in pieces { NSBezierPath(roundedRect: piece, xRadius: 6, yRadius: 6).fill() }
            guard let first = pieces.first, let last = pieces.last else { return }
            let side = FilePill.iconSide
            pill.icon.draw(in: NSRect(x: first.minX + FilePill.padding, y: first.midY - side / 2, width: side, height: side),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let attributes: [NSAttributedString.Key: Any] = [.font: FilePill.sizeFont(for: font), .foregroundColor: NSColor.secondaryLabelColor]
            let size = (pill.size as NSString).size(withAttributes: attributes)
            (pill.size as NSString).draw(at: NSPoint(x: last.maxX - FilePill.padding - size.width, y: last.midY - size.height / 2),
                                         withAttributes: attributes)
        }
    }
}
