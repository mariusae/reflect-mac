import Foundation
import ReflectCore

/// What a note's frontmatter says of it, to show beside its name: in the
/// inbox, pinned, private, a topic.
public struct NoteFlags: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public static let inbox = NoteFlags(rawValue: 1)
    public static let pinned = NoteFlags(rawValue: 2)
    public static let `private` = NoteFlags(rawValue: 4)
    public static let topic = NoteFlags(rawValue: 8)

    public init(rawValue: Int) { self.rawValue = rawValue }

    /// What a note's frontmatter says of it; `isEmptyTopic`, whether it says
    /// nothing but its title, which makes it a topic too.
    public init(_ entry: NoteEntry?, isEmptyTopic: Bool) {
        var flags: NoteFlags = []
        if entry?.isInInbox == true { flags.insert(.inbox) }
        if entry?.pin != nil { flags.insert(.pinned) }
        if entry?.isPrivate == true { flags.insert(.private) }
        if entry?.isTopic == true || isEmptyTopic { flags.insert(.topic) }
        self = flags
    }

    /// Each flag set, in the order shown: its symbol, what it says, and
    /// how strongly it shows: the inbox, which asks for something, in the
    /// accent; a topic, which says what the note is, in ochre; the rest faint.
    public enum Weight: Sendable { case calling, telling, quiet }

    public var shown: [(symbol: String, label: String, weight: Weight)] {
        var shown: [(String, String, Weight)] = []
        if contains(.inbox) { shown.append(("tray.fill", "In the Inbox", .calling)) }
        if contains(.topic) { shown.append(("number", "Topic: what links here shows under it", .telling)) }
        if contains(.pinned) { shown.append(("pin.fill", "Pinned", .quiet)) }
        if contains(.private) { shown.append(("lock.fill", "Private", .quiet)) }
        return shown
    }
}

