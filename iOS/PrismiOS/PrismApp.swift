import SwiftUI
import ReflectCore

@main
struct PrismApp: App {
    @State private var account: GitHubAccount
    @State private var store: PrismStore
    @State private var scheduler: SyncScheduler
    @Environment(\.scenePhase) private var phase

    init() {
        Typeface.registerBundled()
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
        if !store.hasGraph {
            ConnectView(appName: "Prism", clone: store.clone)
        } else if store.index == nil {
            ProgressView()
        } else {
            ColumnsView(store: store, scheduler: scheduler)
                .ignoresSafeArea()
        }
    }
}
