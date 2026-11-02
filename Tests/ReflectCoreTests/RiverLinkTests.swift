import Foundation
import Testing
@testable import ReflectCore
import PrismCore

@Suite struct RiverLinkTests {
    @Test func aRiversNameFromItsLink() {
        #expect(RiverLink.name("rivers/Work") == "Work")
        #expect(RiverLink.name("Rivers/Work.md") == "Work")
        #expect(RiverLink.name("rivers/") == nil)
        #expect(RiverLink.name("notes/Work") == nil)
        #expect(RiverLink.name("rivers/a/b") == nil)
        #expect(RiverLink.link("Work") == "[[rivers/Work]]")
        #expect(RiverLink.url("Weft work").absoluteString == "weft://river/Weft%20work")
        #expect(RiverLink.name(from: RiverLink.url("Q&A / notes?")) == "Q&A / notes?")
        #expect(RiverLink.name(from: URL(string: "weft://river/Work")!) == "Work")
        #expect(RiverLink.name(from: URL(string: "weft://page/Work")!) == nil)
        #expect(RiverLink.name(from: URL(string: "https://river/Work")!) == nil)
    }

    @Test func aRiverLinkShowsItsNameAlone() {
        let text = "see [[rivers/Weft work]] and [[rivers/Work|the work]]" as NSString
        let spans = InlineMarkup.spans(in: text, range: NSRange(location: 0, length: text.length))
        #expect(spans.map { text.substring(with: $0.content) } == ["Weft work", "the work"])
        #expect(spans.first?.markup.map { text.substring(with: $0) } == ["[[rivers/", "]]"])
    }
}

@Suite struct RiverLinkListingTests {
    @Test func aGraphsRiversByWhatIsTyped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rivers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("rivers"), withIntermediateDirectories: true)
        for name in ["Weft work", "Taxes", ".hidden"] { try "- [[A]]\n".write(to: root.appendingPathComponent("rivers/\(name).md"), atomically: true, encoding: .utf8) }
        #expect(RiverLink.names(in: root) == ["Taxes", "Weft work"])
        #expect(RiverLink.matching("WORK", in: root) == ["Weft work"])
        #expect(RiverLink.matching("", in: root).isEmpty)
        // `[[` offers them, linked as the files they are.
        let index = NoteIndex(root: root)
        index.scan()
        let offered = LinkSuggestions.candidates("weft", index: index)
        #expect(offered.contains(LinkSuggestions.Candidate(title: "Weft work", name: "rivers/Weft work", isDay: false, isRiver: true)))
    }
}
