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

/// What UIKit tells the app that SwiftUI does not: its push token, and
/// silent pushes.
final class PrismAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Silent pushes need no permission asked of the person.
        application.registerForRemoteNotifications()
        // `-PrismFakePushAfter <seconds>`: a push handled as one from the relay
        // would be — for the simulator, which delivers no silent pushes.
        let fake = UserDefaults.standard.double(forKey: "PrismFakePushAfter")
        if fake > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + fake) {
                print("FAKE PUSH, app state \(application.applicationState.rawValue)")
                PushRelay.shared.pushed { result in print("FAKE PUSH RESULT \(result.rawValue)") }
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PushRelay.shared.received(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.shared.warning("relay", "No push token", detail: error.localizedDescription)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completion: @escaping (UIBackgroundFetchResult) -> Void) {
        MainActor.assumeIsolated { PushRelay.shared.pushed(completion) }
    }
}
