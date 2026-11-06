import Foundation
import Testing
@testable import GraphKit

@Suite struct QueryTests {
    func wiki() throws -> (PageIndex, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("query-\(UUID())")
        let wiki = PageIndex(root: root)
        let day = { (n: Double) in Date(timeIntervalSince1970: n * 86400) }
        try wiki.save(Page(title: "Fruit", fields: [Page.Field("list", .list(["Pear", "Apple"]))], text: "[[Apple]]"))
        try wiki.save(Page(title: "Apple", tags: ["Fruit"], modified: day(3), fields: [Page.Field("colour", .text("red"))], text: "Crisp. [[Pear]]"))
        try wiki.save(Page(title: "Pear", tags: ["Fruit", "Soft"], modified: day(1), text: "Soft."))
        try wiki.save(Page(title: "Banana", tags: ["Fruit", "Soft"], modified: day(2), text: "Yellow."))
        return (wiki, root)
    }

    @Test func readsAndWritesItsText() {
        let text = "tag: Fruit\nnot tag: Soft\nsort: -modified\nlimit: 3\nshow: table\ncolumns: colour, size\nmystery line"
        let query = Query(text: text)
        #expect(query.tags == ["Fruit"])
        #expect(query.excludedTags == ["Soft"])
        #expect(query.sort == .modified && query.descending)
        #expect(query.limit == 3 && query.show == .table && query.columns == ["colour", "size"])
        #expect(query.text == text)
    }

    @Test func findsTiddlers() throws {
        let (wiki, root) = try wiki()
        defer { try? FileManager.default.removeItem(at: root) }
        // A tag's own order first, then by title.
        #expect(Query(text: "tag: Fruit").run(in: wiki, this: "x") == ["Pear", "Apple", "Banana"])
        #expect(Query(text: "tag: {this}\nnot tag: Soft").run(in: wiki, this: "Fruit") == ["Apple"])
        #expect(Query(text: "tag: Fruit\nsort: -modified\nlimit: 2").run(in: wiki, this: "x") == ["Apple", "Banana"])
        #expect(Query(text: "links to: Pear").run(in: wiki, this: "x") == ["Apple"])
        #expect(Query(text: "linked from: {this}").run(in: wiki, this: "Fruit") == ["Apple"])
        #expect(Query(text: "listed in: Fruit").run(in: wiki, this: "x") == ["Pear", "Apple"])
        #expect(Query(text: "has: colour").run(in: wiki, this: "x") == ["Apple"])
        #expect(Query(text: "text: soft").run(in: wiki, this: "x") == ["Pear"])
    }

    /// Edited since the start of a day, by the calendar: today, yesterday,
    /// so many days ago.
    @Test func findsWhatWasEditedSinceADay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("edited-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let wiki = PageIndex(root: root)
        let today = Calendar.current.startOfDay(for: Date())
        let at = { (days: Int, hours: Double) in
            Calendar.current.date(byAdding: .day, value: -days, to: today)!.addingTimeInterval(hours * 3600)
        }
        try wiki.save(Page(title: "This Morning", modified: at(0, 0.01), text: ""))
        try wiki.save(Page(title: "Last Night", modified: at(1, 23.9), text: ""))
        try wiki.save(Page(title: "Three Days Ago", modified: at(3, 12), text: ""))
        try wiki.save(Page(title: "Last Month", modified: at(30, 12), text: ""))
        let found = { (text: String) in Query(text: text + "\nsort: -modified").run(in: wiki, this: "") }
        #expect(found("edited since: today") == ["This Morning"])
        #expect(found("edited since: yesterday") == ["This Morning", "Last Night"])
        #expect(found("edited since: 2 days ago") == ["This Morning", "Last Night"])
        #expect(found("edited since: 3 days ago") == ["This Morning", "Last Night", "Three Days Ago"])
        #expect(found("edited since: 5 weeks ago").count == 4)
        // Written back as a day is said; what is not one, kept as it was.
        #expect(Query(text: "edited since: Today").text == "edited since: today")
        #expect(Query(text: "edited since: 1 day ago").text == "edited since: yesterday")
        #expect(Query(text: "edited since: a week ago").text == "edited since: 7 days ago")
        #expect(Query(text: "edited since: soon").unknown == ["edited since: soon"])
        #expect(Query(text: "edited since: today").summary == "Edited today")
        #expect(Query(text: "edited since: 3 days ago").summary == "Edited since 3 days ago")
        // Its order in words, apart from what it finds.
        #expect(Query(text: "edited since: today\nsort: -modified").summary == "Edited today · newest first")
        #expect(Query(text: "tag: Fruit\nsort: -modified\nlimit: 3").summary == "Tagged Fruit · recently edited first · first 3")
        #expect(Query(text: "sort: title").summary == "Every page · A to Z")
    }

    /// The day so many back starts at its midnight, whenever it is asked.
    @Test func aDayAgoStartsAtItsMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = ISO8601DateFormatter().date(from: "2026-11-04T00:30:00-05:00")!
        #expect(Query.start(ofDaysAgo: 0, from: now, calendar: calendar) == ISO8601DateFormatter().date(from: "2026-11-04T00:00:00-05:00"))
        // Across the clocks going back, still a midnight.
        #expect(Query.start(ofDaysAgo: 3, from: now, calendar: calendar) == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00-04:00"))
    }

    /// Prism's lenses, as queries: the inbox newest first, the pinned by number.
    @Test func findsByFlag() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flags-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let wiki = PageIndex(root: root)
        let day = { (n: Double) in Date(timeIntervalSince1970: n * 86400) }
        try wiki.save(Page(title: "Old", modified: day(1), fields: [Page.Field("inbox", .text("true"))], text: ""))
        try wiki.save(Page(title: "New", modified: day(2), fields: [Page.Field("inbox", .text("true"))], text: ""))
        try wiki.save(Page(title: "Zeta", fields: [Page.Field("pinned", .text("1"))], text: ""))
        try wiki.save(Page(title: "Alpha", fields: [Page.Field("pinned", .text("true"))], text: ""))
        try wiki.save(Page(title: "Beta", fields: [Page.Field("pinned", .text("2"))], text: ""))
        try wiki.save(Page(title: "2026-10-31", text: "A day."))
        #expect(Query(text: "is: inbox\nsort: -modified").run(in: wiki, this: "") == ["New", "Old"])
        #expect(Query(text: "is: pinned\nsort: pinned").run(in: wiki, this: "") == ["Zeta", "Beta", "Alpha"])
        #expect(Query(text: "is: day").run(in: wiki, this: "") == ["2026-10-31"])
        #expect(Query(text: "is: pinned, inbox").run(in: wiki, this: "").isEmpty)
        #expect(Query(text: "is: pinned").text == "is: pinned")
        // What none of them is: left out.
        #expect(Query(text: "is not: inbox, pinned\nsort: title").run(in: wiki, this: "") == ["2026-10-31"])
        #expect(Query(text: "is: pinned\nis not: inbox\nsort: title").run(in: wiki, this: "") == ["Alpha", "Beta", "Zeta"])
        #expect(Query(text: "is not: inbox, todo").text == "is not: inbox, todo")
        #expect(Query(text: "is not: inbox").summary == "Not in the inbox")
        #expect(Query(text: "is not: nonsense").unknown == ["is not: nonsense"])
        #expect(wiki.entry(atPath: "notes/zeta.md")?.page.title == "Zeta")
    }

    /// Words found as typed first, with the line saying them — not the
    /// first "i" in the file.
    @Test func findsWordsTogetherFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("find-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let wiki = PageIndex(root: root)
        let day = { (n: Double) in Date(timeIntervalSince1970: n * 86400) }
        try wiki.save(Page(title: "Ant", id: "01idid", modified: day(1),
                           text: "- Meeting\n  - I do worry about AI’s effect on our thinking.\n- Other"))
        try wiki.save(Page(title: "Scattered", modified: day(5), text: "I said it. Do it. A worry."))
        try wiki.save(Page(title: "Nothing", modified: day(9), text: "No such words."))
        let found = wiki.find("i do worry")
        #expect(found.map(\.title) == ["Ant", "Scattered"])
        #expect(found[0].phrase && found[0].line == "I do worry about AI’s effect on our thinking.")
        #expect(wiki.find("ai's effect").first?.title == "Ant")
    }

    @Test func blocksAreParsedAndReplaced() {
        let text = "Intro\n\n```query\ntag: A\n```\n\n```swift\nlet x\n```\n\n```query\ntag: B\n```\n"
        #expect(MarkdownBlock.parse(text)[1] == .query(Query(text: "tag: A")))
        var query = Query(text: "tag: B")
        query.show = .count
        #expect(MarkdownBlock.replacingQuery(at: 1, in: text, with: query)
            == "Intro\n\n```query\ntag: A\n```\n\n```swift\nlet x\n```\n\n```query\ntag: B\nshow: count\n```\n")
    }
}
