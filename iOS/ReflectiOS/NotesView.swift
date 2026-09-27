import SwiftUI
import ReflectCore

/// The notes: pinned ones, in Reflect's order; the ones lately written; and
/// the tags.
struct NotesView: View {
    @Environment(GraphStore.self) private var store

    var body: some View {
        let index = store.index
        let pinned = index?.pinned ?? []
        let recent = (index?.all ?? []).filter { $0.day == nil && !$0.path.hasPrefix("templates/") }
            .sorted { $0.modified > $1.modified }.prefix(50)
        let tags = index?.tags ?? []
        List {
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned, id: \.path) { NoteRow(entry: $0) }
                }
            }
            Section("Recent") {
                ForEach(Array(recent), id: \.path) { NoteRow(entry: $0) }
            }
            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags, id: \.name) { tag in
                        NavigationLink(value: Route.tag(tag.name)) {
                            LabeledContent("#" + tag.name, value: "\(tag.count)")
                        }
                    }
                }
            }
        }
        .navigationTitle("Notes")
        .refreshable { await store.refresh() }
    }
}

struct NoteRow: View {
    let entry: NoteEntry

    var body: some View {
        NavigationLink(value: Route.note(entry.path)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.day.map(DayTitle.long) ?? entry.title)
                Text(entry.modified, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct TagView: View {
    let name: String
    @Environment(GraphStore.self) private var store

    var body: some View {
        List(store.index?.notes(tagged: name) ?? [], id: \.path) { NoteRow(entry: $0) }
            .navigationTitle("#" + name)
    }
}
