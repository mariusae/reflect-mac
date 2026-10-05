import Testing
@testable import ReflectCore

struct PostTests {
    @Test func threadsLinks() {
        #expect(Tweet.threadsPath(from: "https://www.threads.com/@keeviniron/post/DeCOyPniFQQ?xmt=abc") == "@keeviniron/post/DeCOyPniFQQ")
        #expect(Tweet.threadsPath(from: "https://www.threads.net/@a/post/XYZ") == "@a/post/XYZ")
        #expect(Tweet.threadsPath(from: "https://www.threads.com/share/BBEEv2YIM6") == "share/BBEEv2YIM6")
        #expect(Tweet.threadsPath(from: "https://www.threads.com/@keeviniron") == nil)
        #expect(Tweet.key(from: "https://x.com/jack/status/20") == "20")
    }

    @Test func threadsEmbed() {
        let html = """
        <div class="AvatarContainer"><img class="img" src="https://cdn.example/a.jpg?x=1&amp;y=2" /></div>\
        <div class="HeaderContainer"><a href="#" class="HeaderLink"><span>keeviniron</span></a></div>\
        <span class="BodyTextContainer"><span>Kind of knew this,<br /> but &amp; more</span></span></span>\
        <div class="LinkAttachmentImage" style="background-image: url(https://cdn.example/p.jpg?a=1&amp;b=2)"></div>\
        <span class="Timestamp">7:04 AM · Oct 3, 2026</span>
        """
        let post = Tweet(threadsEmbed: html, path: "@keeviniron/post/X")
        #expect(post?.user.name == "keeviniron")
        #expect(post?.text == "Kind of knew this,\n but & more")
        #expect(post?.when == "7:04 AM · Oct 3, 2026")
        #expect(post?.user.avatar == "https://cdn.example/a.jpg?x=1&y=2")
        #expect(post?.media?.url == "https://cdn.example/p.jpg?a=1&b=2")
        #expect(post?.site == .threads)
    }
}

struct LinkNoteTests {
    @Test func readsAndHighlights() {
        let page = WebCapture.Page(url: "https://example.com/a", title: "A page", highlights: ["first passage"])
        let note = WebCapture.note(for: page)
        #expect(WebCapture.url(in: note) == "https://example.com/a")
        #expect(WebCapture.highlights(in: note) == ["first passage"])
        let more = WebCapture.highlighting("second  passage", in: note)
        #expect(WebCapture.highlights(in: more) == ["first passage", "second  passage"])
        // Already there: left as it is.
        #expect(WebCapture.highlighting("first passage", in: more) == more)
        #expect(WebCapture.url(in: "# Plain\n\n- words\n") == nil)
    }
}

struct LinkNoteIndentTests {
    @Test func newHighlightsMatchTheirSiblings() {
        let source = "# A\n\n- URL: <https://example.com/>\n- Highlights\n    - first\n"
        let updated = WebCapture.highlighting("second", in: source)
        #expect(updated.contains("    - first\n    - second"))
    }
}
