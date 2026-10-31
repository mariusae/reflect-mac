import Foundation
import Testing
@testable import GraphKit

@Suite struct PageMergeTests {
    let base = """
    ---
    title: Fruit
    tags: [Food, Plants]
    modified: 2026-10-01T10:00:00Z
    colour: green
    ---
    Apples and pears.

    """

    func side(tags: String, modified: String, colour: String, body: String = "Apples and pears.\n") -> Data {
        Data("---\ntitle: Fruit\ntags: [\(tags)]\nmodified: \(modified)\ncolour: \(colour)\n---\n\(body)".utf8)
    }

    @Test func settlesTheFrontmatter() throws {
        let ours = side(tags: "Food, Plants, Sweet", modified: "2026-10-02T10:00:00Z", colour: "green")
        let theirs = side(tags: "Food", modified: "2026-10-03T10:00:00Z", colour: "red", body: "Apples, pears and plums.\n")
        let prepared = try #require(PageMerge.prepare(path: "notes/fruit.md", ours: ours, base: Data(base.utf8), theirs: theirs))
        let header = "---\ntitle: Fruit\ntags: [Food, Sweet]\nmodified: 2026-10-03T10:00:00Z\ncolour: red\n---\n"
        #expect(String(decoding: prepared.ours, as: UTF8.self) == header + "Apples and pears.\n")
        #expect(String(decoding: prepared.base, as: UTF8.self) == header + "Apples and pears.\n")
        #expect(String(decoding: prepared.theirs, as: UTF8.self) == header + "Apples, pears and plums.\n")
    }

    @Test func leavesOtherFilesAlone() {
        #expect(PageMerge.prepare(path: "notes/fruit.md", ours: Data(), base: Data(), theirs: Data()) == nil)
        #expect(PageMerge.prepare(path: "notes/plain.md", ours: Data("a".utf8), base: Data("b".utf8), theirs: Data("c".utf8)) == nil)
    }

    @Test func mergesADraftWithWhatChangedUnderIt() {
        let base = Page(title: "T", tags: ["A"], text: "one\n")
        var draft = base
        draft.tags.append("B")
        var current = base
        current.text = "two\n"
        // Only the other device changed the body: theirs, with both tags.
        let merged = PageMerge.merge(draft: draft, base: base, current: current)
        #expect(merged.tags == ["A", "B"])
        #expect(merged.text == "two\n")
        // Both changed it: both, to review.
        draft.text = "three\n"
        #expect(PageMerge.merge(draft: draft, base: base, current: current).text
            == "<<<<<<< this device\nthree\n=======\ntwo\n>>>>>>> other device\n")
    }
}
