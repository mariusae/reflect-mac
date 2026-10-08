import Testing
@testable import ReflectCore
@testable import PrismCore

@Suite struct NoteCoverTests {
    @Test func readFromFrontmatter() {
        #expect(NoteCover.source(in: "---\ncover: assets/a.jpg\n---\n- x\n") == "assets/a.jpg")
        #expect(NoteCover.source(in: "---\ncover: \"assets/my trip.jpg\"\n---\n") == "assets/my trip.jpg")
        #expect(NoteCover.source(in: "---\ncover: <assets/a b.png>\n---\n") == "assets/a b.png")
        #expect(NoteCover.source(in: "- no frontmatter\n") == nil)
        #expect(NoteCover.source(in: "---\ncover:\n---\n") == nil)
    }

    @Test func setAndTakenOff() {
        let set = NoteCover.setting("assets/a.jpg", in: "- x\n")
        #expect(set == "---\ncover: assets/a.jpg\n---\n- x\n")
        #expect(NoteCover.setting(nil, in: set) == "- x\n")
        let kept = NoteCover.setting("assets/b.jpg", in: "---\ninbox: true\ncover: assets/a.jpg\n---\n- x\n")
        #expect(kept == "---\ninbox: true\ncover: assets/b.jpg\n---\n- x\n")
    }

    @Test func addressesAndAwkwardNamesRoundTrip() {
        for source in ["https://example.com/a.jpg?x=1", "assets/a: b.jpg", "#hash.png", "assets/it's.png"] {
            #expect(NoteCover.source(in: NoteCover.setting(source, in: "- x\n")) == source)
        }
    }

    @Test func indexAndSummaryKnowIt() {
        let text = "---\ncover: assets/c.jpg\n---\n- Words\n- ![](assets/other.png)\n"
        #expect(NoteIndex.entry(path: "notes/a.md", source: text).cover == "assets/c.jpg")
        let summary = NoteSummary.of(text, title: "a")
        #expect(summary.picture == "assets/c.jpg")
        #expect(summary.isCover)
        #expect(!NoteSummary.of("- ![](assets/other.png)\n", title: "a").isCover)
    }
}
