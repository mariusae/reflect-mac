import AppKit
import PrismCore

/// Words said, written where the caret is, as they are heard — what was
/// heard so far standing in place, replaced as more comes, and settled
/// once let go. Prism's own notes, typed in: ⌃⌥Space held there. Typed
/// out as it comes, each word lit as it is written, a microphone beside
/// the caret meanwhile.
@MainActor
final class CursorDictation {
    private let view: NSTextView
    private let dictation = Dictation()
    /// Where what is heard stands: at the caret, as long as what is heard so far.
    private var range: NSRange
    /// A space before it, after a word.
    private let lead: String
    /// How much of its line follows it: where it ends is found from this.
    private let tail: Int
    private var typist: DictationTypist!
    private let glow: DictationGlow

    init(view: NSTextView) {
        self.view = view
        range = view.selectedRange()
        let text = view.string as NSString
        let before = range.location > 0 ? text.character(at: range.location - 1) : 32
        lead = before == 32 || before == 10 || before == 9 ? "" : " "
        tail = DictatedSpan.tail(after: range, in: text)
        glow = DictationGlow(on: view)
        typist = DictationTypist { [weak self] heard in self?.show(heard) }
        glow.listen(at: range.location)
    }

    func start(keyterms: [String]) throws {
        try dictation.start(keyterms: keyterms) { [weak self] heard in self?.typist.type(heard) }
    }

    /// Let go: the last of it written down, and put in its place.
    func finish() async {
        typist.flush(await dictation.stop())
        glow.end()
        settle()
        view.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
    }

    /// Given up on: what was put in taken out again.
    func cancel() {
        dictation.cancel()
        typist.flush("")
        glow.end(keepingLight: false)
    }

    /// Where what was said stands now: the text system may have changed it since.
    private func settle() {
        range = DictatedSpan.span(from: range.location, tail: tail, in: view.string as NSString)
    }

    private func show(_ heard: String) {
        settle()
        let text = heard.isEmpty ? "" : lead + heard
        let was = (view.string as NSString).substring(with: range)
        guard text != was else { return }
        view.insertText(text, replacementRange: range)
        settle()
        let same = was.commonPrefix(with: (view.string as NSString).substring(with: range)).utf16.count
        glow.wrote(NSRange(location: range.location + same, length: range.length - same))
        glow.listen(at: NSMaxRange(range))
    }
}
