import SwiftUI
import ReflectCore
import ReflectGit2

/// Prism Reader: the inbox's links, read one at a time — the oldest first,
/// and nothing else. The graph is its own clone of the same repository,
/// synced as Prism's is.
@main
struct PrismReaderApp: App {
    @UIApplicationDelegateAdaptor(PrismReaderDelegate.self) private var delegate
    @State private var account: GitHubAccount
    @State private var store: PrismStore
    @State private var scheduler: SyncScheduler
    @Environment(\.scenePhase) private var phase

    init() {
        _ = Typeface.registration
        let account = GitHubAccount()
        let store = PrismStore(account: account)
        _account = State(initialValue: account)
        _store = State(initialValue: store)
        _scheduler = State(initialValue: SyncScheduler(store: store))
        PushRelay.shared.store = store
        PushRelay.shared.account = account
    }

    var body: some Scene {
        WindowGroup {
            ReaderRootView(phase: phase)
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

struct ReaderRootView: View {
    @Environment(PrismStore.self) private var store
    let phase: ScenePhase

    var body: some View {
        if store.index == nil {
            if store.hasGraph || store.isLoading {
                ProgressView()
            } else {
                ConnectView(appName: "Prism Reader", clone: store.clone)
            }
        } else {
            QueueView(store: store, revision: store.revision, active: phase == .active)
                .ignoresSafeArea()
        }
    }
}

/// The queue, followed: the notes changed, or the app come back to — a
/// snoozed link may be due.
struct QueueView: UIViewControllerRepresentable {
    let store: PrismStore
    let revision: Int
    let active: Bool

    func makeUIViewController(context: Context) -> QueueController { QueueController(store: store) }

    func updateUIViewController(_ controller: QueueController, context: Context) {
        if active { controller.refresh() }
    }
}

final class PrismReaderDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Scroll bars that read on the dark paper too.
        UIScrollView.followPaper()
        return true
    }
}
