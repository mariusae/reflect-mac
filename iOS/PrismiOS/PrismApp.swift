import SwiftUI
import ReflectCore

@main
struct PrismApp: App {
    @State private var account: GitHubAccount
    @State private var store: PrismStore
    @State private var scheduler: SyncScheduler
    @Environment(\.scenePhase) private var phase

    init() {
        StallWatch.begin()
        _ = Typeface.registration
        let account = GitHubAccount()
        let store = PrismStore(account: account)
        _account = State(initialValue: account)
        _store = State(initialValue: store)
        _scheduler = State(initialValue: SyncScheduler(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView(scheduler: scheduler)
                .environment(store)
                .environment(account)
                .task {
                    await store.load()
                    if UIApplication.shared.applicationState != .background { scheduler.becameActive() }
                }
        }
        .onChange(of: phase) { _, phase in
            switch phase {
            case .active: if store.index != nil { scheduler.becameActive() }
            case .background: scheduler.wentToBackground()
            default: break
            }
        }
    }
}

struct RootView: View {
    @Environment(PrismStore.self) private var store
    let scheduler: SyncScheduler

    var body: some View {
        // The index first: it is what changes once a clone is in. Whether
        // the folder holds a graph is not watched, and alone would leave
        // the connecting screen up after a clone.
        if store.index == nil {
            if store.hasGraph || store.isLoading {
                ProgressView()
            } else {
                ConnectView(appName: "Prism", clone: store.clone)
            }
        } else {
            ColumnsView(store: store, scheduler: scheduler)
                .ignoresSafeArea()
        }
    }
}
