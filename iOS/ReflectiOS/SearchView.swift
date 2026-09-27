import SwiftUI
import ReflectCore

/// Notes by title and alias, then by what they say.
struct SearchView: View {
    @Environment(GraphStore.self) private var store
    @State private var query = ""
    @State private var titles: [NoteIndex.Match] = []
    @State private var content: [(path: String, snippet: String)] = []

    var body: some View {
        List {
            if !titles.isEmpty {
                Section(query.isEmpty ? "Recent" : "Titles") {
                    ForEach(titles, id: \.entry.path) { NoteRow(entry: $0.entry) }
                }
            }
            if !content.isEmpty {
                Section("Mentions") {
                    ForEach(content, id: \.path) { hit in
                        NavigationLink(value: Route.note(hit.path)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.title(hit.path))
                                Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if !query.isEmpty && titles.isEmpty && content.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Notes and what they say")
        .task(id: query) {
            guard let index = store.index else { return }
            let query = query
            // Typing on: wait a moment before reading every note.
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) {
                (index.matches(query, limit: 30), query.isEmpty ? [] : index.containing(query, limit: 30))
            }.value
            guard !Task.isCancelled else { return }
            titles = found.0
            content = found.1
        }
    }
}
