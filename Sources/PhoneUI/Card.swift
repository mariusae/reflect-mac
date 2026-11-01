#if os(iOS)
import UIKit

/// How a note is set on the phone — shared by the apps that show notes in
/// the outline editor. (Prism's own notes' cards add to it.)
@MainActor
public enum Card {
    /// The page flat, as a magazine's: no cards, the notes on the paper
    /// itself, parted by a hairline and headed by a small line in capitals —
    /// the one way it is set; what links to a note, alone, on cards.
    nonisolated public static let flat = true

    /// The small line in spaced capitals over things, at a text's size: a
    /// day's date, a gap's days, a card's site — one style for them all.
    nonisolated public static func label(size: CGFloat) -> [NSAttributedString.Key: Any] {
        let small = round(size * 0.74)
        return [.font: Typeface.current.body(small, weight: .medium), .foregroundColor: Ink.label, .kern: small * 0.09]
    }
}

extension Notification.Name {
    /// A note changed while read, not typed in: its undo manager and the
    /// change's name, to offer Undo for.
    public static let prismUndoable = Notification.Name("PrismUndoable")
}
#endif
