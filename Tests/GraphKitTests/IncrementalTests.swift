import Foundation
import Testing
@testable import GraphKit

/// The index kept page by page answers every question as one read afresh.
@Suite struct IncrementalTests {
    @Test func keptAsItGoesIsAsIfReadAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("incremental-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = PageIndex(root: root)
        try kept.load()
        let day = { (n: Double) in Date(timeIntervalSince1970: n * 86400) }
        try kept.save(Page(title: "Apple", tags: ["Fruit"], modified: day(1), text: "Crisp. [[Pear]] and [[Quince]]. #orchard"))
        try kept.save(Page(title: "Pear", tags: ["Fruit"], modified: day(2), fields: [Page.Field("aliases", .list(["Poire"]))],
                           text: "Soft, unlike [[Apple]]."))
        try kept.save(Page(title: "Fruit", modified: day(3), fields: [Page.Field("list", .list(["Pear", "Apple"]))],
                           text: "```query\ntag: Fruit\n```"))
        try kept.save(Page(title: "Orchard Notes", modified: day(4), fields: [Page.Field("about", .text("Apple"))],
                           text: "Visited the [[Poire]] trees. Worry about frost."))
        try kept.save(Page(title: "2026-10-31", text: "Picked [[Apple]]s. Missing [[Medlar]]."))
        // Changed, renamed, given an alias, untagged, deleted.
        try kept.save(Page(title: "Apple", tags: ["Fruit", "Red"], modified: day(5), text: "Crisp and red. [[Pear]]."))
        try kept.relink(from: "Pear", to: "Williams Pear")
        try kept.save(Page(title: "Williams Pear", tags: ["Fruit"], modified: day(6), fields: [Page.Field("aliases", .list(["Poire"]))],
                           text: "Soft, unlike [[Apple]]."), replacing: "Pear")
        try kept.save(Page(title: "Quince", modified: day(7), text: "Hard. Worry about frost too."))
        try kept.delete("Quince")
        try kept.save(Page(title: "Medlar", modified: day(8), text: "Bletted."))
        try Data("---\ntitle: Conflicted\n---\n<<<<<<< ours\na\n=======\nb\n>>>>>>> theirs\n".utf8)
            .write(to: root.appendingPathComponent("notes/conflicted.md"))
        kept.reload(path: "notes/conflicted.md")

        let fresh = PageIndex(root: root)
        try fresh.load()
        #expect(kept.titles == fresh.titles)
        #expect(kept.recent(limit: 100) == fresh.recent(limit: 100))
        for title in fresh.titles {
            #expect(kept.backlinks(to: title) == fresh.backlinks(to: title), "\(title)")
            #expect(kept.links(from: title) == fresh.links(from: title), "\(title)")
            #expect(kept.references(to: title) == fresh.references(to: title), "\(title)")
            #expect(kept.tags(of: title) == fresh.tags(of: title))
        }
        for name in ["apple", "POIRE", "williams pear", "Pear", "Quince", "Medlar", "2026-10-31", "Orchard Notes"] {
            #expect(kept.title(for: name) == fresh.title(for: name), "\(name)")
        }
        #expect(kept.missing() == fresh.missing())
        #expect(kept.missing().isEmpty)
        #expect(kept.tags().map(\.tag) == fresh.tags().map(\.tag))
        #expect(kept.tags().map(\.count) == fresh.tags().map(\.count))
        #expect(kept.tagged("fruit") == fresh.tagged("fruit"))
        #expect(kept.conflicted() == fresh.conflicted() && kept.conflicted() == ["Conflicted"])
        for query in ["a", "ap", "poi", "pear", "worry about", "worry ab", "frost", "crisp red", "nothing here"] {
            #expect(kept.search(query) == fresh.search(query), "\(query)")
            #expect(kept.find(query).map(\.title) == fresh.find(query).map(\.title), "\(query)")
        }
        #expect(kept.search("poi").first == "Williams Pear")
        #expect(kept.search("pear").contains("Williams Pear"))
        #expect(kept.find("worry about").map(\.title) == ["Orchard Notes"])
        #expect(kept.pages(flagged: .day) == ["2026-10-31"])
    }
}
