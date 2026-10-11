import UIKit
import ReflectCore

/// The app's icon held on the Home Screen: the notes written in last, each
/// to open — as the magnifier held offers them in the app.
@MainActor
enum QuickActions {
    private static let type = "com.mariusae.Prism.note"

    /// A note chosen from the icon, waiting for the notes to be shown.
    static var pending: String? {
        didSet { if pending != nil { onPending?() } }
    }
    /// Told when one is chosen: the columns, to open it once they can.
    static var onPending: (() -> Void)?

    /// The icon's notes, the latest first — as many as it shows.
    static func update(_ entries: [NoteEntry]) {
        UIApplication.shared.shortcutItems = entries.prefix(4).map { entry in
            UIApplicationShortcutItem(type: type, localizedTitle: entry.title.isEmpty ? (entry.path as NSString).lastPathComponent : entry.title,
                                      localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "doc.text"),
                                      userInfo: ["path": entry.path as NSString])
        }
    }

    /// An item chosen: its note, to open. Says whether it was one of ours.
    @discardableResult
    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type == type, let path = item.userInfo?["path"] as? String else { return false }
        pending = path
        return true
    }
}

/// The scene's delegate: the icon's item chosen — at launch, or while the
/// app ran — handed on.
final class PrismSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let item = options.shortcutItem { MainActor.assumeIsolated { _ = QuickActions.handle(item) } }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor item: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(MainActor.assumeIsolated { QuickActions.handle(item) })
    }
}
