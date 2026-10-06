import Foundation
import Testing
@testable import ReflectCore

@Suite struct RichLinkTests {
    @Test func linksAreKnownByShape() {
        #expect(RichLinkKind.of("https://docs.google.com/document/d/abc/edit") == .google(.document))
        #expect(RichLinkKind.of("https://docs.google.com/presentation/d/abc") == .google(.presentation))
        #expect(RichLinkKind.of("https://podcasts.apple.com/us/podcast/the-show/id1234?i=1000567") == .podcast(show: "1234", episode: "1000567"))
        #expect(RichLinkKind.of("https://arxiv.org/pdf/2310.18313v2.pdf") == .paper("2310.18313"))
        #expect(RichLinkKind.of("https://arxiv.org/abs/2310.18313") == .paper("2310.18313"))
        #expect(RichLinkKind.of("https://github.com/rsc/rsc.io/issues/12") == .repository("rsc/rsc.io", 12))
        #expect(RichLinkKind.of("https://github.com/zed-industries/zed") == .repository("zed-industries/zed", nil))
        #expect(RichLinkKind.of("https://www.nytimes.com/2026/10/01/a-story.html") == .article)
        #expect(RichLinkKind.of("https://www.internalfb.com/diff/D123") == nil)
        #expect(RichLinkKind.of("https://nytimes.com/") == nil)
    }

    /// Against the services themselves: `RICH_LINKS_LIVE=1` to run.
    @Test func servicesAnswer() async throws {
        guard ProcessInfo.processInfo.environment["RICH_LINKS_LIVE"] != nil else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rich-\(UUID())")
        for source in ["https://podcasts.apple.com/us/podcast/the-ezra-klein-show/id1548604447",
                       "https://arxiv.org/abs/1706.03762",
                       "https://github.com/zed-industries/zed",
                       "https://github.com/swiftlang/swift/pull/70000",
                       "https://www.theatlantic.com/technology/archive/2024/05/openai-scarlett-johansson-sky/678446/",
                       "https://www.nytimes.com/2026/06/29/well/glp1-drugs-ozempic-longevity.html?smid=nytcore-ios-share",
                       "https://a.co/d/04k88BOb",
                       "https://www.instagram.com/reel/C7rn65jRw7X/?igsh=MWQ1ZGUxMzBkMA==",
                       "https://podcasts.apple.com/us/podcast/keep-talking/id1546657722?i=1000678621505",
                       "https://paulkrugman.substack.com/p/grand-theft-oil-futures"] {
            let card = await RichLinks.load(source, in: folder)
            print("RICH", source, card.map { RichCardFace($0, linkText: nil) }.map { "\($0.service) | \($0.title) | \($0.detail ?? "-") | \($0.facts ?? "-") | \($0.picture)" } ?? "nil")
        }
    }
}
