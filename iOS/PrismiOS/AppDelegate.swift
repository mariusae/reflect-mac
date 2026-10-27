import UIKit
import ReflectCore
import ReflectGit2

/// What UIKit tells the app that SwiftUI does not: its push token, and
/// silent pushes.
final class PrismAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Scroll bars that read on the dark paper too.
        UIScrollView.followPaper()
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

    /// Each scene with a delegate of its own: for the icon's quick actions.
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = PrismSceneDelegate.self
        return configuration
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
