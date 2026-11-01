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
    private var typist: DictationTypist!
    private let glow: DictationGlow

    init(view: NSTextView) {
        self.view = view
        range = view.selectedRange()
        let text = view.string as NSString
        let before = range.location > 0 ? text.character(at: range.location - 1) : 32
        lead = before == 32 || before == 10 || before == 9 ? "" : " "
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
        view.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
    }

    /// Given up on: what was put in taken out again.
    func cancel() {
        dictation.cancel()
        typist.flush("")
        glow.end(keepingLight: false)
    }

    private func show(_ heard: String) {
        let text = heard.isEmpty ? "" : lead + heard
        let was = (view.string as NSString).substring(with: range)
        guard text != was else { return }
        view.insertText(text, replacementRange: range)
        range = NSRange(location: range.location, length: (text as NSString).length)
        let same = was.commonPrefix(with: text).utf16.count
        glow.wrote(NSRange(location: range.location + same, length: range.length - same))
        glow.listen(at: NSMaxRange(range))
    }
}
