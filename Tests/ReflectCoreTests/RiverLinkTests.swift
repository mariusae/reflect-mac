import Foundation
import Testing
@testable import ReflectCore

@Suite struct RiverLinkTests {
    @Test func aRiversNameFromItsLink() {
        #expect(RiverLink.name("rivers/Work") == "Work")
        #expect(RiverLink.name("Rivers/Work.md") == "Work")
        #expect(RiverLink.name("rivers/") == nil)
        #expect(RiverLink.name("notes/Work") == nil)
        #expect(RiverLink.name("rivers/a/b") == nil)
        #expect(RiverLink.link("Work") == "[[rivers/Work]]")
    }

    @Test func aRiverLinkShowsItsNameAlone() {
        let text = "see [[rivers/Weft work]] and [[rivers/Work|the work]]" as NSString
        let spans = InlineMarkup.spans(in: text, range: NSRange(location: 0, length: text.length))
        #expect(spans.map { text.substring(with: $0.content) } == ["Weft work", "the work"])
        #expect(spans.first?.markup.map { text.substring(with: $0) } == ["[[rivers/", "]]"])
    }
}
