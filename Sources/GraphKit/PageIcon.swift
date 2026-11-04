import Foundation
import ReflectCore

/// A page's own icon: an SF Symbol's name in its frontmatter, `icon: leaf`,
/// shown where a day shows its calendar — before its title, and in links to
/// it. Any symbol's name will do; these are the ones offered, by name, in
/// groups, to choose among.
public enum PageIcon {
    /// The frontmatter field it is kept in.
    public static let key = "icon"

    public struct Choice: Hashable, Sendable, Identifiable {
        public let name: String
        public let symbol: String
        public var id: String { symbol }

        public init(name: String, symbol: String) {
            self.name = name
            self.symbol = symbol
        }
    }

    public struct Group: Hashable, Sendable, Identifiable {
        public let name: String
        public let choices: [Choice]
        public var id: String { name }

        public init(name: String, choices: [Choice]) {
            self.name = name
            self.choices = choices
        }
    }

    private static func group(_ name: String, _ choices: [(String, String)]) -> Group {
        Group(name: name, choices: choices.map { Choice(name: $0.0, symbol: $0.1) })
    }

    /// What is offered, in groups.
    public static let groups: [Group] = [
        group("Marks", [
            ("Star", "star"), ("Flag", "flag"), ("Bookmark", "bookmark"), ("Pin", "pin"), ("Bolt", "bolt"),
            ("Sparkles", "sparkles"), ("Target", "target"), ("Seal", "checkmark.seal"), ("Question", "questionmark.circle"),
            ("Warning", "exclamationmark.triangle"), ("Key", "key"), ("Lock", "lock"), ("Shield", "shield"),
        ]),
        group("Work", [
            ("Lightbulb", "lightbulb"), ("Briefcase", "briefcase"), ("Folder", "folder"), ("Tray", "tray"),
            ("Archive", "archivebox"), ("Document", "doc.text"), ("Clipboard", "list.clipboard"), ("Chart", "chart.bar"),
            ("Trend", "chart.line.uptrend.xyaxis"), ("Money", "dollarsign.circle"), ("Megaphone", "megaphone"),
            ("Puzzle", "puzzlepiece"), ("Clock", "clock"), ("Hourglass", "hourglass"),
        ]),
        group("Making", [
            ("Code", "chevron.left.forwardslash.chevron.right"), ("Terminal", "terminal"), ("Gear", "gearshape"),
            ("Hammer", "hammer"), ("Tools", "wrench.and.screwdriver"), ("Pencil", "pencil"), ("Brush", "paintbrush"),
            ("Palette", "paintpalette"), ("Cube", "cube"), ("Flask", "flask"), ("Atom", "atom"), ("Brain", "brain"),
        ]),
        group("Reading", [
            ("Book", "book"), ("Books", "books.vertical"), ("Newspaper", "newspaper"), ("Quote", "quote.bubble"),
            ("Graduation", "graduationcap"), ("Glasses", "eyeglasses"),
        ]),
        group("People", [
            ("Person", "person"), ("People", "person.2"), ("Family", "figure.2.and.child.holdinghands"),
            ("Conversation", "bubble.left.and.bubble.right"), ("Mail", "envelope"), ("Phone", "phone"), ("Heart", "heart"),
        ]),
        group("Places", [
            ("House", "house"), ("Building", "building.2"), ("Map", "map"), ("Globe", "globe"), ("Airplane", "airplane"),
            ("Car", "car"), ("Tent", "tent"), ("Mountain", "mountain.2"),
        ]),
        group("Life", [
            ("Health", "cross.case"), ("Dumbbell", "dumbbell"), ("Running", "figure.run"), ("Food", "fork.knife"),
            ("Coffee", "cup.and.saucer"), ("Cart", "cart"), ("Gift", "gift"), ("Music", "music.note"), ("Film", "film"),
            ("Camera", "camera"), ("Game", "gamecontroller"), ("Ticket", "ticket"),
        ]),
        group("Nature", [
            ("Leaf", "leaf"), ("Tree", "tree"), ("Sun", "sun.max"), ("Moon", "moon"), ("Cloud", "cloud"),
            ("Flame", "flame"), ("Drop", "drop"), ("Snowflake", "snowflake"), ("Paw", "pawprint"), ("Bird", "bird"),
        ]),
    ]

    /// Every choice, in the order offered.
    public static let all: [Choice] = groups.flatMap(\.choices)

    /// What a symbol is called among the choices — or, another, its own name.
    public static func name(of symbol: String) -> String {
        all.first { $0.symbol == symbol }?.name ?? symbol
    }

    /// A page's icon, as its frontmatter has it: nil for none.
    public static func symbol(of page: Page) -> String? {
        let value: String? = switch page[field: key] {
        case .text(let text): text
        case .list(let items): items.first
        case nil: nil
        }
        let symbol = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return symbol.isEmpty ? nil : symbol
    }
}
