import Foundation
import Testing
import ReflectCore

@Suite struct TemplatesTests {
    @Test func aTemplatesRowsFilledInWithoutItsTitle() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9, minute: 5))!
        let source = "---\ntemplate: true\n---\n# Meeting\n\n- {{day}} {{time}}, on {{date}}\n  - Agenda\n- Actions\n"
        let rows = Templates.rows(of: source, at: date, calendar: calendar)
        #expect(rows.map(\.text) == ["Friday 09:05, on [[2026-10-30]]", "Agenda", "Actions"])
        #expect(rows.first?.gap.isEmpty == true)
    }

    @Test func templatesAreListed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\ntemplate: true\n---\n# Meeting\n".write(to: root.appendingPathComponent("notes/meeting.md"), atomically: true, encoding: .utf8)
        try "# Plans\n".write(to: root.appendingPathComponent("notes/plans.md"), atomically: true, encoding: .utf8)
        let index = NoteIndex(root: root)
        index.scan()
        #expect(index.templates.map(\.title) == ["Meeting"])
    }
}
