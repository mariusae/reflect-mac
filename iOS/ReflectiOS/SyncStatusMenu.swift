import SwiftUI

/// How the sync stands — syncing, failed, or when it last went through —
/// and the account it goes through.
struct SyncStatusMenu: View {
    @Environment(GraphStore.self) private var store
    @Environment(GitHubAccount.self) private var account

    var body: some View {
        Menu {
            if let name = store.repositoryName {
                Section(name) {
                    if let error = store.syncError {
                        Text(error)
                    } else if let synced = store.lastSynced {
                        Text("Synced \(synced, format: .relative(presentation: .named))")
                    }
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await store.refresh() }
                    }
                    .disabled(store.isSyncing || !account.isSignedIn)
                }
            }
            if let user = account.user {
                Section("Signed in as \(user.login)") {
                    Button("Sign Out", role: .destructive) { account.signOut() }
                }
            }
        } label: {
            if store.isSyncing {
                ProgressView()
            } else if store.syncError != nil || (store.git != nil && !account.isSignedIn) {
                Image(systemName: "exclamationmark.icloud")
            } else {
                Image(systemName: "checkmark.icloud")
            }
        }
    }
}
