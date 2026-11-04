#if os(iOS)
import Testing
import UIKit
import ReflectCore
@testable import PhoneUI

/// The height kept as the note is typed in: what it would be measured
/// afresh, however the typing went.
@MainActor
struct EditorHeightTests {
    static let note = """
    - 2026-10-31
      - Think first it's super important to identify what the goal is.
      - I do worry about AI's effect on our thinking for ourselves. That's another leg that democracy rests on that is being eroded over time.
    - @today[
    - [[Dario Amodei — Machines of Loving Grace]]
    """

    private func editor(_ markdown: String, window: UIWindow) -> OutlineEditor {
        let editor = OutlineEditor(metrics: PhoneMetrics())
        editor.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        window.addSubview(editor)
        editor.load(OutlineMarkdown.parse(markdown).rows)
        return editor
    }

    private func fresh(_ text: String, window: UIWindow) -> CGFloat {
        let other = OutlineEditor(metrics: PhoneMetrics())
        other.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        window.addSubview(other)
        other.load(OutlineMarkdown.parse(text).rows)
        defer { other.removeFromSuperview() }
        return other.rowsHeight(width: 390)
    }

    @Test(arguments: [false, true]) func deletingAtARowsEndKeepsTheHeight(builtAhead: Bool) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.makeKeyAndVisible()
        let editor: OutlineEditor
        if builtAhead {
            // As a sheet has it: built off the main thread, then put in.
            editor = OutlineEditor(metrics: PhoneMetrics())
            editor.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
            window.addSubview(editor)
            editor.install(OutlineEditor.prepare(OutlineMarkdown.parse(Self.note).rows, metrics: PhoneMetrics(), width: 390))
        } else {
            editor = self.editor(Self.note, window: window)
        }
        _ = editor.fittingHeight(width: 390)
        _ = editor.becomeFirstResponder()
        let found = (editor.text as NSString).range(of: "@today[")
        let end = NSMaxRange(found)
        editor.selectedRange = NSRange(location: end, length: 0)
        // As a tap has it: the row the caret is put in, restyled for it.
        editor.textViewDidChangeSelection(editor)
        for _ in 0..<4 {
            editor.deleteBackward()
            let markdown = OutlineMarkdown.serialize(Outline(rows: editor.rows))
            #expect(abs(editor.rowsHeight(width: 390) - fresh(markdown, window: window)) < 1, "after deleting, at \(editor.text.debugDescription)")
        }
    }
}
#endif
