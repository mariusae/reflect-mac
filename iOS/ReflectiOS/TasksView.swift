import SwiftUI
import ReflectCore

/// Every open task in the graph, grouped as Reflect's Tasks view groups
/// them: Current, Overdue, Upcoming, then by note.
struct TasksView: View {
    @Environment(GraphStore.self) private var store
    @State private var groups: [TaskGroup] = []

    var body: some View {
        List {
            ForEach(groups, id: \.key) { group in
                Section {
                    ForEach(group.tasks, id: \.id) { task in
                        TaskRow(task: task, showsNote: group.kind != .note)
                    }
                } header: {
                    if let path = group.notePath {
                        NavigationLink(value: Route.note(path)) { Text(group.label) }
                    } else {
                        Text(group.label)
                    }
                }
            }
        }
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView("No Tasks", systemImage: "checklist",
                                       description: Text("Tasks — `+ [ ]` — from every note gather here."))
            }
        }
        .navigationTitle("Tasks")
        .refreshable { await store.refresh() }
        .task(id: store.revision) {
            guard let index = store.index else { return }
            groups = await Task.detached(priority: .userInitiated) {
                Tasks.group(index.tasks(), today: Day.today)
            }.value
        }
    }
}

extension NoteTask {
    /// Which task it is, among every note's.
    var id: String { "\(notePath)#\(ordinal)" }
}

private struct TaskRow: View {
    let task: NoteTask
    let showsNote: Bool

    var body: some View {
        NavigationLink(value: Route.note(task.notePath)) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 3) {
                    Text(InlineText.render(task.text).text)
                    let crumbs = Tasks.visibleBreadcrumbs(task.breadcrumbs)
                    let context = (showsNote ? [task.day.map(DayTitle.long) ?? task.noteTitle] : []) + crumbs
                    if !context.isEmpty {
                        Text(context.joined(separator: " › "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

extension TaskGroup {
    /// Which group it is: two notes may share a title.
    var key: String { notePath ?? label }
}
