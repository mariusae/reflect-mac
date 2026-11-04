import Foundation
import Testing
@testable import GraphKit

@Suite struct QueryOrderTests {
    private func graph() throws -> (PageIndex, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("order-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wiki = PageIndex(root: root)
        try wiki.load()
        // A page a day, the newest last: each tagged as named.
        let pages: [(String, [String])] = [("A", ["Work"]), ("B", ["Home"]), ("C", ["Work", "Urgent"]), ("D", []), ("E", ["Home"]), ("F", ["Someday"])]
        for (day, page) in pages.enumerated() {
            try wiki.save(Page(title: page.0, tags: page.1, modified: Date(timeIntervalSince1970: 1_790_000_000 + Double(day) * 86_400), text: "x\n"))
        }
        return (wiki, root)
    }

    @Test func readsAndWritesItsPriorities() {
        let query = Query(text: "any tag: Work, Home\nsort: -modified\nhigh priority: Urgent, Home\nlow priority: Someday\npriority: grouped")
        #expect(query.anyTags == ["Work", "Home"])
        #expect(query.highPriority == ["Urgent", "Home"])
        #expect(query.lowPriority == ["Someday"])
        #expect(query.priorityMode == .grouped)
        #expect(Query(text: query.text) == query)
    }

    @Test func anyTag() throws {
        let (wiki, root) = try graph()
        defer { try? FileManager.default.removeItem(at: root) }
        let query = Query(text: "any tag: Work, Home\nsort: -modified")
        #expect(query.run(in: wiki, this: "") == ["E", "C", "B", "A"])
        #expect(query.ordered(in: wiki).map(\.title) == ["E", "C", "B", "A"])
    }

    @Test func ranked() throws {
        let (wiki, root) = try graph()
        defer { try? FileManager.default.removeItem(at: root) }
        // Newest first; Urgent, then Home, ahead; Someday behind.
        let query = Query(text: "sort: -modified\nhigh priority: Urgent, Home\nlow priority: Someday")
        #expect(query.ordered(in: wiki).map(\.title) == ["C", "E", "B", "D", "A", "F"])
    }

    @Test func grouped() throws {
        let (wiki, root) = try graph()
        defer { try? FileManager.default.removeItem(at: root) }
        // High priority as one: newest first among them.
        let query = Query(text: "sort: -modified\nhigh priority: Urgent, Home\nlow priority: Someday\npriority: grouped")
        #expect(query.ordered(in: wiki).map(\.title) == ["E", "C", "B", "D", "A", "F"])
    }

    @Test func aPlaceBetweenStaysBetween() throws {
        let (wiki, root) = try graph()
        defer { try? FileManager.default.removeItem(at: root) }
        let query = Query(text: "sort: -modified")
        let order = query.ordered(in: wiki)
        let e = order[1].place, d = order[2].place
        let between = query.place(between: e, and: d)
        #expect(query.precedes(e, between))
        #expect(query.precedes(between, d))
        // At the end: after the last.
        let last = query.place(between: order.last!.place, and: nil)
        #expect(query.precedes(order.last!.place, last))
        // At the top: before the first.
        let first = query.place(between: nil, and: order[0].place)
        #expect(query.precedes(first, order[0].place))
    }
}
