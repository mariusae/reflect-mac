import Testing
@testable import PrismCore

struct PaneHistoryTests {
    let a = PanePlace(path: "notes/a.md"), b = PanePlace(path: "notes/b.md"), c = PanePlace(path: "notes/c.md")

    @Test func backAndForward() {
        var history = PaneHistory(a)
        history.go(b)
        history.go(c)
        #expect(history.goBack() == b)
        #expect(history.goBack() == a)
        #expect(history.goBack() == nil)
        #expect(history.goForward() == b)
        // Somewhere new: the way forward forgotten.
        history.go(a)
        #expect(!history.canGoForward)
        #expect(history.back == [a, b])
    }

    @Test func sameNoteIsNotASteps() {
        var history = PaneHistory(a)
        history.go(a)
        #expect(!history.canGoBack)
    }

    @Test func replaceLeavesNoWayBack() {
        var history = PaneHistory(a)
        history.replace(PanePlace(path: a.path, face: .schedule))
        #expect(!history.canGoBack)
        #expect(history.current.face == .schedule)
    }

    @Test func forgetsAndRenames() {
        var history = PaneHistory(a)
        history.go(b)
        history.go(c)
        history.rename(b.path, to: "notes/bee.md")
        #expect(history.back.map(\.path) == [a.path, "notes/bee.md"])
        history.forget(a.path)
        #expect(history.back.map(\.path) == ["notes/bee.md"])
    }
}
