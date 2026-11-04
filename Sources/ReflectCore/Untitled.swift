import Foundation

/// A page not yet given a title: jotted down, to be named later, if ever.
///
/// It is kept in `notes/untitled-<when>-<four letters>.md`, which names
/// it: its title — what links to it say, `[[untitled-2026-11-04-103122-7f3a]]`,
/// and what it is known by — is its file's name, and its file says no
/// title, not even in a heading. What it is shown as is its first line's
/// words, as they are now. Given a title, it goes to the file its title
/// names, and what linked to it is relinked; its title taken away, it is
/// untitled again, under a new name.
public enum Untitled {
    public static let prefix = "untitled-"

    /// Whether a title is an untitled page's name: `untitled-`, its
    /// date and time, and four letters to keep two devices' apart.
    public static func isName(_ title: String) -> Bool {
        let utf8 = title.utf8
        // untitled-YYYY-MM-DD-HHMMSS-xxxx
        guard utf8.count == prefix.utf8.count + 22, title.hasPrefix(prefix) else { return false }
        let rest = Array(utf8.dropFirst(prefix.utf8.count))
        func digits(_ range: Range<Int>) -> Bool { rest[range].allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }
        func dash(_ at: Int) -> Bool { rest[at] == 0x2D }
        return digits(0..<4) && dash(4) && digits(5..<7) && dash(7) && digits(8..<10) && dash(10) && digits(11..<17) && dash(17)
            && rest[18...].allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7A) }
    }

    /// Whether a graph-relative path is an untitled page's file.
    public static func isPath(_ path: String) -> Bool {
        let folder = GraphPaths.notesDirectory + "/"
        guard path.hasPrefix(folder), path.hasSuffix(".md") else { return false }
        return isName(String(path.dropFirst(folder.count).dropLast(3)))
    }

    /// A name for a page made now, untitled.
    public static func newName(at date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let letters = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let tail = String((0..<4).map { _ in letters.randomElement()! })
        return String(format: "%@%04d-%02d-%02d-%02d%02d%02d-%@", prefix, c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, tail)
    }

    /// When an untitled page was made, by its name.
    public static func date(of title: String) -> Date? {
        guard isName(title) else { return nil }
        let digits = title.dropFirst(prefix.count).filter(\.isNumber)
        let parts = [0..<4, 4..<6, 6..<8, 8..<10, 10..<12, 12..<14].map { range -> Int in
            Int(digits[digits.index(digits.startIndex, offsetBy: range.lowerBound)..<digits.index(digits.startIndex, offsetBy: range.upperBound)]) ?? 0
        }
        return Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .current, year: parts[0], month: parts[1], day: parts[2],
                                                                           hour: parts[3], minute: parts[4], second: parts[5]))
    }

    /// What a page says, as its name: the words of its first line that
    /// has any — a picture's, a rule's, a fence's lines passed over — as a
    /// title. Nil, when it says nothing yet.
    public static func name(of text: String) -> String? {
        var looked = 0
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            looked += 1
            if looked > 40 { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence || trimmed.isEmpty { continue }
            // A rule, or a picture alone: nothing to call it by.
            if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" || $0 == " " }) { continue }
            let words = title(from: String(trimmed))
            if !words.isEmpty { return words }
        }
        return nil
    }

    /// Words as a title: Markdown's marks out — a heading's, a list's, a
    /// task's, a quote's, emphasis, a picture, a link's address — on one
    /// line, cut at a word past sixty letters.
    public static func title(from words: String) -> String {
        var line = words.trimmingCharacters(in: .whitespacesAndNewlines)
        line = line.components(separatedBy: .newlines).first ?? line
        while line.hasPrefix("#") { line.removeFirst() }
        line = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- [ ] ", "- [x] ", "- [X] ", "+ [ ] ", "+ [x] ", "* [ ] ", "* [x] ", "- ", "* ", "+ ", "> "] where line.hasPrefix(marker) {
            line = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        // Pictures go; `[words](address)` is its words; `[[Title]]` and `[[Title|shown]]`, what they show.
        line = line.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"!\[\[[^\]]*\]\]"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        line = line.replacingOccurrences(of: #"\[\[([^\]|]*)\|([^\]]*)\]\]"#, with: "$2", options: .regularExpression)
        line = line.replacingOccurrences(of: #"\[\[([^\]|]*)\]\]"#, with: "$1", options: .regularExpression)
        for mark in ["**", "__", "`", "~~", "=="] { line = line.replacingOccurrences(of: mark, with: "") }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: " .,;").union(.whitespaces))
        guard line.count > 60 else { return line }
        let cut = line.prefix(60)
        return String(cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut).trimmingCharacters(in: .whitespaces)
    }
}
