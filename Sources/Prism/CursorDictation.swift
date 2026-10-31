import AppKit
import PrismCore

/// Words said, written where the caret is, as they are heard — what was
/// heard so far standing in place, replaced as more comes, and settled
/// once let go. Prism's own notes, typed in: ⌃⌥Space held there.
@MainActor
final class CursorDictation {
    private let view: NSTextView
    private let dictation = Dictation()
    /// Where what is heard stands: at the caret, as long as what is heard so far.
    private var range: NSRange
    /// A space before it, after a word.
    private let lead: String

    init(view: NSTextView) {
        self.view = view
        range = view.selectedRange()
        let text = view.string as NSString
        let before = range.location > 0 ? text.character(at: range.location - 1) : 32
        lead = before == 32 || before == 10 || before == 9 ? "" : " "
    }

    func start(keyterms: [String]) throws {
        try dictation.start(keyterms: keyterms) { [weak self] heard in self?.show(heard) }
    }

    /// Let go: the last of it written down, and put in its place.
    func finish() async {
        show(await dictation.stop())
        view.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
    }

    /// Given up on: what was put in taken out again.
    func cancel() {
        dictation.cancel()
        show("")
    }

    private func show(_ heard: String) {
        let text = heard.isEmpty ? "" : lead + heard
        guard text != (view.string as NSString).substring(with: range) else { return }
        view.insertText(text, replacementRange: range)
        range = NSRange(location: range.location, length: (text as NSString).length)
    }
}
