import Testing
@testable import ReflectCore

/// A note's Markdown with its done items moved down, from the row at `index`.
private func sunk(_ source: String, at index: Int) -> (String, Int?) {
    var outline = OutlineMarkdown.parse(source)
    let landed = OutlineEditing.moveDoneToBottom(&outline.rows, at: index)
    return (OutlineMarkdown.serialize(outline), landed)
}

@Suite struct DoneToBottomTests {
    @Test func doneGoBelowTheRestInTheirOrder() {
        let (text, landed) = sunk("- [x] a\n- [ ] b\n- [x] c\n- [ ] d\n", at: 0)
        #expect(text == "- [ ] b\n- [ ] d\n- [x] a\n- [x] c\n")
        #expect(landed == 2)
    }

    @Test func childrenGoAlong() {
        let (text, _) = sunk("- [x] a\n  - note on a\n- [ ] b\n", at: 2)
        #expect(text == "- [ ] b\n- [x] a\n  - note on a\n")
    }

    @Test func fromTheParentItSortsItsChildren() {
        let (text, landed) = sunk("- Groceries\n  - [x] milk\n  - [ ] eggs\n- After\n", at: 0)
        #expect(text == "- Groceries\n  - [ ] eggs\n  - [x] milk\n- After\n")
        #expect(landed == 0)
    }

    @Test func plainBulletsStayWithTheOpen() {
        let (text, _) = sunk("- [x] a\n- plain\n- [ ] b\n", at: 0)
        #expect(text == "- plain\n- [ ] b\n- [x] a\n")
    }

    @Test func nothingDoneIsNothingMoved() {
        let (text, landed) = sunk("- [ ] a\n- [x] b\n", at: 0)
        #expect(text == "- [ ] a\n- [x] b\n")
        #expect(landed == nil)
    }

    @Test func otherListsAreLeftAlone() {
        let (text, _) = sunk("- one\n  - [x] a\n  - [ ] b\n- two\n  - [x] c\n  - [ ] d\n", at: 1)
        #expect(text == "- one\n  - [ ] b\n  - [x] a\n- two\n  - [x] c\n  - [ ] d\n")
    }

    @Test func orderedListsKeepCounting() {
        let (text, _) = sunk("1. [x] a\n2. [ ] b\n3. [ ] c\n", at: 0)
        #expect(text == "1. [ ] b\n2. [ ] c\n3. [x] a\n")
    }

    @Test func blankLinesStayWhereTheyWere() {
        let (text, _) = sunk("- [x] a\n\n- [ ] b\n- [ ] c\n", at: 0)
        #expect(text == "- [ ] b\n\n- [ ] c\n- [x] a\n")
    }

    @Test func aHeadingPartsTheList() {
        let (text, _) = sunk("- [x] a\n- [ ] b\n## Later\n- [x] c\n- [ ] d\n", at: 0)
        #expect(text == "- [ ] b\n- [x] a\n## Later\n- [x] c\n- [ ] d\n")
    }

    @Test func underAParentSortsItsChildrenNotItsSiblings() {
        var outline = OutlineMarkdown.parse("- [x] done sibling\n- Groceries\n  - [x] milk\n  - [ ] eggs\n")
        #expect(OutlineEditing.moveDoneToBottom(&outline.rows, under: 1))
        #expect(OutlineMarkdown.serialize(outline) == "- [x] done sibling\n- Groceries\n  - [ ] eggs\n  - [x] milk\n")
    }

    @Test func everyListInTheNote() {
        var outline = OutlineMarkdown.parse("---\ninbox: true\n---\n- [x] a\n  - [x] a1\n  - [ ] a2\n- [ ] b\n## Later\n- [x] c\n- [ ] d\n")
        #expect(OutlineEditing.moveAllDoneToBottom(&outline.rows))
        #expect(OutlineMarkdown.serialize(outline)
            == "---\ninbox: true\n---\n- [ ] b\n- [x] a\n  - [ ] a2\n  - [x] a1\n## Later\n- [ ] d\n- [x] c\n")
        #expect(!OutlineEditing.moveAllDoneToBottom(&outline.rows))
    }
}
