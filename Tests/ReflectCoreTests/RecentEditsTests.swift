import Foundation
import Testing
@testable import PrismCore

struct RecentEditsTests {
    @Test func recordsChangedRowsWithAncestors() {
        var recent = RecentEdits()
        let old = "- Project\n    - idea one\n- Other\n"
        let new = "- Project\n    - idea one\n    - idea two\n- Other changed\n"
        recent.note("notes/a.md", from: old, to: new)
        #expect(recent.edits.map(\.text) == ["idea two", "Other changed"])
        #expect(recent.edits[0].ancestors == ["Project"])
        // Typed on: the same row, its latest words.
        recent.note("notes/a.md", from: new, to: new.replacingOccurrences(of: "idea two", with: "idea two more"))
        #expect(recent.edits.map(\.text) == ["idea two more", "Other changed"])
        #expect(recent.matching("project").map(\.text) == ["idea two more"])
        #expect(RecentEdits.locate(recent.edits[0], in: new.replacingOccurrences(of: "idea two", with: "idea two more")) == 2)
    }
}

struct RecentEditsTitleTests {
    @Test func matchesTheNoteName() {
        var recent = RecentEdits()
        recent.note("notes/monarch.md", from: "", to: "- a row\n")
        #expect(recent.matching("monarch", title: { _ in "Monarch" }).count == 1)
        #expect(recent.matching("monarch").isEmpty)
    }

    /// A row written on — dictated, words changed as it went — is one edit,
    /// and found by its words, quotes as typed.
    @Test func aRowWrittenOnIsOneEdit() {
        let day = "daily/2026-10-31.md"
        func edit(_ text: String) -> RecentEdits.Edit { .init(path: day, text: text, ancestors: ["Ant"], date: Date()) }
        let older = RecentEdits(edits: [
            edit("I do worry about AI’s effect on our thinking for ourselves. That’s a big one"),
            edit("I do worry about AI’s effect on our thinking for ourselves."),
            edit("I do worry about AI’s effect on our thinking"),
            edit("I do worry about"),
            edit("Think first it's super important to identify what the goal is."),
        ])
        #expect(older.distinct.count == 2)
        #expect(older.matching("ai's effect").count == 1)
        #expect(older.matching("i do worry").first?.text.hasSuffix("big one") == true)
    }
}
