import Foundation
import Testing
@testable import PrismCore

@Suite struct DictatedSpanTests {
    @Test func foundFromWhatFollowsOnItsLine() {
        // " when the um..." written after "for,", then `...` made `…`.
        let text = "for, when the um… then\nLinks\n" as NSString
        #expect(DictatedSpan.span(from: 4, tail: 5, in: text) == NSRange(location: 4, length: 13))
    }

    @Test func neverPastTheLine() {
        let text = "for, um…\nLinks\n" as NSString
        #expect(DictatedSpan.span(from: 4, tail: 0, in: text) == NSRange(location: 4, length: 4))
    }

    @Test func tailIsTheRestOfTheLine() {
        let text = "for, um then\nLinks\n" as NSString
        #expect(DictatedSpan.tail(after: NSRange(location: 4, length: 3), in: text) == 5)
        #expect(DictatedSpan.tail(after: NSRange(location: 0, length: 12), in: text) == 0)
    }
}
