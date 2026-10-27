import UIKit
import ReflectCore
import ReflectGit2

/// The phone's side of the sync relay: its push token registered for the
/// graph's repository, and the silent pushes the relay sends — another
/// device pushed — met with a sync, even with the app in the background.
@MainActor
final class PushRelay {
    static let shared = PushRelay()

    weak var store: PrismStore?
    weak var scheduler: SyncScheduler?
    var account: GitHubAccount?
    private var deviceToken: Data?
    /// Registered this run, for this repository: once is enough.
    private var registered: String?

    /// APNs gave the phone its token.
    func received(_ token: Data) {
        if token != deviceToken { registered = nil }
        deviceToken = token
        register()
    }

    /// The token told to the relay, once there is one, a graph and a sign-in.
    func register() {
        guard let deviceToken, let store, let account, account.isSignedIn, SyncRelay.host != nil else { return }
        store.prepareGit()
        guard let repository = store.repositoryName, registered != repository else { return }
        registered = repository
        Task {
            do {
                try await SyncRelay.register(deviceToken: deviceToken, repository: repository,
                                             topic: Bundle.main.bundleIdentifier ?? "com.mariusae.Prism",
                                             sandbox: SyncRelay.isSandbox, accessToken: try await account.validAccessToken())
            } catch {
                registered = nil
                Log.shared.warning("relay", "Could not register for pushes", detail: error.localizedDescription)
            }
        }
    }

    func pushed(_ completion: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let scheduler else { return completion(.noData) }
        scheduler.syncForPush(completion)
    }
}

