import Foundation

/// A note named in another's words without a link to it: found, and made
/// a link — its title, or another name it goes by, as whole words, outside
/// links and code.
public enum Mentions {
    /// Where the names are in a row's words, as whole words, case aside —
    /// not in a link, a code span, a picture, a tag.
    public static func ranges(of names: [String], in text: String) -> [NSRange] {
        let string = text as NSString
        let skipped = InlineMarkup.spans(in: string, range: NSRange(location: 0, length: string.length)).filter { span in
            switch span.kind {
            case .link, .wikiLink, .url, .code, .image, .imageText, .comment, .tag: true
            default: false
            }
        }.map(\.range)
        var found: [NSRange] = []
        for name in names.sorted(by: { $0.count > $1.count }) where name.count >= 3 {
            var start = 0
            while start < string.length {
                let range = string.range(of: name, options: [.caseInsensitive, .diacriticInsensitive],
                                         range: NSRange(location: start, length: string.length - start))
                guard range.location != NSNotFound else { break }
                start = NSMaxRange(range)
                guard isWordEdge(string, before: range.location), isWordEdge(string, after: NSMaxRange(range)),
                      !skipped.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                      !found.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                found.append(range)
            }
        }
        return found.sorted { $0.location < $1.location }
    }

    /// Whether a note's text names one of `names` without a link.
    public static func mentions(_ names: [String], in source: String) -> Bool {
        OutlineMarkdown.parse(source).rows.contains { !ranges(of: names, in: $0.text).isEmpty }
    }

    /// A note's text with every mention of the names made a link to
    /// `title`: `[[Title]]` where the words are its title, else
    /// `[[Title|the words]]`. Nil, with none.
    public static func linking(_ names: [String], to title: String, in source: String) -> String? {
        var outline = OutlineMarkdown.parse(source)
        var changed = false
        for i in outline.rows.indices {
            let text = outline.rows[i].text as NSString
            let ranges = ranges(of: names, in: outline.rows[i].text)
            guard !ranges.isEmpty else { continue }
            let linked = NSMutableString(string: text)
            for range in ranges.reversed() {
                let words = text.substring(with: range)
                let link = words == title ? "[[\(title)]]" : "[[\(title)|\(words)]]"
                linked.replaceCharacters(in: range, with: link)
            }
            outline.rows[i].text = linked as String
            changed = true
        }
        return changed ? OutlineMarkdown.serialize(outline) : nil
    }

    private static func isWordEdge(_ text: NSString, before location: Int) -> Bool {
        location == 0 || !isWordCharacter(text.character(at: location - 1))
    }

    private static func isWordEdge(_ text: NSString, after location: Int) -> Bool {
        location >= text.length || !isWordCharacter(text.character(at: location))
    }

    private static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}

extension NoteIndex {
    /// The notes that name a note without linking it — by its title or
    /// another name it goes by — most lately changed first.
    public func mentions(of path: String, limit: Int = 20) -> [String] {
        guard let entry = entry(path), entry.day == nil else { return [] }
        let names = ([entry.title] + entry.aliases).filter { $0.count >= 3 }
        guard !names.isEmpty else { return [] }
        var found: Set<String> = []
        for name in names {
            for hit in containing(name, limit: 200) where hit.path != path && !found.contains(hit.path) {
                found.insert(hit.path)
            }
        }
        return found.compactMap { candidate -> (String, Date)? in
            guard let body = body(candidate), Mentions.mentions(names, in: body) else { return nil }
            return (candidate, self.entry(candidate)?.modified ?? .distantPast)
        }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
