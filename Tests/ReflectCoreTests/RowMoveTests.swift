import Testing
import ReflectCore

@Suite struct RowMoveTests {
    @Test func aBlockStandsAtTheTopLevelWhereItGoes() {
        let source = OutlineMarkdown.parse("# Project\n\n- Plans\n  - Call Ana\n    - About the lease\n- Later\n").rows
        let moved = RowMove.detached(Array(source[2...3]))
        #expect(moved.map(\.text) == ["Call Ana", "About the lease"])
        #expect(moved.map(\.depth) == [0, 1])
    }

    @Test func aNoteGetsThemAtItsEnd() {
        let rows = OutlineMarkdown.parse("- Call Ana\n  - About the lease\n").rows
        let after = RowMove.adding(rows, to: "# Ana\n\n- Met in May\n", path: "notes/ana.md")
        #expect(after == "# Ana\n\n- Met in May\n- Call Ana\n  - About the lease\n")
    }

    @Test func aDayGetsThemAtItsTopAfterItsTitle() {
        let rows = OutlineMarkdown.parse("- Call Ana\n").rows
        let after = RowMove.adding(rows, to: "# Friday\n\n- Lunch\n", path: "daily/2026-10-30.md")
        #expect(after == "# Friday\n\n- Call Ana\n- Lunch\n")
    }

    @Test func anEmptyNoteGetsThemAlone() {
        let rows = OutlineMarkdown.parse("- Call Ana\n").rows
        #expect(RowMove.adding(rows, to: "", path: "notes/ana.md") == "- Call Ana\n")
    }
}
