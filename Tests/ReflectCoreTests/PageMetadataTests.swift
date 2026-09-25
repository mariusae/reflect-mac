import Foundation
import Testing
@testable import ReflectCore

@Suite struct PageMetadataTests {
    let url = URL(string: "https://example.com/a/b?c=1")!

    @Test func prefersOpenGraph() {
        let html = """
            <html><head><title>Plain  Title</title>
            <meta property="og:title" content="The &amp; Graph Title">
            <meta name="description" content="Plain description">
            <meta property='og:description' content='OG &#8212; description'>
            <link rel="apple-touch-icon" href="/touch.png"><link rel="icon" type="image/svg+xml" href="/i.svg">
            </head></html>
            """
        let meta = PageMetadata.parse(html: html, url: url)
        #expect(meta?.title == "The & Graph Title")
        #expect(meta?.description == "OG — description")
        #expect(meta?.iconURL?.absoluteString == "https://example.com/touch.png")
    }

    @Test func fallsBackToTheTitleTagAndFavicon() {
        let meta = PageMetadata.parse(html: "<TITLE>\n  A   page\n</TITLE>", url: url)
        #expect(meta?.title == "A page")
        #expect(meta?.description == nil)
        #expect(meta?.iconURL?.absoluteString == "https://example.com/favicon.ico")
    }

    @Test func noTitleNoCard() {
        #expect(PageMetadata.parse(html: "<html><body>hi</body></html>", url: url) == nil)
    }
}
