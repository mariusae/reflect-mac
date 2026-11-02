import Foundation

/// Notes related without a link in their text: frontmatter `related:`, a
/// list of the other notes' names, as Prism and Weft both write and read
/// it. A relation goes both ways — written in one note, it is shown in
/// both — and is taken away from whichever note has it written.
///
/// ```
/// related:
///   - The Commanding Heights
///   - "Planning: a primer"
/// ```
public enum Related {
    public static let key = "related"

    /// The names in a note's frontmatter, each once, as written — a
    /// `[[link]]` read as the name in it.
    public static func names(in frontmatter: Frontmatter) -> [String] {
        var seen = Set<String>()
        return frontmatter.list(key).map(clean).filter { !$0.isEmpty && seen.insert(NoteIndex.foldKey($0)).inserted }
    }

    public static func names(in source: String) -> [String] { names(in: Frontmatter(of: source)) }

    /// `[[Title|shown]]` read as `Title`; a plain name as it is.
    public static func clean(_ name: String) -> String {
        var name = name.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("[["), name.hasSuffix("]]") { name = String(name.dropFirst(2).dropLast(2)) }
        if let bar = name.firstIndex(of: "|") { name = String(name[..<bar]) }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// A note's text related to one more note — after those it has.
    public static func adding(_ name: String, to source: String) -> String {
        let name = clean(name)
        var names = names(in: source)
        guard !name.isEmpty, !names.contains(where: { NoteIndex.foldKey($0) == NoteIndex.foldKey(name) }) else { return source }
        names.append(name)
        return setting(names, in: source)
    }

    /// A note's text related no longer to the names given — any it has
    /// written that match one, regardless of case.
    public static func removing(_ removed: [String], from source: String) -> String {
        let keys = Set(removed.map { NoteIndex.foldKey(clean($0)) })
        let names = names(in: source)
        let kept = names.filter { !keys.contains(NoteIndex.foldKey($0)) }
        return kept.count == names.count ? source : setting(kept, in: source)
    }

    /// A note's text with its relations these: an item a line, so that git
    /// merges two devices' additions; none, and the key goes.
    public static func setting(_ names: [String], in source: String) -> String {
        guard !names.isEmpty else { return Frontmatter.setting(key, to: nil, in: source) }
        return Frontmatter.setting(key, to: "\n" + names.map { "  - " + item($0) }.joined(separator: "\n"), in: source)
            .replacingOccurrences(of: "\(key): \n", with: "\(key):\n")
    }

    /// A name as a list item: plain where it reads back as itself, else quoted.
    static func item(_ name: String) -> String {
        guard let first = name.first, let last = name.last, !first.isWhitespace, !last.isWhitespace,
              !"-?:,[]{}#&*!|>'\"%@`".contains(first), !name.contains(": "), !name.contains(" #"), last != ":",
              !["null", "~", "true", "false", "yes", "no"].contains(name.lowercased()) else {
            return "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return name
    }
}

/// A note related to another, as one of them shows it.
public struct RelatedNote: Equatable, Sendable {
    /// Its name, as the relation names it, or its title.
    public var name: String
    /// Its file, when a note answers to the name; nil for one not yet written.
    public var path: String?
    /// Whether the relation is written in the note showing it — else in
    /// this one, the other way.
    public var isOwn: Bool

    public init(name: String, path: String?, isOwn: Bool) {
        self.name = name
        self.path = path
        self.isOwn = isOwn
    }
}

extension NoteIndex {
    /// A note's relations, both ways: those it names, in its order, then
    /// the notes naming it, by title. Each note once.
    public func related(to path: String) -> [RelatedNote] {
        guard let entry = entry(path) else { return [] }
        var found: [RelatedNote] = []
        var seen = Set<String>([path])
        for name in entry.related {
            let target = resolve(name)
            if let target { guard seen.insert(target).inserted else { continue } }
            found.append(RelatedNote(name: target.flatMap { self.entry($0)?.title } ?? name, path: target, isOwn: true))
        }
        // The names it answers to: a name of another's relation names it.
        let keys = Set(([entry.title] + entry.aliases + (entry.day.map { [$0.description] } ?? [])).map(NoteIndex.foldKey))
        let others = all.filter { !$0.related.isEmpty && !seen.contains($0.path) && $0.related.contains { keys.contains(NoteIndex.foldKey($0)) } }
        for other in others.sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) {
            found.append(RelatedNote(name: other.title, path: other.path, isOwn: false))
        }
        return found
    }
}
