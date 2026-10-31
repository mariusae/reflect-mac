import UIKit
import PrismCore

/// Words said, written where the caret is, as they are heard — what was
/// heard so far standing in place, replaced as more comes, settled once
/// stopped: the keyboard bar's microphone.
@MainActor
final class CursorDictation {
    private weak var view: UITextView?
    private let dictation = Dictation()
    /// Where what is heard stands: at the caret, as long as what is heard so far.
    private var range: NSRange
    /// A space before it, after a word.
    private let lead: String

    init(view: UITextView) {
        self.view = view
        range = view.selectedRange
        let text = view.textStorage.mutableString
        let before = range.location > 0 ? text.character(at: range.location - 1) : 32
        lead = before == 32 || before == 10 || before == 9 || before == 0x2028 ? "" : " "
    }

    func start(keyterms: [String], engine: @escaping (Dictation.Engine) -> Void) throws {
        dictation.onEngine = engine
        try dictation.start(keyterms: keyterms) { [weak self] heard in self?.show(heard) }
    }

    /// Stopped: the last of it written down, and put in its place.
    func finish() async {
        show(await dictation.stop())
        view?.selectedRange = NSRange(location: NSMaxRange(range), length: 0)
    }

    func cancel() {
        dictation.cancel()
        show("")
    }

    private func show(_ heard: String) {
        guard let view, NSMaxRange(range) <= view.textStorage.length,
              let start = view.position(from: view.beginningOfDocument, offset: range.location),
              let end = view.position(from: start, offset: range.length),
              let place = view.textRange(from: start, to: end) else { return }
        let text = heard.isEmpty ? "" : lead + heard
        guard text != view.textStorage.mutableString.substring(with: range) else { return }
        view.replace(place, withText: text)
        range = NSRange(location: range.location, length: (text as NSString).length)
    }
}
