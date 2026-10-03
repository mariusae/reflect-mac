import AuthenticationServices
import SwiftUI

/// Before there is a graph: sign in to GitHub, choose the repository the
/// notes are kept in, and bring it down. Shared by the apps that show a
/// graph: each says what it is called, and how it brings one down.
struct ConnectView: View {
    /// The app's name, as the page says it.
    let appName: String
    /// Brings a repository down into the app's graph.
    let clone: (GitHubRepository) async throws -> Void
    @Environment(GitHubAccount.self) private var account
    @Environment(\.webAuthenticationSession) private var session

    @State private var repositories: [GitHubRepository]?
    @State private var cloning: GitHubRepository?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if !GitHubApp.isConfigured {
                    ContentUnavailableView("GitHub Is Not Set Up", systemImage: "gearshape",
                                           description: Text("This build has no GitHub App. Its details go in iOS/GitHub.local.xcconfig."))
                } else if let cloning {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Bringing down \(cloning.fullName)…").foregroundStyle(.secondary)
                    }
                } else if !account.isSignedIn {
                    signIn
                } else {
                    choose
                }
            }
            .navigationTitle(appName)
            .toolbar {
                if account.isSignedIn && cloning == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if let user = account.user { Text("Signed in as \(user.login)") }
                            Button("Sign Out", role: .destructive) {
                                account.signOut()
                                repositories = nil
                            }
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                    }
                }
            }
            .alert("Something Went Wrong", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
        .task(id: account.isSignedIn) { await loadRepositories() }
    }

    private var signIn: some View {
        ContentUnavailableView {
            Label("Your Notes, from GitHub", systemImage: "books.vertical")
        } description: {
            Text("\(appName) keeps your graph in a GitHub repository. Sign in, and choose the one it is in.")
        } actions: {
            Button {
                run { try await account.signIn(session) }
            } label: {
                Text("Sign In with GitHub").frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy)
        }
    }

    private var choose: some View {
        List {
            if let repositories {
                Section {
                    ForEach(repositories) { repository in
                        Button {
                            bringDown(repository)
                        } label: {
                            Label {
                                Text(repository.fullName).foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: repository.isPrivate ? "lock" : "book.closed")
                            }
                        }
                    }
                } header: {
                    Text("Choose Your Graph")
                } footer: {
                    Text(repositories.isEmpty
                         ? "\(appName) has not been given any repositories yet."
                         : "The notes come down to this iPhone, and are kept in step with GitHub.")
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            Section {
                Button("Choose Repositories on GitHub…") {
                    run {
                        try await account.chooseRepositories(session)
                        await loadRepositories()
                    }
                }
                .disabled(busy)
            }
        }
        .refreshable { await loadRepositories() }
    }

    private func loadRepositories() async {
        guard account.isSignedIn else { return }
        do {
            repositories = try await account.repositories()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func bringDown(_ repository: GitHubRepository) {
        cloning = repository
        Task {
            do {
                try await clone(repository)
            } catch {
                self.error = error.localizedDescription
            }
            cloning = nil
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            do {
                try await work()
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // Closed by the person: nothing to say.
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
