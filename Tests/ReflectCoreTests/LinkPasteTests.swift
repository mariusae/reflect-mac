import Foundation
import Testing
@testable import ReflectCore

@Suite struct LinkPasteTests {
    @Test func addresses() {
        #expect(LinkPaste.address(in: " https://example.com/a?b=c \n") == "https://example.com/a?b=c")
        #expect(LinkPaste.address(in: "mailto:a@b.c") == "mailto:a@b.c")
        #expect(LinkPaste.address(in: "two words") == nil)
        #expect(LinkPaste.address(in: "ftp://example.com") == nil)
        #expect(LinkPaste.address(in: "example.com") == nil)
    }

    @Test func wordsBecomeALink() throws {
        let linked = try #require(LinkPaste.link("Read the paper today", selection: NSRange(location: 9, length: 5), to: "https://arxiv.org/abs/1"))
        #expect(linked.text == "Read the [paper](https://arxiv.org/abs/1) today")
        #expect(linked.caret == 41)
    }

    @Test func aLinksWordsArePointedElsewhere() throws {
        let row = "See [the paper](https://old.example) now"
        let linked = try #require(LinkPaste.link(row, selection: NSRange(location: 5, length: 9), to: "https://new.example/x(1)"))
        #expect(linked.text == "See [the paper](https://new.example/x%281%29) now")
    }

    @Test func notOverAnAddressOrLines() {
        #expect(LinkPaste.link("https://a.example", selection: NSRange(location: 0, length: 17), to: "https://b.example") == nil)
        #expect(LinkPaste.link("one\ntwo", selection: NSRange(location: 0, length: 7), to: "https://b.example") == nil)
        #expect(LinkPaste.link("words", selection: NSRange(location: 0, length: 0), to: "https://b.example") == nil)
    }
}
