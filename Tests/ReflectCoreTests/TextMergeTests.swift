import Testing
@testable import ReflectCore

@Suite struct TextMergeTests {
    @Test func trivialSides() {
        #expect(TextMerge.merge(base: "a\n", ours: "a\n", theirs: "b\n") == .init(text: "b\n", conflicted: false))
        #expect(TextMerge.merge(base: "a\n", ours: "b\n", theirs: "a\n") == .init(text: "b\n", conflicted: false))
        #expect(TextMerge.merge(base: "a\n", ours: "b\n", theirs: "b\n") == .init(text: "b\n", conflicted: false))
        #expect(TextMerge.merge(base: "", ours: "x\n", theirs: "") == .init(text: "x\n", conflicted: false))
    }

    @Test func changesInDifferentPlacesBothKept() {
        let base = "- one\n- two\n- three\n- four\n"
        let ours = "- one, typed here\n- two\n- three\n- four\n"
        let theirs = "- one\n- two\n- three\n- four, from the sync\n- five\n"
        let merged = TextMerge.merge(base: base, ours: ours, theirs: theirs)
        #expect(merged == .init(text: "- one, typed here\n- two\n- three\n- four, from the sync\n- five\n", conflicted: false))
    }

    @Test func theSameLineChangedIsAConflict() {
        let merged = TextMerge.merge(base: "a\nb\nc\n", ours: "a\nB here\nc\n", theirs: "a\nB there\nc\n")
        #expect(merged.conflicted)
        #expect(merged.text == "a\n<<<<<<< this device\nB here\n=======\nB there\n>>>>>>> other device\nc\n")
        #expect(ConflictMarkers.detect(merged.text))
        #expect(ConflictMarkers.resolve(merged.text, keeping: .ours) == "a\nB here\nc\n")
        #expect(ConflictMarkers.resolve(merged.text, keeping: .theirs) == "a\nB there\nc\n")
    }

    @Test func aLastLineWithoutABreak() {
        let merged = TextMerge.merge(base: "a\nb", ours: "a\nb here", theirs: "a\nb there")
        #expect(merged.conflicted)
        #expect(merged.text.hasSuffix(">>>>>>> other device\n"))
        #expect(TextMerge.merge(base: "a\nb", ours: "z\nb", theirs: "a\nb\nc") == .init(text: "z\nb\nc", conflicted: false))
    }

    @Test func bothAddingAtTheEnd() {
        let merged = TextMerge.merge(base: "a\n", ours: "a\nmine\n", theirs: "a\ntheirs\n")
        #expect(merged.conflicted)
    }

    /// Random edits to separate parts of a note, one on each side: every
    /// line either side wrote is in the merge, and nothing conflicts.
    @Test func randomSeparateEditsAlwaysMergeCleanly() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let count = Int.random(in: 4...30, using: &rng)
            let base = (0..<count).map { "line \($0)\n" }
            let split = Int.random(in: 1..<(count - 1), using: &rng)
            func edit(_ range: Range<Int>, tag: String) -> [String] {
                var lines = base
                var added: [String] = []
                for index in range.reversed() where Bool.random(using: &rng) {
                    switch Int.random(in: 0..<3, using: &rng) {
                    case 0: lines[index] = "line \(index) \(tag)\n"; added.append(lines[index])
                    case 1: lines.remove(at: index)
                    default: let new = "new \(index) \(tag)\n"; lines.insert(new, at: index + 1); added.append(new)
                    }
                }
                return lines
            }
            // A line between the two parts left alone, so they never touch.
            let ours = edit(0..<(split - 1 < 0 ? 0 : max(0, split - 1)), tag: "ours")
            let theirs = edit((split + 1)..<count, tag: "theirs")
            let merged = TextMerge.merge(base: base.joined(), ours: ours.joined(), theirs: theirs.joined())
            #expect(!merged.conflicted)
            let lines = Set(TextMerge.lines(merged.text).map(String.init))
            for line in ours + theirs where line.contains("ours") || line.contains("theirs") {
                #expect(lines.contains(line))
            }
        }
    }
}
