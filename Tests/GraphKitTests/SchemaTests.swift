import Foundation
import Testing
@testable import GraphKit

@Suite struct SchemaTests {
    @Test func readsAndWritesSpecs() {
        let items = ["birthday (date)", "company (link)", "status (active | paused | done)", "rating (number)",
                     "website (url)", "met (yes/no)", "notes"]
        let specs = items.compactMap(FieldSpec.init(item:))
        #expect(specs.map(\.kind) == [.date, .link, .choice(["active", "paused", "done"]), .number, .url, .flag, .text])
        #expect(specs.map(\.item) == items)
        #expect(FieldSpec(item: "favourite colour (Colour)")?.kind == .text)
        #expect(FieldSpec(item: "  ") == nil)
    }

    @Test func aTiddlersTagsGiveItsFields() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("schema-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let wiki = PageIndex(root: root)
        try wiki.save(Page(title: "Person", fields: [Page.Field("fields", .list(["birthday (date)", "company (link)"]))]))
        try wiki.save(Page(title: "Friend", fields: [Page.Field("fields", .list(["company (text)", "met (yes/no)"]))]))
        try wiki.save(Page(title: "Ada", tags: ["Person", "Friend"]))
        #expect(wiki.schema(for: wiki["Ada"]!) == [FieldSpec(name: "birthday", kind: .date), FieldSpec(name: "company", kind: .link),
                                                    FieldSpec(name: "met", kind: .flag)])
        #expect(wiki.schema(for: wiki["Person"]!).isEmpty)
    }

    @Test func datesAndFlags() throws {
        let date = try #require(FieldSpec.date("2026-10-31"))
        #expect(Calendar.current.component(.day, from: date) == 31)
        #expect(FieldSpec.value(of: date) == "2026-10-31")
        #expect(FieldSpec.date("not a date") == nil)
        #expect(FieldSpec.flag("Yes") && !FieldSpec.flag("no"))
    }
}
