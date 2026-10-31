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
