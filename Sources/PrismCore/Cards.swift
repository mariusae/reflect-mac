import Foundation
import ReflectCore

/// How a note's card shows it, wherever notes are listed.
public enum CardMode: String, Codable, Sendable, CaseIterable {
    /// The whole note, to read and write in.
    case full
    /// Only some rows of it, under its name — what links somewhere, its
    /// tasks, what a search found.
    case view
    /// A short form: what it is about in a few lines, and its picture.
    case summary
    /// Its name and when alone.
    case collapsed

    public var name: String {
        switch self {
        case .full: "Full"
        case .view: "Excerpt"
        case .summary: "Summary"
        case .collapsed: "Collapsed"
        }
    }
}

/// What a card in summary shows of a note: a line that says what it is,
/// a little of what follows, and the first picture in it.
public struct NoteSummary: Equatable, Sendable {
    /// Its first heading or line — not the title its card is headed by.
    public var headline: String?
    /// The words after it, as they read.
    public var snippet: String
    /// The first picture's source, as its Markdown gives it — or its
    /// cover's, when it has one.
    public var picture: String?
    /// Whether the picture is its cover: shown larger, at the card's top.
    public var isCover: Bool

    public init(headline: String?, snippet: String, picture: String?, isCover: Bool = false) {
        self.headline = headline
        self.snippet = snippet
        self.picture = picture
        self.isCover = isCover
    }

    /// The summary of a note's source, its card headed by `title`.
    public static func of(_ source: String, title: String?, length: Int = 280) -> NoteSummary {
        let rows = Row.unfold(OutlineMarkdown.parse(source).rows)
        let cover = NoteCover.source(in: source)
        var picture = cover
        var lines: [String] = []
        for row in rows {
            if picture == nil, let found = firstPicture(in: row.text) { picture = found }
            guard row.kind != .rule, row.kind != .code else { continue }
            let text = InlineMarkup.plainText(row.text).replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // The note's name, heading it: its card says it already.
            if lines.isEmpty, let title, text.caseInsensitiveCompare(title) == .orderedSame { continue }
            lines.append(text)
            if lines.joined(separator: " ").count > length * 2, picture != nil { break }
        }
        let headline = lines.first
        var snippet = lines.dropFirst().joined(separator: " · ")
        if snippet.count > length { snippet = String(snippet.prefix(length)).trimmingCharacters(in: .whitespaces) + "…" }
        return NoteSummary(headline: headline, snippet: snippet, picture: picture, isCover: cover != nil)
    }

    private static let image = try! NSRegularExpression(pattern: #"!\[[^\[\]\n]*\]\(([^)\s]+)\)"#)

    private static func firstPicture(in text: String) -> String? {
        let ns = text as NSString
        guard let match = image.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}

/// How each note's card was last asked to show it, kept across launches:
/// a note collapsed, or summarized, stays so wherever it is listed.
public enum CardModes {
    private static let key = "CardModes"
    nonisolated(unsafe) private static var modes: [String: CardMode] = {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: CardMode].self, from: data) else { return [:] }
        return decoded
    }()
    private static let lock = NSLock()
    /// Whether a mode set is kept: not for a scripted check's.
    nonisolated(unsafe) public static var persists = true

    /// A note's mode, or what the place it is listed in shows by default.
    public static func mode(_ path: String, default fallback: CardMode = .full) -> CardMode {
        lock.lock()
        defer { lock.unlock() }
        return modes[path] ?? fallback
    }

    /// Sets a note's mode; full — the usual — is not kept.
    public static func set(_ mode: CardMode?, for path: String) {
        lock.lock()
        modes[path] = mode == .full ? nil : mode
        let data = try? JSONEncoder().encode(modes)
        lock.unlock()
        if persists, let data { UserDefaults.standard.set(data, forKey: key) }
        NotificationCenter.default.post(name: changed, object: path)
    }

    /// Posted with a note's path when its mode changes.
    public static let changed = Notification.Name("CardModesChanged")
}
