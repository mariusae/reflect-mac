import SwiftUI
import ReflectCore

@main
struct PrismApp: App {
    @State private var account: GitHubAccount
    @State private var store: PrismStore

    init() {
        Typeface.registerBundled()
        let account = GitHubAccount()
        _account = State(initialValue: account)
        _store = State(initialValue: PrismStore(account: account))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(account)
                .task { await store.load() }
        }
    }
}

struct RootView: View {
    @Environment(PrismStore.self) private var store

    var body: some View {
        if !store.hasGraph {
            ConnectView(appName: "Prism", clone: store.clone)
        } else if store.index == nil {
            ProgressView()
        } else {
            Text("Prism")
                .font(Font(Typeface.current.heading(34)))
                .foregroundStyle(Color(Ink.text))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(Ink.paper))
        }
    }
}
