import Testing
@testable import ReflectCore

/// Rows written as an outline in a string, `  ` a level: `"a\n  b"`.
private func rows(_ text: String) -> [Row] {
    text.split(separator: "\n").map { line in
        let depth = line.prefix(while: { $0 == " " }).count / 2
        let name = line.drop(while: { $0 == " " })
        if name.hasPrefix("p:") { return Row(kind: .paragraph, depth: depth, text: String(name.dropFirst(2))) }
        return Row(kind: .bullet, depth: depth, text: String(name))
    }
}

private func shape(_ rows: [Row]) -> String {
    rows.map { String(repeating: "  ", count: $0.depth) + ($0.kind == .paragraph ? "p:" : "") + $0.text + ($0.isFolded ? "+" : "") }
        .joined(separator: "\n")
}

@Suite struct EditingTests {
    @Test func indentTakesChildren() {
        var outline = rows("a\nb\n  c\nd")
        #expect(OutlineEditing.indent(&outline, 1..<2) == 1..<2)
        #expect(shape(outline) == "a\n  b\n    c\nd")
    }

    @Test func indentNeedsASibling() {
        var outline = rows("a\n  b")
        #expect(OutlineEditing.indent(&outline, 1..<2) == nil)
        #expect(OutlineEditing.indent(&outline, 0..<1) == nil)
    }

    @Test func indentUnderParagraphIsRefused() {
        var outline = rows("p:a\nb")
        #expect(OutlineEditing.indent(&outline, 1..<2) == nil)
    }

    @Test func indentOpensAFoldedParent() {
        var outline = rows("a\n  x\nb")
        OutlineEditing.fold(&outline, at: 0)
        #expect(shape(outline) == "a+\nb")
        #expect(OutlineEditing.indent(&outline, 1..<2) == 2..<3)
        #expect(shape(outline) == "a\n  x\n  b")
    }

    @Test func outdentAdoptsFollowingSiblings() {
        var outline = rows("a\n  b\n  c")
        #expect(OutlineEditing.outdent(&outline, 1..<2) == 1..<2)
        #expect(shape(outline) == "a\nb\n  c")
    }

    @Test func moveUpSwapsSubtrees() {
        var outline = rows("a\n  a1\nb\n  b1\nc")
        #expect(OutlineEditing.moveUp(&outline, 2..<3) == 0..<1)
        #expect(shape(outline) == "b\n  b1\na\n  a1\nc")
        #expect(OutlineEditing.moveUp(&outline, 0..<1) == nil)
    }

    @Test func moveDownSwapsSubtrees() {
        var outline = rows("a\n  a1\nb\n  b1\nc")
        #expect(OutlineEditing.moveDown(&outline, 0..<1) == 2..<3)
        #expect(shape(outline) == "b\n  b1\na\n  a1\nc")
        #expect(OutlineEditing.moveDown(&outline, 4..<5) == nil)
    }

    @Test func foldAndUnfold() {
        var outline = rows("a\n  b\n    c\nd")
        OutlineEditing.foldCompletely(&outline, at: 0)
        #expect(shape(outline) == "a+\nd")
        OutlineEditing.unfold(&outline, at: 0)
        #expect(shape(outline) == "a\n  b+\nd")
        OutlineEditing.fold(&outline, at: 0)
        OutlineEditing.unfold(&outline, at: 0, completely: true)
        #expect(shape(outline) == "a\n  b\n    c\nd")
    }

    @Test func foldedRowsAreWritten() {
        var outline = OutlineMarkdown.parse("- a\n  - b\n- c\n")
        OutlineEditing.fold(&outline.rows, at: 0)
        #expect(outline.rows.count == 2)
        #expect(OutlineMarkdown.serialize(outline) == "- a\n  - b\n- c\n")
    }

    @Test func deleteTakesChildrenAndKeepsARow() {
        var outline = rows("a\n  b\nc")
        #expect(OutlineEditing.delete(&outline, 0..<1) == 0)
        #expect(shape(outline) == "c")
        _ = OutlineEditing.delete(&outline, 0..<1)
        #expect(outline == [.blank])
    }

    @Test func normalizeClampsDepth() {
        var outline = rows("a\n    b\np:c\n  d")
        OutlineEditing.normalize(&outline)
        #expect(shape(outline) == "a\n  b\np:c\nd")
    }

    @Test func editorRowsStayRows() {
        // A paragraph row made right under a list item must come back a row.
        let outline = Outline(rows: [Row(kind: .bullet, text: "a"), Row(kind: .paragraph, depth: 1, text: "b")])
        let text = OutlineMarkdown.serialize(outline)
        #expect(text == "- a\n\n  b\n")
        #expect(OutlineMarkdown.parse(text).rows.map(\.depth) == [0, 1])
    }

    @Test func orderedItemsAreSiblings() {
        #expect(OutlineMarkdown.parse("1. a\n2. b\n").rows.count == 2)
        #expect(OutlineMarkdown.parse("text\n2. b\n").rows.count == 1)
    }
}

@Suite struct GapTests {
    @Test func movingKeepsBlankLinesInPlace() {
        var outline = OutlineMarkdown.parse("## H\n\n- a\n- b\n")
        #expect(OutlineEditing.moveUp(&outline.rows, 2..<3) == 1..<2)
        #expect(OutlineMarkdown.serialize(outline) == "## H\n\n- b\n- a\n")
        #expect(OutlineEditing.moveDown(&outline.rows, 1..<2) == 2..<3)
        #expect(OutlineMarkdown.serialize(outline) == "## H\n\n- a\n- b\n")
    }
}

@Suite struct SectionTests {
    let note = "- a\n\n## [[Links]]\n\n- one\n- two\n  - three\n\n## Next\n\n- four\n"

    @Test func headingsHoldTheirSections() {
        let rows = OutlineMarkdown.parse(note).rows
        #expect(OutlineEditing.levels(rows) == [0, 0, 1, 1, 2, 0, 1])
        #expect(OutlineEditing.subtreeEnd(rows, 1) == 5)
        let nested = OutlineMarkdown.parse("# A\n## B\n- x\n## C\n# D\n").rows
        #expect(OutlineEditing.levels(nested) == [0, 1, 2, 1, 0])
    }

    @Test func foldingAHeadingFoldsItsSection() {
        var outline = OutlineMarkdown.parse(note)
        #expect(OutlineEditing.fold(&outline.rows, at: 1) == 3)
        #expect(outline.rows.map(\.text) == ["a", "[[Links]]", "Next", "four"])
        #expect(OutlineMarkdown.serialize(outline) == note)
        OutlineEditing.unfold(&outline.rows, at: 1)
        #expect(OutlineMarkdown.serialize(outline) == note)
    }

    @Test func movingAHeadingTakesItsSection() {
        var outline = OutlineMarkdown.parse(note)
        #expect(OutlineEditing.moveDown(&outline.rows, 1..<2) == 3..<4)
        #expect(OutlineMarkdown.serialize(outline) == "- a\n\n## Next\n\n- four\n\n## [[Links]]\n\n- one\n- two\n  - three\n")
    }

    @Test func indentingIgnoresSections() {
        var outline = OutlineMarkdown.parse(note)
        #expect(OutlineEditing.indent(&outline.rows, 3..<4) == 3..<4)
        #expect(outline.rows[3].depth == 1)
        #expect(outline.rows[4].depth == 2)
    }
}

@Suite struct FoldMarkTests {
    let note = "- a\n  - b\n    - c\n  - d\n- e\n  - f\n"

    @Test func recordsAndRestoresFoldsNestedInFolds() {
        var rows = OutlineMarkdown.parse(note).rows
        OutlineEditing.fold(&rows, at: 1)   // b
        OutlineEditing.fold(&rows, at: 0)   // a, with b folded inside
        OutlineEditing.fold(&rows, at: 1)   // e
        let marks = OutlineFolds.marks(rows)
        #expect(marks == [.init(index: 0, text: "a"), .init(index: 1, text: "b"), .init(index: 4, text: "e")])
        let restored = OutlineFolds.apply(marks, to: OutlineMarkdown.parse(note).rows)
        #expect(restored == rows)
    }

    @Test func followsARowThatMovedAndDropsOneThatWent() {
        let edited = OutlineMarkdown.parse("- new\n- a\n  - b\n- e\n").rows
        let restored = OutlineFolds.apply([.init(index: 0, text: "a"), .init(index: 4, text: "gone")], to: edited)
        #expect(restored.map(\.text) == ["new", "a", "e"])
        #expect(restored[1].isFolded)
    }

    @Test func foldsNothingWithoutChildren() {
        let rows = OutlineMarkdown.parse("- a\n- b\n").rows
        #expect(OutlineFolds.apply([.init(index: 0, text: "a")], to: rows) == rows)
    }
}

/// Reflect's two checkboxes: ⌘Return's square checklist item and ⇧⌘Return's
/// round task, each cycling open → checked → bullet.
@Suite struct CheckboxTests {
    func cycled(_ source: String, _ checkbox: OutlineEditing.Checkbox, times: Int = 1) -> String {
        var outline = OutlineMarkdown.parse(source)
        for _ in 0..<times { OutlineEditing.cycle(checkbox, &outline.rows, 0..<1) }
        return OutlineMarkdown.serialize(outline)
    }

    @Test func checklistItemsCycle() {
        #expect(cycled("- thing\n", .checklist) == "- [ ] thing\n")
        #expect(cycled("- thing\n", .checklist, times: 2) == "- [x] thing\n")
        #expect(cycled("- thing\n", .checklist, times: 3) == "- thing\n")
        #expect(cycled("* thing\n", .checklist) == "* [ ] thing\n")
        #expect(cycled("plain text\n", .checklist) == "- [ ] plain text\n")
    }

    @Test func tasksCycle() {
        #expect(cycled("- thing\n", .task) == "+ [ ] thing\n")
        #expect(cycled("- thing\n", .task, times: 2) == "+ [x] thing\n")
        #expect(cycled("- thing\n", .task, times: 3) == "- thing\n")
    }

    @Test func oneKindBecomesTheOther() {
        // A checked checklist item made a task starts open, round.
        #expect(cycled("- [x] thing\n", .task) == "+ [ ] thing\n")
        #expect(cycled("+ [ ] thing\n", .checklist) == "- [ ] thing\n")
        // Headings stay headings.
        #expect(cycled("# Title\n", .task) == "# Title\n")
    }
}

@Suite struct ContinuationTests {
    /// A row's lines after its first, as ⇧Return makes them, written so each
    /// reads back as the same row: a quote's with `>`, a bullet's indented.
    @Test func quoteAndBulletLinesRoundTrip() {
        for row in [Row(kind: .quote, text: "first line\nsecond line"), Row(kind: .bullet, text: "first\nsecond"),
                    Row(kind: .bullet, depth: 1, text: "nested\nmore")] {
            var rows = [Row(kind: .bullet, text: "top")]
            if row.depth == 0 { rows = [] }
            rows.append(row)
            let text = OutlineMarkdown.serialize(Outline(rows: rows))
            let back = OutlineMarkdown.parse(text).rows
            #expect(back.last?.text == row.text, "\(text)")
            #expect(back.last?.kind == row.kind)
            #expect(back.count == rows.count)
        }
    }

    /// A quote's lines each start `>`, and read back as the one quote.
    @Test func quoteLinesKeepTheirMarks() {
        let quote = OutlineMarkdown.serialize(Outline(rows: [Row(kind: .quote, text: "first line\nsecond line")]))
        #expect(quote == "> first line\n> second line\n")
        for source in ["> a\n> b\n", "> a\nlazy\n> b\n", "> a\n>\n> b\n", "> a\n>b\n", "- x\n  > a\n  > b\n", "> a\n\n> b\n"] {
            #expect(OutlineMarkdown.roundTrips(source), "\(source)")
        }
        #expect(OutlineMarkdown.parse("> a\n> b\n").rows.count == 1)
        #expect(OutlineMarkdown.parse("> a\n\n> b\n").rows.count == 2)
    }
}
