#if os(iOS)
import UIKit
import PrismCore

/// Words said, written where the caret is, as they are heard — what was
/// heard so far standing in place, replaced as more comes, settled once
/// stopped: the keyboard bar's microphone. Typed out as it comes, each
/// word lit as it is written, a microphone beside the caret meanwhile.
@MainActor
public final class CursorDictation {
    private weak var view: UITextView?
    private let dictation = Dictation()
    /// Where what is heard stands: at the caret, as long as what is heard so far.
    private var range: NSRange
    /// A space before it, after a word.
    private let lead: String
    private var typist: DictationTypist!
    private let glow: DictationGlow

    public init(view: UITextView) {
        self.view = view
        range = view.selectedRange
        let text = view.textStorage.mutableString
        let before = range.location > 0 ? text.character(at: range.location - 1) : 32
        lead = before == 32 || before == 10 || before == 9 || before == 0x2028 ? "" : " "
        glow = DictationGlow(on: view)
        typist = DictationTypist { [weak self] heard in self?.show(heard) }
        glow.listen(at: range.location)
    }

    public func start(keyterms: [String], engine: @escaping (Dictation.Engine) -> Void) throws {
        dictation.onEngine = engine
        try dictation.start(keyterms: keyterms) { [weak self] heard in self?.typist.type(heard) }
    }

    /// Stopped: the last of it written down, and put in its place.
    public func finish() async {
        typist.flush(await dictation.stop())
        glow.end()
        view?.selectedRange = NSRange(location: NSMaxRange(range), length: 0)
    }

    public func cancel() {
        dictation.cancel()
        typist.flush("")
        glow.end(keepingLight: false)
    }

    private func show(_ heard: String) {
        guard let view, NSMaxRange(range) <= view.textStorage.length,
              let start = view.position(from: view.beginningOfDocument, offset: range.location),
              let end = view.position(from: start, offset: range.length),
              let place = view.textRange(from: start, to: end) else { return }
        let text = heard.isEmpty ? "" : lead + heard
        let was = view.textStorage.mutableString.substring(with: range) as NSString
        guard text != was as String else { return }
        view.replace(place, withText: text)
        range = NSRange(location: range.location, length: (text as NSString).length)
        let same = was.commonPrefix(with: text).utf16.count
        glow.wrote(NSRange(location: range.location + same, length: range.length - same))
        glow.listen(at: NSMaxRange(range))
    }
}
#endif
