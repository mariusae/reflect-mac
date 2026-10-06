import AppKit
import AuthenticationServices
import ReflectCore
import ReflectGit2
import SwiftUI

/// Prism's own graph: a clone of the GitHub repository the notes are kept
/// in, in Prism's own folder, synced with the GitHub account it signed in
/// with — as the phone does — and never the checkout another app keeps in
/// step. Two apps syncing one checkout got in each other's way.
@MainActor
enum GitHubGraph {
    /// The account, shared by the window that signs in and the sync.
    static let account = GitHubAccount()

    /// Where the clone is.
    static let root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Prism", isDirectory: true).appendingPathComponent("Graph", isDirectory: true)

    /// Whether there is a clone to open.
    static var exists: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
    }

    /// The repository the clone is of, as GitHub names it.
    static var repositoryName: String? {
        get { UserDefaults.standard.string(forKey: "GitHubRepository") }
        set { UserDefaults.standard.set(newValue, forKey: "GitHubRepository") }
    }

    /// The clone, synced through libgit2 with the account's token: nothing
    /// of the Mac's own git, its credentials or its configuration, needed.
    static func graph() -> Graph {
        guard let backend = LibGit2Backend(root: root) else { return Graph(root: root, git: nil) }
        let token = account.currentToken
        backend.credentials = { token.credentials }
        if let user = account.user { backend.identity = user.identity }
        return Graph(root: root, git: Git(backend: backend))
    }

    /// Before each sync: the token good for a while yet.
    static func prepare() async throws {
        guard account.isSignedIn else { throw GitHubError("Signed out of GitHub. Choose Graph ▸ GitHub Account… to sign in again.") }
        _ = try await account.validAccessToken()
    }

    /// Brings a repository down — all of it: the Mac has the room — into
    /// Prism's folder.
    static func clone(_ repository: GitHubRepository) async throws {
        try await GraphClone.clone(repository, account: account, into: root, depth: 0)
        repositoryName = repository.fullName
    }
}

/// The window to sign in to GitHub and choose the graph in: on the first
/// launch, and from Graph ▸ GitHub Account….
@MainActor
final class GitHubWindowController: NSWindowController, NSWindowDelegate {
    /// Told when a repository is down, to open.
    private let onCloned: () -> Void
    /// Told when the person would rather open a folder of their own.
    private let onOpenFolder: (() -> Void)?

    /// `closeGraph` lets the graph open go, saved, before its clone is set
    /// aside for another.
    init(onCloned: @escaping () -> Void, onOpenFolder: (() -> Void)?, closeGraph: @escaping () -> Void) {
        self.onCloned = onCloned
        self.onOpenFolder = onOpenFolder
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "GitHub"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        // The graph opened before this closes: the last window closing quits.
        let view = GitHubConnectView(closeGraph: closeGraph, onCloned: { [weak self] in
            onCloned()
            self?.close()
        }, onOpenFolder: onOpenFolder.map { open in { [weak self] in
            open()
            self?.close()
        } })
        .environment(GitHubGraph.account)
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Sign in, choose the repository, bring it down; or, signed in already,
/// who as and which repository — and signing out.
struct GitHubConnectView: View {
    let closeGraph: () -> Void
    let onCloned: () -> Void
    let onOpenFolder: (() -> Void)?
    @Environment(GitHubAccount.self) private var account
    @Environment(\.webAuthenticationSession) private var session

    @State private var repositories: [GitHubRepository]?
    @State private var cloning: GitHubRepository?
    @State private var busy = false
    @State private var error: String?
    /// Signed in with a clone already: choosing another repository.
    @State private var choosingAnother = false

    var body: some View {
        VStack(spacing: 0) {
            if !GitHubApp.isConfigured {
                ContentUnavailableView("GitHub Is Not Set Up", systemImage: "gearshape",
                                       description: Text("This build has no GitHub App: build Prism with scripts/build-prism.sh, with iOS/GitHub.local.xcconfig in place."))
            } else if let cloning {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Bringing down \(cloning.fullName)…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !account.isSignedIn {
                signIn
            } else if GitHubGraph.exists && !choosingAnother {
                connected
            } else {
                choose
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .alert("Something Went Wrong", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .task(id: account.isSignedIn) { await loadRepositories() }
    }

    private var signIn: some View {
        page(symbol: "books.vertical", title: "Your Notes, from GitHub",
             text: "Prism keeps its own copy of your graph, in step with the GitHub repository it is kept in — as the iPhone does. Sign in, and choose the repository.") {
            Button {
                run { try await account.signIn(session.github) }
            } label: {
                Text("Sign In with GitHub").frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy)
            if let onOpenFolder {
                Button("Open a Folder Instead…", action: onOpenFolder)
                    .buttonStyle(.link)
            }
        }
    }

    private var connected: some View {
        page(symbol: "checkmark.icloud", title: GitHubGraph.repositoryName ?? "Your Graph",
             text: "Signed in as \(account.user?.login ?? "you"). Prism keeps its copy of the graph in step with GitHub.") {
            Button("Choose Another Repository…") { choosingAnother = true }
                .controlSize(.large)
            Button("Sign Out") { account.signOut() }
                .buttonStyle(.link)
        }
    }

    /// A page of its own: a symbol, what it is, and what to do.
    private func page(symbol: String, title: String, text: String, @ViewBuilder actions: () -> some View) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text(title).font(.title2.bold())
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            VStack(spacing: 10) { actions() }
                .padding(.top, 10)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Your Graph").font(.title2.bold())
            Text("The repository your notes are kept in. It comes down to this Mac, and is kept in step with GitHub.")
                .foregroundStyle(.secondary)
            Group {
                if let repositories {
                    if repositories.isEmpty {
                        Text("Prism has not been given any repositories yet.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(repositories) { repository in
                            Button {
                                bringDown(repository)
                            } label: {
                                Label(repository.fullName, systemImage: repository.isPrivate ? "lock" : "book.closed")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                        }
                        .listStyle(.bordered)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Button("Choose Repositories on GitHub…") {
                    run {
                        try await account.chooseRepositories(session.github)
                        await loadRepositories()
                    }
                }
                .disabled(busy)
                Spacer()
                if let user = account.user { Text(user.login).foregroundStyle(.secondary) }
                Button("Sign Out") {
                    account.signOut()
                    repositories = nil
                }
            }
        }
        .padding(24)
        .padding(.top, 12)
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
                // Another repository in place of the clone: the old one set
                // aside, not deleted — what was not yet pushed may be in it.
                if GitHubGraph.exists {
                    closeGraph()
                    let aside = GitHubGraph.root.deletingLastPathComponent()
                        .appendingPathComponent("Graph (set aside \(Int(Date().timeIntervalSince1970)))")
                    try FileManager.default.moveItem(at: GitHubGraph.root, to: aside)
                }
                try await GitHubGraph.clone(repository)
                onCloned()
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

extension WebAuthenticationSession {
    /// GitHub's pages in the system's browser sheet, for the account to sign in through.
    var github: GitHubAuthenticator {
        { url, scheme in
            try await authenticate(using: url, callback: .customScheme(scheme), preferredBrowserSession: .shared, additionalHeaderFields: [:])
        }
    }
}
