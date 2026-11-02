import Foundation
import Testing
@testable import ReflectCore

/// Notes related in frontmatter, without a link in their text.
struct RelatedTests {
    @Test func namesAreReadInEitherListFormAndAsLinks() {
        #expect(Related.names(in: "---\nrelated: [Alpha, \"Beta, Gamma\", '[[Delta]]']\n---\nText.\n") == ["Alpha", "Beta, Gamma", "Delta"])
        #expect(Related.names(in: "---\nrelated:\n  - Alpha\n  - \"[[Beta|the b]]\"\n  - alpha\n---\n") == ["Alpha", "Beta"])
        #expect(Related.names(in: "No frontmatter.\n").isEmpty)
    }

    @Test func addingAndRemovingKeepEverythingElse() {
        let source = "---\ntitle: One\npinned: 1024\n---\n# One\n\n- a row\n"
        let added = Related.adding("Planning: a primer", to: Related.adding("Two", to: source))
        #expect(added == "---\ntitle: One\npinned: 1024\nrelated:\n  - Two\n  - \"Planning: a primer\"\n---\n# One\n\n- a row\n")
        #expect(Related.adding("two", to: added) == added)
        #expect(Related.names(in: added) == ["Two", "Planning: a primer"])
        let removed = Related.removing(["TWO"], from: added)
        #expect(Related.names(in: removed) == ["Planning: a primer"])
        #expect(Related.removing(["Planning: a primer"], from: removed) == source)
        #expect(Related.adding("Two", to: "Just text.\n") == "---\nrelated:\n  - Two\n---\nJust text.\n")
    }

    @Test func aRelationIsShownBothWays() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("related-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try "---\nrelated:\n  - Beta\n  - Nowhere\n---\n# Alpha\n".write(to: notes.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
        try "---\naliases: [B]\n---\n# Beta\n".write(to: notes.appendingPathComponent("beta.md"), atomically: true, encoding: .utf8)
        try "---\nrelated: [b]\n---\n# Gamma\n".write(to: notes.appendingPathComponent("gamma.md"), atomically: true, encoding: .utf8)
        let index = NoteIndex(root: root)
        index.scan()
        #expect(index.related(to: "notes/alpha.md") == [RelatedNote(name: "Beta", path: "notes/beta.md", isOwn: true),
                                                         RelatedNote(name: "Nowhere", path: nil, isOwn: true)])
        #expect(index.related(to: "notes/beta.md") == [RelatedNote(name: "Alpha", path: "notes/alpha.md", isOwn: false),
                                                        RelatedNote(name: "Gamma", path: "notes/gamma.md", isOwn: false)])
    }
}
