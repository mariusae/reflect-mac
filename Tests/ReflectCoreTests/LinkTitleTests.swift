import Foundation
import Testing
@testable import ReflectCore

@Suite struct LinkTitleTests {
    @Test func addATitleToAnAddress() {
        let row = "Read https://example.com/a today"
        #expect(LinkTitle.retitling(row, at: 8, to: "A page")?.text == "Read [A page](https://example.com/a) today")
        #expect(LinkTitle.retitling("<https://example.com/a>", at: 2, to: "A")?.text == "[A](https://example.com/a)")
        #expect(LinkTitle.retitling("<https://example.com/a>", at: 2, to: "")?.text == "https://example.com/a")
    }

    @Test func changeAndTakeAwayATitle() {
        #expect(LinkTitle.retitling("See [old](https://e.com) x", at: 6, to: "new")?.text == "See [new](https://e.com) x")
        #expect(LinkTitle.retitling("See [old](https://e.com) x", at: 6, to: "  ")?.text == "See https://e.com x")
    }

    @Test func readsTheTitle() {
        let text = "[a (b)](https://e.com)" as NSString
        let span = InlineMarkup.spans(in: text, range: NSRange(location: 0, length: text.length)).first!
        #expect(LinkTitle.link(span, in: text)?.title == "a (b)")
        #expect(LinkTitle.link(span, in: text)?.address == "https://e.com")
    }

    @Test func awkwardTitlesAndAddressesStayLinks() {
        let made = LinkTitle.markdown(address: "https://en.wikipedia.org/wiki/Swift_(language)", title: "Swift [lang]")
        #expect(made == "[Swift (lang)](https://en.wikipedia.org/wiki/Swift_%28language%29)")
        let text = made as NSString
        let span = InlineMarkup.spans(in: text, range: NSRange(location: 0, length: text.length)).first!
        #expect(LinkTitle.link(span, in: text)?.title == "Swift (lang)")
        #expect(LinkTitle.link(span, in: text)?.address == "https://en.wikipedia.org/wiki/Swift_%28language%29")
    }

    @Test func hidesAndShowsACard() {
        let titled = "See [A post](https://x.com/a/status/1) now"
        let hidden = LinkTitle.settingCard(titled, at: 6, hidden: true)!
        #expect(hidden.text == #"See [A post](https://x.com/a/status/1 "no card") now"#)
        #expect(LinkTitle.hidesCard(hidden.text, at: 6) == true)
        // Still the same link, its words and address.
        let ns = hidden.text as NSString
        let span = InlineMarkup.spans(in: ns, range: NSRange(location: 0, length: ns.length)).first { if case .link = $0.kind { true } else { false } }!
        #expect(ns.substring(with: span.content) == "A post")
        #expect(span.kind == .link("https://x.com/a/status/1"))
        #expect(span.hidesCard)
        #expect(LinkTitle.settingCard(hidden.text, at: 6, hidden: false)?.text == titled)
    }

    @Test func aBareAddressHiddenKeepsItsAddressAsItsWords() {
        let hidden = LinkTitle.settingCard("https://x.com/a/status/1", at: 3, hidden: true)!
        #expect(hidden.text == #"[https://x.com/a/status/1](https://x.com/a/status/1 "no card")"#)
        #expect(LinkTitle.settingCard(hidden.text, at: 3, hidden: false)?.text == "https://x.com/a/status/1")
    }

    @Test func retitlingKeepsTheCardHidden() {
        let hidden = #"[Old](https://e.com "no card")"#
        #expect(LinkTitle.retitling(hidden, at: 2, to: "New")?.text == #"[New](https://e.com "no card")"#)
        #expect(LinkTitle.hidesCard(#"[Old](https://e.com "other")"#, at: 2) == false)
    }

    @Test func notOnALink() {
        #expect(LinkTitle.retitling("No link [[Note]] here", at: 10, to: "x") == nil)
    }
}
