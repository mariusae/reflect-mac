import Foundation
import ReflectCore

/// The order a query puts pages in, as a river shows them: by priority —
/// the query's high-priority tags first, its low-priority ones last — then
/// by what it sorts by. Each page has its place in that order, which a
/// card put somewhere by hand can be given too: a place between two others,
/// that it keeps as other pages come and go.
extension Query {
    /// Where a page goes: its priority's rank, then its sort key — a date,
    /// written so that its letters sort as it does, or a title.
    public struct Place: Hashable, Sendable {
        public var rank: Int
        public var key: String

        public init(rank: Int, key: String) {
            self.rank = rank
            self.key = key
        }
    }

    /// The rank of those with no priority, between the high and the low.
    static let normalRank = 1000

    /// Whether a page at `a` comes before one at `b`.
    public func precedes(_ a: Place, _ b: Place) -> Bool {
        if a.rank != b.rank { return a.rank < b.rank }
        if a.key != b.key { return descending ? a.key > b.key : a.key < b.key }
        return false
    }

    /// Where a page goes in the query's order.
    public func place(of title: String, in index: PageIndex) -> Place {
        Place(rank: rank(of: title, in: index), key: key(of: title, in: index))
    }

    /// The pages the query finds, in its order, each with its place.
    public func ordered(in index: PageIndex, this: String = "") -> [(title: String, place: Place)] {
        var found = matching(in: index, this: this).map { (title: $0, place: place(of: $0, in: index)) }
        found.sort { a, b in
            if precedes(a.place, b.place) { return true }
            if precedes(b.place, a.place) { return false }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        if let limit { found = Array(found.prefix(max(0, limit))) }
        return found
    }

    /// A place between two others — a card dropped there — that stays
    /// between them as long as nothing comes between them: a date halfway
    /// between theirs; at an end, a moment beyond the last.
    public func place(between above: Place?, and below: Place?) -> Place {
        let rank = above?.rank ?? below?.rank ?? Self.normalRank
        switch sort {
        case .created, .modified:
            let a = above.flatMap { $0.rank == rank ? Self.date($0.key) : nil }
            let b = below.flatMap { $0.rank == rank ? Self.date($0.key) : nil }
            // A moment further along the order than the one beside it.
            let step: TimeInterval = descending ? -1 : 1
            let date: Date
            switch (a, b) {
            case let (a?, b?): date = Date(timeIntervalSince1970: (a.timeIntervalSince1970 + b.timeIntervalSince1970) / 2)
            case let (a?, nil): date = a.addingTimeInterval(step)
            case let (nil, b?): date = b.addingTimeInterval(-step)
            case (nil, nil): date = Date()
            }
            return Place(rank: rank, key: Self.dateKey(date))
        default:
            // Just after the one above — its title, a space more.
            if let above, above.rank == rank { return Place(rank: rank, key: descending ? above.key : above.key + " ") }
            return Place(rank: rank, key: below?.key ?? "")
        }
    }

    // MARK: Ranks and keys

    private func rank(of title: String, in index: PageIndex) -> Int {
        guard !highPriority.isEmpty || !lowPriority.isEmpty else { return Self.normalRank }
        let own = Set(index.tags(of: title).map { $0.lowercased() })
        if let at = highPriority.firstIndex(where: { own.contains($0.lowercased()) }) {
            return priorityMode == .ranked ? at : 0
        }
        if let at = lowPriority.firstIndex(where: { own.contains($0.lowercased()) }) {
            return Self.normalRank + 1 + (priorityMode == .ranked ? at : 0)
        }
        return Self.normalRank
    }

    private func key(of title: String, in index: PageIndex) -> String {
        switch sort {
        case .created, .modified:
            let entry = index.entries[title]
            guard let date = sort == .created ? entry?.page.created : entry?.modified else { return "" }
            return Self.dateKey(date)
        default:
            return title.lowercased()
        }
    }

    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// A date as a key whose letters sort as the dates do.
    static func dateKey(_ date: Date) -> String { date.formatted(dateStyle) }

    static func date(_ key: String) -> Date? { try? dateStyle.parse(key) }
}
