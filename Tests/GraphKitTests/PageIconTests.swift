import AppKit
import Foundation
import Testing
@testable import GraphKit

@Suite struct PageIconTests {
    /// Every icon offered is a symbol there is, offered once, with a name.
    @Test func everyChoiceIsASymbol() {
        let symbols = PageIcon.all.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
        for choice in PageIcon.all {
            #expect(NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil) != nil, "\(choice.symbol)")
            #expect(!choice.name.isEmpty)
        }
        #expect(PageIcon.name(of: "leaf") == "Leaf")
        #expect(PageIcon.name(of: "custom.symbol") == "custom.symbol")
    }

    /// Kept in the frontmatter as `icon:`; none, when it is empty.
    @Test func readFromItsFrontmatter() {
        #expect(PageIcon.symbol(of: PageFile.read("---\nicon: leaf\n---\nWords\n", fallbackTitle: "x")) == "leaf")
        #expect(PageIcon.symbol(of: PageFile.read("---\nicon: \"\"\n---\nWords\n", fallbackTitle: "x")) == nil)
        #expect(PageIcon.symbol(of: PageFile.read("Words\n", fallbackTitle: "x")) == nil)
        var page = PageFile.read("Words\n", fallbackTitle: "x")
        page[field: PageIcon.key] = .text("star")
        #expect(PageFile.write(page, over: "Words\n", fallbackTitle: "x") == "---\nicon: star\n---\nWords\n")
    }
}
