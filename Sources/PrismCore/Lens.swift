import Foundation
import ReflectCore

/// Prism's whole shape, on the Mac and the phone alike: notes — outlines,
/// each with a title — linked to one another, gathered by a few lenses.
/// A lens is a list that leads to a note: the days, the inbox, the tasks,
/// the pinned, what is found. Picked from the rail, on the Mac; from the
/// bar at the foot, on the phone.
public enum Lens: String, CaseIterable, Codable, Sendable {
    case daily, inbox, tasks, pinned, search

    public var title: String {
        switch self {
        case .daily: "Daily"
        case .inbox: "Inbox"
        case .tasks: "Tasks"
        case .pinned: "Pinned"
        case .search: "Search"
        }
    }

    /// Its SF Symbol.
    public var symbol: String {
        switch self {
        case .daily: "sun.max"
        case .inbox: "tray"
        case .tasks: "checklist"
        case .pinned: "pin"
        case .search: "magnifyingglass"
        }
    }

    /// Its key, with ⌘, on the Mac: in the rail's order.
    public var key: String {
        switch self {
        case .daily: "1"
        case .inbox: "2"
        case .tasks: "3"
        case .pinned: "4"
        case .search: "5"
        }
    }
}

/// A day has two faces: its note as written, or its hours, its time
/// blocks down them.
public enum DayFace: String, Codable, Sendable {
    case outline, schedule
}

/// Where a note pane is: a note, and — a day's — which face of it.
public struct PanePlace: Hashable, Codable, Sendable {
    public var path: String
    public var face: DayFace

    public init(path: String, face: DayFace = .outline) {
        self.path = path
        self.face = face
    }

    public init(_ ref: NoteRef, face: DayFace = .outline) {
        self.init(path: ref.path, face: face)
    }

    public var ref: NoteRef { NoteRef(path: path) }
}

/// A note pane's way back and forward, as a browser tab's: going somewhere
/// new puts where it was behind it, and forgets the way forward.
public struct PaneHistory: Codable, Sendable, Equatable {
    public private(set) var back: [PanePlace] = []
    public private(set) var current: PanePlace
    public private(set) var forward: [PanePlace] = []
    /// How far back is kept.
    public static let depth = 50

    public init(_ current: PanePlace) { self.current = current }

    /// Somewhere new — nowhere, if it is where it is.
    public mutating func go(_ place: PanePlace) {
        guard place != current else { return }
        back.append(current)
        if back.count > Self.depth { back.removeFirst(back.count - Self.depth) }
        current = place
        forward = []
    }

    /// Where it is changed in place — another face of the same day, a day
    /// stepped along in the week — without a way back to it.
    public mutating func replace(_ place: PanePlace) { current = place }

    @discardableResult
    public mutating func goBack() -> PanePlace? {
        guard let last = back.popLast() else { return nil }
        forward.insert(current, at: 0)
        current = last
        return last
    }

    @discardableResult
    public mutating func goForward() -> PanePlace? {
        guard !forward.isEmpty else { return nil }
        back.append(current)
        current = forward.removeFirst()
        return current
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// A note gone — trashed, renamed — out of the way back and forward.
    public mutating func forget(_ path: String) {
        back.removeAll { $0.path == path }
        forward.removeAll { $0.path == path }
    }

    /// A note moved, wherever it is in the history.
    public mutating func rename(_ path: String, to new: String) {
        func moved(_ place: PanePlace) -> PanePlace { place.path == path ? PanePlace(path: new, face: place.face) : place }
        back = back.map(moved)
        forward = forward.map(moved)
        current = moved(current)
    }
}
