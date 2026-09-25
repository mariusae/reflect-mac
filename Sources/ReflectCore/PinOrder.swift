import Foundation

/// The order of the pinned shelf, numbered as Reflect numbers it: each
/// pinned note's `pinned:` is a whole number, and they ascend down the
/// shelf. A note moved takes a number between its new neighbours; only when
/// none fits is the whole shelf numbered again, 1024 apart.
public enum PinOrder {
    public static let gap = 1024
    static let lowest = 0
    static let highest = Int(Int32.max)

    /// A pinned note, and its number when it has a usable one.
    public struct Pin: Equatable, Sendable {
        public var path: String
        public var order: Int?

        public init(path: String, order: Int?) {
            self.path = path
            self.order = order
        }
    }

    /// A note's number, when `pinned:` holds one Reflect would use.
    public static func order(_ pin: NoteEntry.Pin?) -> Int? {
        guard case .order(let value) = pin, value == value.rounded(), value >= Double(lowest), value <= Double(highest) else { return nil }
        return Int(value)
    }

    /// Moves the note at one place on the shelf to another, and says which
    /// notes need a new number for it, and what.
    public static func move(_ shelf: [Pin], from: Int, to: Int) -> [Pin] {
        guard shelf.indices.contains(from), shelf.indices.contains(to), from != to else { return [] }
        var moved = shelf
        let note = moved.remove(at: from)
        moved.insert(note, at: to)
        let numbered = renumbered(moved, moving: note.path)
        return zip(numbered, moved).compactMap { new, old in new.order != old.order ? new : nil }
    }

    /// The shelf numbered so that its numbers ascend as its notes sit.
    static func renumbered(_ shelf: [Pin], moving path: String) -> [Pin] {
        if isSorted(shelf) { return shelf }
        guard let at = shelf.firstIndex(where: { $0.path == path }) else { return numberedAfresh(shelf) }
        let before = at > 0 ? shelf[at - 1].order : nil
        let after = at + 1 < shelf.count ? shelf[at + 1].order : nil
        var next = shelf
        if let order = between(before, after) { next[at].order = order }
        return isSorted(next) ? next : numberedAfresh(next)
    }

    static func numberedAfresh(_ shelf: [Pin]) -> [Pin] {
        let step = min(max(highest / (shelf.count + 1), 1), gap)
        return shelf.enumerated().map { Pin(path: $1.path, order: step * ($0 + 1)) }
    }

    static func isSorted(_ shelf: [Pin]) -> Bool {
        var previous: Int?
        for pin in shelf {
            guard let order = pin.order, previous.map({ order > $0 }) ?? true else { return false }
            previous = order
        }
        return true
    }

    /// A whole number strictly between two neighbours, or nil when none fits.
    /// Past the last note it opens a fresh gap rather than jumping halfway
    /// to the top.
    static func between(_ before: Int?, _ after: Int?) -> Int? {
        func valid(_ order: Int) -> Int? { order >= lowest && order <= highest ? order : nil }
        switch (before, after) {
        case (nil, nil): return gap
        case (nil, let after?):
            let result = after / 2
            return result < after ? valid(result) : nil
        case (let before?, nil):
            return valid(before + gap)
        case (let before?, let after?):
            let result = (before + after) / 2
            return before < result && result < after ? valid(result) : nil
        }
    }
}
