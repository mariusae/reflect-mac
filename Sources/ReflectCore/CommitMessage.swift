import Foundation

/// Commit messages in Reflect's words — `Update daily note for 2026-09-25`,
/// `Add Project X`, `Update 2 notes and 1 attachment` — by the rules of its
/// `commit_message.rs`, so a history written from both apps reads as one.
public enum CommitMessage {
    public enum Action: Equatable, Sendable {
        case add, update, delete, rename

        var verb: String {
            switch self {
            case .add: "Add"
            case .update: "Update"
            case .delete: "Delete"
            case .rename: "Rename"
            }
        }
    }

    /// One path the commit changes, as `git diff --name-status` tells it.
    public struct Change: Equatable, Sendable {
        public var action: Action
        public var path: String
        /// Where a renamed file was.
        public var oldPath: String?

        public init(action: Action, path: String, oldPath: String? = nil) {
            self.action = action
            self.path = path
            self.oldPath = oldPath
        }
    }

    /// The subject for a commit of `changes`, or `fallback` when they say
    /// nothing worth naming. `text` gives a file's text as committed (`old`
    /// false) or as it was before (`old` true), for a note's title.
    public static func describe(_ changes: [Change], fallback: String = "Update notes",
                                text: (_ path: String, _ old: Bool) -> String?) -> String {
        let content = changes.filter { $0.path != ".gitignore" && $0.path != ".gitattributes" }
        guard !content.isEmpty else { return fallback }
        let notes: [(action: Action, label: String, oldLabel: String?)] = content.compactMap { change in
            let label = change.action == .delete
                ? noteLabel(change.path, source: text(change.path, true))
                : noteLabel(change.path, source: text(change.path, false))
            guard let label else { return nil }
            let oldLabel = change.oldPath.flatMap { noteLabel($0, source: text($0, true)) }
            return (change.action, label, oldLabel)
        }
        let attachments = content.filter { isAttachment($0.path) }
        let others = content.count - notes.count - attachments.count

        if notes.count == content.count {
            if notes.count == 1, let note = notes.first {
                switch note.action {
                case .rename:
                    return limit(note.oldLabel.map { "Rename \($0) to \(note.label)" } ?? "Rename \(note.label)")
                default:
                    return limit("\(note.action.verb) \(note.label)")
                }
            }
            return limit("\(group(notes.map(\.action)).verb) \(count(notes.count, "note", "notes"))")
        }
        if attachments.count == content.count {
            return limit("\(group(attachments.map(\.action)).verb) \(count(attachments.count, "attachment", "attachments"))")
        }
        guard !notes.isEmpty else { return fallback }
        let verb = group(content.map(\.action)).verb
        if others == 0 {
            return limit("\(verb) \(count(notes.count, "note", "notes")) and \(count(attachments.count, "attachment", "attachments"))")
        }
        return limit("\(verb) \(count(notes.count, "note", "notes")) and \(count(content.count - notes.count, "file", "files"))")
    }

    /// What a note is called in a commit message: `daily note for …`, its
    /// title, `private note`, or its file name made readable.
    static func noteLabel(_ path: String, source: String?) -> String? {
        let fallback: String
        if let day = GraphPaths.day(fromDailyPath: path) {
            fallback = "daily note for \(day)"
        } else if path.hasPrefix("notes/"), path.hasSuffix(".md") {
            let stem = String(path.dropFirst(6).dropLast(3).split(separator: "/").last ?? "")
            let label = humanize(stem)
            guard !label.isEmpty else { return nil }
            fallback = label
        } else {
            return nil
        }
        guard let source else { return fallback }
        let (frontmatter, body) = splitFrontmatter(source)
        if let frontmatter, isPrivate(frontmatter) { return "private note" }
        if GraphPaths.day(fromDailyPath: path) != nil { return fallback }
        let title = frontmatter.flatMap { scalar($0, "title") }.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? firstH1(body)
        let collapsed = title.map(collapseSpaces) ?? ""
        return collapsed.isEmpty ? fallback : collapsed
    }

    private static func isAttachment(_ path: String) -> Bool {
        path.hasPrefix("assets/") || path.hasPrefix("audio-memos/")
    }

    /// All the same action is that action; a mixture is an update.
    private static func group(_ actions: [Action]) -> Action {
        guard let first = actions.first else { return .update }
        return actions.allSatisfy { $0 == first } ? first : .update
    }

    private static func count(_ count: Int, _ singular: String, _ plural: String) -> String {
        count == 1 ? "1 \(singular)" : "\(count) \(plural)"
    }

    private static func limit(_ subject: String) -> String {
        subject.count <= 72 ? subject : String(subject.prefix(69)) + "..."
    }

    private static func collapseSpaces(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `my-project_notes` → `My Project Notes`; left alone if it has capitals.
    static func humanize(_ stem: String) -> String {
        let spaced = String(stem.map { character -> Character in
            let control = character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .control }
            return character == "-" || character == "_" || control ? " " : character
        })
        let normalized = collapseSpaces(spaced)
        if normalized.contains(where: { $0.isUppercase }) { return normalized }
        return normalized.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: Frontmatter and headings, read as Reflect reads them here

    private static func fenceLength(_ text: Substring) -> Int? {
        guard text.hasPrefix("---") else { return nil }
        var index = text.index(text.startIndex, offsetBy: 3)
        var length = 3
        while index < text.endIndex, text[index] == " " || text[index] == "\t" {
            index = text.index(after: index)
            length += 1
        }
        if index == text.endIndex { return length }
        if text[index] == "\n" { return length + 1 }
        if text[index] == "\r\n" { return length + 2 }
        return nil
    }

    static func splitFrontmatter(_ source: String) -> (raw: String?, body: String) {
        let text = Substring(source)
        guard let open = fenceLength(text) else { return (nil, source) }
        let rest = text.dropFirst(open)
        if let close = fenceLength(rest) { return ("", String(rest.dropFirst(close))) }
        var lineStart = rest.startIndex
        while let newline = rest[lineStart...].firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
            let next = rest.index(after: newline)
            if let close = fenceLength(rest[next...]) {
                return (String(rest[rest.startIndex..<newline]), String(rest[next...].dropFirst(close)))
            }
            lineStart = next
        }
        return (nil, source)
    }

    private static func isPrivate(_ raw: String) -> Bool {
        guard let value = scalar(raw, "private") else { return false }
        return ["true", "yes", "on", "1"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private static func scalar(_ raw: String, _ key: String) -> String? {
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces) == key {
                return unquote(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, let quote = trimmed.first, quote == "\"" || quote == "'" {
            let inner = trimmed.dropFirst()
            if let end = inner.firstIndex(of: quote) {
                let trailing = inner[inner.index(after: end)...].drop(while: { $0 == " " || $0 == "\t" })
                if trailing.isEmpty || trailing.hasPrefix("#") { return String(inner[..<end]) }
            }
        }
        if let comment = trimmed.range(of: " #") { return String(trimmed[..<comment.lowerBound]) }
        return trimmed
    }

    static func firstH1(_ body: String) -> String? {
        // Lines as Rust's `lines()` gives them: no last empty one.
        var lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last?.isEmpty == true { lines.removeLast() }
        var inFence = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.drop(while: \.isWhitespace)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if trimmed.hasPrefix("#") {
                let rest = trimmed.dropFirst()
                if !rest.hasPrefix("#"), rest.isEmpty || rest.first == " " || rest.first == "\t" {
                    let heading = cleanHeading(rest)
                    if !heading.isEmpty { return heading }
                }
            }
            if index + 1 < lines.count {
                let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
                if !next.isEmpty, next.allSatisfy({ $0 == "=" }) {
                    let heading = cleanHeading(line)
                    if !heading.isEmpty { return heading }
                }
            }
        }
        return nil
    }

    private static func cleanHeading(_ raw: Substring) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
