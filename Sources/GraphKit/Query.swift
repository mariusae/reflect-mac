import Foundation
import ReflectCore

/// Which pages, and how to show them: what TiddlyWiki says with a filter
/// and a list widget, said as a form — and written in a page as a
/// ```` ```query ```` block, a line for each condition:
///
/// ```
/// tag: Filter Operators
/// not tag: Deprecated
/// sort: -modified
/// limit: 10
/// show: table
/// columns: caption, op-purpose
/// ```
///
/// `{this}` stands for the page the query is in: `tag: {this}` is what
/// is tagged with it.
public struct Query: Equatable, Sendable {
    /// Tagged with every one of these.
    public var tags: [String] = []
    /// Tagged with any one of these, when there are any.
    public var anyTags: [String] = []
    /// Pages tagged with these come first, and those with these last — as
    /// a podcast app's playlist puts its high- and low-priority podcasts —
    /// each tag after the one before it, or all as one, as `priorityMode` says.
    public var highPriority: [String] = []
    public var lowPriority: [String] = []
    public var priorityMode: PriorityMode = .ranked
    /// Tagged with none of these.
    public var excludedTags: [String] = []
    /// Words in the title, and in the body.
    public var titleContains = ""
    public var textContains = ""
    /// Pages linking to this one, and those this one links to — a page
    /// related to another, in its frontmatter's `related:`, as linking to it.
    public var linksTo = ""
    public var linkedFrom = ""
    /// The titles in this page's `list` field, in their order.
    public var listedIn = ""
    /// Having each of these fields.
    public var hasFields: [String] = []
    /// Edited since the start of the day this many days ago, by the
    /// calendar: 0 today, 1 since yesterday — written `edited since: today`,
    /// `edited since: yesterday`, `edited since: 3 days ago`.
    public var editedSinceDaysAgo: Int?
    /// Wiki pages, or the rest; nil for both.
    public var wiki: Bool?
    /// What each page is, as Prism flags notes: `is: inbox`, `is: pinned`.
    public var flags: [Flag] = []
    /// What none of them is: `is not: inbox, todo`.
    public var excludedFlags: [Flag] = []
    public var sort: Sort = .automatic
    public var descending = false
    public var limit: Int?
    public var show: Display = .list
    /// The fields a table shows beside the title.
    public var columns: [String] = []
    /// Lines weft did not understand, kept so that they are written back.
    public var unknown: [String] = []

    public init() {}

    public enum PriorityMode: String, CaseIterable, Sendable {
        /// Each priority tag ahead of the ones after it.
        case ranked
        /// High priority, then the rest, then low — no further ranked.
        case grouped
    }

    public enum Sort: String, CaseIterable, Sendable {
        /// In the order the source gives — a tag's or a list's — else by title.
        case automatic, title, created, modified
        /// Pinned notes' order: numbered ones by number, then by title.
        case pinned
    }

    /// A flag a page has, or a kind it is.
    public enum Flag: String, CaseIterable, Sendable {
        case inbox, pinned, topic, template, wiki, day, week, note
        /// A page that is itself a thing to do, still to do; one done.
        case todo, done

        /// What it says of a page, in a query's summary.
        var phrase: String {
            switch self {
            case .inbox: "in the inbox"
            case .pinned: "pinned"
            case .topic: "topics"
            case .template: "templates"
            case .wiki: "wiki pages"
            case .day: "days"
            case .week: "weeks"
            case .note: "notes"
            case .todo: "still to do"
            case .done: "done"
            }
        }

        func holds(for entry: PageIndex.Entry) -> Bool {
            switch self {
            case .inbox: entry.note.isInInbox
            case .pinned: entry.note.pin != nil
            case .topic: entry.note.isTopic
            case .template: entry.note.isTemplate
            case .wiki: entry.page.isWiki
            case .day: if case .day = entry.kind { true } else { false }
            case .week: if case .week = entry.kind { true } else { false }
            case .note: entry.kind == .note
            case .todo: entry.page.taskState == .todo
            case .done: entry.page.taskState == .done
            }
        }
    }

    public enum Display: String, CaseIterable, Sendable {
        case list, inline, table, cards, count, tree
    }

    public static let this = "{this}"

    // MARK: Text

    public init(text: String) {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else {
                unknown.append(line)
                continue
            }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "tag": tags.append(value)
            case "any tag": anyTags += Self.items(value)
            case "high priority": highPriority += Self.items(value)
            case "low priority": lowPriority += Self.items(value)
            case "priority": priorityMode = PriorityMode(rawValue: value.lowercased()) ?? .ranked
            case "not tag": excludedTags.append(value)
            case "title": titleContains = value
            case "text": textContains = value
            case "links to": linksTo = value
            case "linked from": linkedFrom = value
            case "listed in": listedIn = value
            case "has": hasFields += Self.items(value)
            case "edited since", "edited":
                if let days = Self.daysAgo(value) { editedSinceDaysAgo = days } else { unknown.append(line) }
            case "wiki": wiki = FieldSpec.flag(value)
            case "is":
                let named = Self.items(value).map { Flag(rawValue: $0.lowercased()) }
                if named.contains(nil) { unknown.append(line) } else { flags += named.compactMap { $0 } }
            case "is not":
                let named = Self.items(value).map { Flag(rawValue: $0.lowercased()) }
                if named.contains(nil) { unknown.append(line) } else { excludedFlags += named.compactMap { $0 } }
            case "sort":
                descending = value.hasPrefix("-")
                sort = Sort(rawValue: value.trimmingCharacters(in: CharacterSet(charactersIn: "-+ ")).lowercased()) ?? .automatic
            case "limit": limit = Int(value)
            case "show": show = Display(rawValue: value.lowercased()) ?? .list
            case "columns": columns = Self.items(value)
            default: unknown.append(line)
            }
        }
    }

    /// How many days back a day is: `today`, `yesterday`, `3 days ago`,
    /// `2 weeks ago`, `3`.
    static func daysAgo(_ value: String) -> Int? {
        let said = value.lowercased().trimmingCharacters(in: .whitespaces)
        switch said {
        case "today": return 0
        case "yesterday": return 1
        default: break
        }
        var words = said.split(separator: " ").map(String.init)
        if words.last == "ago" { words.removeLast() }
        guard let first = words.first else { return nil }
        let number = first == "a" || first == "an" || first == "one" ? 1 : Int(first)
        guard let number, number >= 0 else { return nil }
        switch words.dropFirst().first {
        case nil, "day", "days": return number
        case "week", "weeks": return number * 7
        default: return nil
        }
    }

    /// A day this many back, as a query says it.
    public static func daysAgoPhrase(_ days: Int) -> String {
        switch days {
        case 0: "today"
        case 1: "yesterday"
        default: "\(days) days ago"
        }
    }

    /// When the day this many back began, by the calendar.
    static func start(ofDaysAgo days: Int, from now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -days, to: today) ?? today
    }

    private static func items(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The query as a block's lines, in weft's order.
    public var text: String {
        var lines: [String] = []
        lines += tags.map { "tag: \($0)" }
        if !anyTags.isEmpty { lines.append("any tag: \(anyTags.joined(separator: ", "))") }
        lines += excludedTags.map { "not tag: \($0)" }
        if !titleContains.isEmpty { lines.append("title: \(titleContains)") }
        if !textContains.isEmpty { lines.append("text: \(textContains)") }
        if !linksTo.isEmpty { lines.append("links to: \(linksTo)") }
        if !linkedFrom.isEmpty { lines.append("linked from: \(linkedFrom)") }
        if !listedIn.isEmpty { lines.append("listed in: \(listedIn)") }
        if !hasFields.isEmpty { lines.append("has: \(hasFields.joined(separator: ", "))") }
        if let editedSinceDaysAgo { lines.append("edited since: \(Self.daysAgoPhrase(editedSinceDaysAgo))") }
        if let wiki { lines.append("wiki: \(wiki ? "yes" : "no")") }
        if !flags.isEmpty { lines.append("is: \(flags.map(\.rawValue).joined(separator: ", "))") }
        if !excludedFlags.isEmpty { lines.append("is not: \(excludedFlags.map(\.rawValue).joined(separator: ", "))") }
        if sort != .automatic || descending { lines.append("sort: \(descending ? "-" : "")\(sort.rawValue)") }
        if !highPriority.isEmpty { lines.append("high priority: \(highPriority.joined(separator: ", "))") }
        if !lowPriority.isEmpty { lines.append("low priority: \(lowPriority.joined(separator: ", "))") }
        if priorityMode != .ranked { lines.append("priority: \(priorityMode.rawValue)") }
        if let limit { lines.append("limit: \(limit)") }
        if show != .list { lines.append("show: \(show.rawValue)") }
        if !columns.isEmpty { lines.append("columns: \(columns.joined(separator: ", "))") }
        lines += unknown
        return lines.joined(separator: "\n")
    }

    /// The query as a fenced block, to put in a page.
    public var block: String { "```query\n\(text)\n```" }

    /// What the query asks, in a few words: "Tagged Filters, by title".
    public var summary: String {
        var parts: [String] = []
        if !listedIn.isEmpty { parts.append("Listed in \(listedIn)") }
        if !tags.isEmpty { parts.append("Tagged \(tags.joined(separator: " and "))") }
        if !anyTags.isEmpty { parts.append("Tagged \(anyTags.joined(separator: " or "))") }
        if !excludedTags.isEmpty { parts.append("not \(excludedTags.joined(separator: " or "))") }
        if !linksTo.isEmpty { parts.append("Linking to \(linksTo)") }
        if !linkedFrom.isEmpty { parts.append("Linked from \(linkedFrom)") }
        if !titleContains.isEmpty { parts.append("titled “\(titleContains)”") }
        if !textContains.isEmpty { parts.append("mentioning “\(textContains)”") }
        if !hasFields.isEmpty { parts.append("with \(hasFields.joined(separator: ", "))") }
        if let editedSinceDaysAgo { parts.append(editedSinceDaysAgo == 0 ? "edited today" : "edited since \(Self.daysAgoPhrase(editedSinceDaysAgo))") }
        if let wiki { parts.append(wiki ? "in the wiki" : "outside the wiki") }
        if !flags.isEmpty { parts.append(flags.map(\.phrase).joined(separator: " and ")) }
        if !excludedFlags.isEmpty { parts.append("not " + excludedFlags.map(\.phrase).joined(separator: " or ")) }
        if parts.isEmpty { parts.append("Every page") }
        if sort != .automatic { parts.append("by \(sort.rawValue)\(descending ? ", newest first" : "")") }
        if let limit { parts.append("first \(limit)") }
        let said = parts.joined(separator: ", ").replacingOccurrences(of: Self.this, with: "this page")
        return said.prefix(1).uppercased() + said.dropFirst()
    }

    // MARK: Asking

    /// The pages the query finds in a wiki, in order. `this` is the
    /// page it is asked from.
    public func run(in index: PageIndex, this: String) -> [String] {
        let found = matched(in: index, this: this)
        var titles = found.titles
        sortTitles(&titles, ordered: found.ordered, in: index)
        if let limit { titles = Array(titles.prefix(max(0, limit))) }
        return titles
    }

    /// The pages the query finds, in the order their source gives — a
    /// tag's, a list's — or none in particular.
    func matching(in index: PageIndex, this: String) -> [String] {
        matched(in: index, this: this).titles
    }

    private func matched(in index: PageIndex, this: String) -> (titles: [String], ordered: Bool) {
        func resolve(_ value: String) -> String { value == Self.this ? this : value }
        let tags = tags.map(resolve), excludedTags = excludedTags.map(resolve)
        let ordered: Bool
        var titles: [String]
        let saying = TextQuery(textContains)
        if !saying.isEmpty {
            // What pages say, best first: the order the rest keep.
            titles = index.textMatches(saying)
            ordered = true
        } else if !listedIn.isEmpty {
            titles = (index[resolve(listedIn)]?[field: "list"]?.list ?? []).filter { index[$0] != nil }
            ordered = true
        } else if let first = tags.first {
            titles = index.tagged(first)
            ordered = true
        } else if !anyTags.isEmpty {
            var seen = Set<String>()
            titles = anyTags.map(resolve).flatMap(index.tagged).filter { seen.insert($0).inserted }
            ordered = false
        } else if !linksTo.isEmpty {
            titles = Self.linking(to: resolve(linksTo), in: index).sorted()
            ordered = false
        } else if !linkedFrom.isEmpty {
            titles = Self.linked(from: resolve(linkedFrom), in: index).sorted()
            ordered = false
        } else {
            titles = index.titles
            ordered = false
        }
        let linkingTo = linksTo.isEmpty ? nil : Self.linking(to: resolve(linksTo), in: index)
        let linkedFromSet = linkedFrom.isEmpty ? nil : Self.linked(from: resolve(linkedFrom), in: index)
        // Edited since the start of that day.
        let editedSince = editedSinceDaysAgo.map { Self.start(ofDaysAgo: $0) }
        titles = titles.filter { title in
            guard let page = index[title] else { return false }
            let own = Set(index.tags(of: title).map { $0.lowercased() })
            if !tags.allSatisfy({ own.contains($0.lowercased()) }) { return false }
            if !anyTags.isEmpty, !anyTags.contains(where: { own.contains(resolve($0).lowercased()) }) { return false }
            if excludedTags.contains(where: { own.contains($0.lowercased()) }) { return false }
            if let wanted = self.wiki, page.isWiki != wanted { return false }
            if !flags.isEmpty, let entry = index.entries[title], !flags.allSatisfy({ $0.holds(for: entry) }) { return false }
            if !excludedFlags.isEmpty, let entry = index.entries[title], excludedFlags.contains(where: { $0.holds(for: entry) }) { return false }
            if !titleContains.isEmpty, title.range(of: titleContains, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return false
            }
            if let linkingTo, !linkingTo.contains(title) { return false }
            if let linkedFromSet, !linkedFromSet.contains(title) { return false }
            if !hasFields.allSatisfy({ field in Self.has(page, field) }) { return false }
            if let editedSince, (index.entries[title]?.modified ?? .distantPast) < editedSince { return false }
            return true
        }
        return (titles, ordered)
    }

    /// Titles in the order the query sorts them by.
    private func sortTitles(_ titles: inout [String], ordered: Bool, in index: PageIndex) {
        switch sort {
        case .automatic:
            if !ordered { titles.sort { $0.localizedStandardCompare($1) == .orderedAscending } }
        case .title:
            titles.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        case .created, .modified:
            func date(_ title: String) -> Date {
                let entry = index.entries[title]
                return (sort == .created ? entry?.page.created : entry?.modified) ?? .distantPast
            }
            titles.sort { date($0) < date($1) }
        case .pinned:
            func pin(_ title: String) -> NoteEntry.Pin? { index.entries[title]?.note.pin }
            titles.sort { a, b in
                switch (pin(a), pin(b)) {
                case let (x?, y?) where x != y: return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.localizedStandardCompare(b) == .orderedAscending
                }
            }
        }
        if descending { titles.reverse() }
    }

    /// The pages related to a page either way: those it names in its
    /// `related:`, and those naming it in theirs.
    private static func related(to name: String, in index: PageIndex) -> Set<String> {
        guard let title = index.title(for: name) else { return [] }
        var found = Set(index.relating(to: title))
        for other in index.entries[title]?.note.related ?? [] {
            if let other = index.title(for: other), index[other] != nil { found.insert(other) }
        }
        found.remove(title)
        return found
    }

    /// The pages linking to a page, or related to it.
    static func linking(to name: String, in index: PageIndex) -> Set<String> {
        let title = index.title(for: name) ?? name
        return Set(index.backlinks(to: title)).union(related(to: name, in: index))
    }

    /// The pages a page links to, or is related to.
    static func linked(from name: String, in index: PageIndex) -> Set<String> {
        let title = index.title(for: name) ?? name
        return index.links(from: title).filter { index[$0] != nil }.union(related(to: name, in: index))
    }

    private static func has(_ page: Page, _ field: String) -> Bool {
        switch field {
        case "tags": !page.tags.isEmpty
        case "text": !page.text.isEmpty
        case "created": page.created != nil
        case "modified": page.modified != nil
        default:
            switch page[field: field] {
            case .text(let text): !text.isEmpty
            case .list(let list): !list.isEmpty
            case nil: false
            }
        }
    }
}

extension MarkdownBlock {
    /// A page's text with its `index`th query block — counting from 0 —
    /// holding `query` instead.
    public static func replacingQuery(at index: Int, in text: String, with query: Query) -> String {
        var lines = text.components(separatedBy: "\n")
        var seen = 0
        var line = 0
        while line < lines.count {
            let ticks = lines[line].prefix { $0 == "`" }
            if ticks.count >= 3 {
                let language = lines[line].dropFirst(ticks.count).trimmingCharacters(in: .whitespaces)
                var end = line + 1
                while end < lines.count, !(lines[end].hasPrefix(ticks) && lines[end].allSatisfy { $0 == "`" || $0 == " " }) { end += 1 }
                if language == "query" {
                    if seen == index {
                        lines.replaceSubrange((line + 1)..<min(end, lines.count), with: query.text.components(separatedBy: "\n"))
                        return lines.joined(separator: "\n")
                    }
                    seen += 1
                }
                line = end + 1
                continue
            }
            line += 1
        }
        return text
    }
}

extension Query {
    /// A query as a search is typed: its words — `"phrases"`, `-left out` —
    /// what its pages are to say; and among them `#tag` and `-#tag`, `is:todo`
    /// and `-is:done`, `title:word`, and `edited:today`, `edited:yesterday`,
    /// `edited:3` — since that many days ago.
    public init(search: String) {
        self.init()
        var words: [String] = []
        var rest = Substring(search)
        while let start = rest.firstIndex(where: { !$0.isWhitespace }) {
            rest = rest[start...]
            // A phrase, as typed: kept whole, quotes and all.
            let quoted = rest.first == "\"" || rest.hasPrefix("-\"")
            let end: Substring.Index
            if quoted {
                let open = rest.firstIndex(of: "\"")!
                end = rest[rest.index(after: open)...].firstIndex(of: "\"").map { rest.index(after: $0) } ?? rest.endIndex
            } else {
                end = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
            }
            let token = String(rest[..<end])
            rest = rest[end...]
            if quoted || !take(token) { words.append(token) }
        }
        textContains = words.joined(separator: " ") + (search.last?.isWhitespace == true && !words.isEmpty ? " " : "")
    }

    /// An operator taken into the query; false when the token is words.
    private mutating func take(_ token: String) -> Bool {
        let negated = token.hasPrefix("-")
        let bare = negated ? String(token.dropFirst()) : token
        if bare.hasPrefix("#"), bare.count > 1 {
            if negated { excludedTags.append(String(bare.dropFirst())) } else { tags.append(String(bare.dropFirst())) }
            return true
        }
        guard let colon = bare.firstIndex(of: ":"), colon != bare.startIndex else { return false }
        let key = bare[..<colon].lowercased(), value = String(bare[bare.index(after: colon)...])
        guard !value.isEmpty else { return false }
        switch key {
        case "is":
            guard let flag = Flag(rawValue: value.lowercased()) else { return false }
            if negated { excludedFlags.append(flag) } else { flags.append(flag) }
        case "tag":
            if negated { excludedTags.append(value) } else { tags.append(value) }
        case "title" where !negated:
            titleContains = value
        case "edited" where !negated:
            guard let days = Int(value).map({ max(0, $0) }) ?? Self.daysAgo(value) else { return false }
            editedSinceDaysAgo = days
        default:
            return false
        }
        return true
    }
}
