import EventKit
import ReflectCore

/// A day's meetings, from the calendars on the device: each its name, its
/// times, and who is in it — asked for once, and only when wanted.
@MainActor
public final class CalendarEvents {
    public struct Event: Equatable, Sendable {
        public let id: String
        public let title: String
        public let start: Date
        public let end: Date
        /// Who is in it, by name — the one whose calendar it is left out.
        public let people: [String]
    }

    public static let shared = CalendarEvents()
    private let store = EKEventStore()

    /// Allowed to read the calendars.
    public var isAllowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    /// Not asked yet: a button to ask, where the events would be.
    public var canAsk: Bool { EKEventStore.authorizationStatus(for: .event) == .notDetermined }

    /// Asks to read the calendars: whether it may.
    public func ask() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// The day's meetings with a time, in order — not those declined, nor
    /// the whole day's.
    public func events(on day: Day) -> [Event] {
        guard isAllowed, let start = day.date, let end = day.adding(1).date else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled && !Self.declined($0) }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                Event(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Meeting", start: event.startDate,
                      end: event.endDate,
                      people: (event.attendees ?? []).filter { !$0.isCurrentUser && $0.participantType == .person }.compactMap(\.name))
            }
    }

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }
}
