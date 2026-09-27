import SwiftUI
import ReflectCore

/// The days, today first and on back: each day's note in full, as the Mac's
/// timeline has them.
struct TimelineView: View {
    @Environment(GraphStore.self) private var store

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 36) {
                ForEach(store.days, id: \.self) { day in
                    DaySection(day: day)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SyncStatusMenu() }
        }
        .refreshable { await store.refresh() }
    }
}

private struct DaySection: View {
    let day: Day
    @Environment(GraphStore.self) private var store

    var body: some View {
        let path = GraphPaths.dailyPath(for: day)
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: Route.note(path)) {
                HStack(alignment: .firstTextBaseline) {
                    Text(DayTitle.relative(day)).font(.title2.weight(.bold))
                    if day == Day.today || day == Day.today.adding(-1) {
                        Text(DayTitle.long(day)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            let rows = store.text(path).map { NoteBody.rows($0, title: nil) } ?? []
            if rows.isEmpty {
                Text("Nothing written.").foregroundStyle(.tertiary)
            } else {
                OutlineView(rows: rows)
            }
        }
    }
}

enum NoteBody {
    /// A note's rows to show: all of them, unfolded, less a first heading
    /// that only repeats the title shown above it.
    static func rows(_ text: String, title: String?) -> [Row] {
        var rows = OutlineMarkdown.parse(text).unfoldedRows
        if let title, let first = rows.first, first.kind == .heading(1),
           InlineMarkup.plainText(first.text) == title {
            rows.removeFirst()
        }
        return rows.filter { !($0.kind == .paragraph && $0.text.trimmingCharacters(in: .whitespaces).isEmpty) }
    }
}
