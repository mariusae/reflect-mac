import SwiftUI
import ReflectCore

@main
struct ReflectApp: App {
    @State private var account: GitHubAccount
    @State private var store: GraphStore
    @Environment(\.scenePhase) private var phase

    init() {
        let account = GitHubAccount()
        _account = State(initialValue: account)
        _store = State(initialValue: GraphStore(account: account))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(account)
                .task { await store.load() }
        }
        // Coming back to the app: whatever other devices wrote since.
        .onChange(of: phase) { _, phase in
            if phase == .active { Task { await store.sync() } }
        }
    }
}

struct RootView: View {
    @Environment(GraphStore.self) private var store

    var body: some View {
        if !store.hasGraph {
            ConnectView()
        } else if store.index == nil {
            ProgressView()
        } else {
            TabView {
                Tab("Today", systemImage: "calendar") {
                    NoteStack { TimelineView() }
                }
                Tab("Notes", systemImage: "note.text") {
                    NoteStack { NotesView() }
                }
                Tab("Tasks", systemImage: "checklist") {
                    NoteStack { TasksView() }
                }
                Tab(role: .search) {
                    NoteStack { SearchView() }
                }
            }
            .tabViewStyle(.sidebarAdaptable)
        }
    }
}
