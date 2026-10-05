import Testing
@testable import PrismCore

@Suite struct NoteSummaryTests {
    @Test func headlineSnippetAndPicture() {
        let source = """
        # Trip notes
        - Flew to **Oslo**, met [[Kari]]
        - ![](assets/fjord.jpg)
        - Dinner at the [harbour](https://example.com)
        """
        let summary = NoteSummary.of(source, title: "Trip notes")
        #expect(summary.headline == "Flew to Oslo, met Kari")
        #expect(summary.snippet == "Dinner at the harbour")
        #expect(summary.picture == "assets/fjord.jpg")
    }

    @Test func longSnippetIsShortened() {
        let source = (0..<40).map { "- row number \($0) with some words in it" }.joined(separator: "\n")
        let summary = NoteSummary.of(source, title: nil, length: 100)
        #expect(summary.headline == "row number 0 with some words in it")
        #expect(summary.snippet.count <= 101)
        #expect(summary.snippet.hasSuffix("…"))
    }
}
