import SwiftUI
import ReflectCore

/// A note: its title, its outline, and the notes that link to it.
struct NoteView: View {
    let path: String
    @Environment(GraphStore.self) private var store
    @State private var backlinks: [BacklinkSource]?

    var body: some View {
        let title = store.title(path)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.largeTitle.weight(.bold))
                let rows = store.text(path).map { NoteBody.rows($0, title: title) } ?? []
                if rows.isEmpty {
                    Text("Nothing written.").foregroundStyle(.tertiary)
                } else {
                    OutlineView(rows: rows)
                }
                if let backlinks, !backlinks.isEmpty {
                    BacklinksSection(sources: backlinks).padding(.top, 24)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.revision) {
            guard let index = store.index else { return }
            let path = path
            backlinks = await Task.detached(priority: .userInitiated) { index.backlinks(to: path) }.value
        }
    }
}

private struct BacklinksSection: View {
    let sources: [BacklinkSource]
    @Environment(GraphStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(sources.count) \(sources.count == 1 ? "Backlink" : "Backlinks")")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(sources, id: \.path) { source in
                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink(value: Route.note(source.path)) {
                        Text(store.title(source.path)).font(.headline)
                    }
                    .buttonStyle(.plain)
                    ForEach(Array(source.contexts.enumerated()), id: \.offset) { _, context in
                        OutlineView(rows: context.rows.map(Self.flattened(context.rows)), compact: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quinary, in: .rect(cornerRadius: 10))
            }
        }
    }

    /// A context's rows moved to start at the left.
    private static func flattened(_ rows: [Row]) -> (Row) -> Row {
        let base = rows.map(\.depth).min() ?? 0
        return { row in
            var row = row
            row.depth -= base
            return row
        }
    }
}
