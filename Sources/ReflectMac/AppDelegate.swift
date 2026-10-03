import AppKit
import ReflectCore
import ReflectUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Where the graph is: a checkout of the repository the notes are kept
    /// in. `-GraphPath <folder>` on the command line overrides it.
    static let graphPathKey = "GraphPath"

    private var windowController: MainWindowController?
    /// Where the browser extension sends pages.
    let captureServer = CaptureServer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        StallWatch.shared.start()
        SyncController.doing = { StallWatch.doing($0) }
        NSApp.mainMenu = MainMenu.build()
        if let path = UserDefaults.standard.string(forKey: Self.graphPathKey) {
            open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
        } else {
            chooseGraph(firstTime: true)
        }
        NSApp.activate()
    }

    private func open(_ root: URL) {
        windowController?.workspace.saveAll()
        windowController?.recordState()
        windowController?.close()
        let graph = Graph(root: root)
        Log.shared.info("app", "Opened \(root.path)" + (graph.git == nil ? ", which is not in a git repository" : ""))
        let sync = SyncController(git: graph.git)
        let controller = MainWindowController(graph: graph, sync: sync)
        windowController = controller
        captureServer.graphName = { root.lastPathComponent }
        captureServer.onCapture = { [weak controller] page, screenshot in
            guard let controller else { throw CocoaError(.fileWriteUnknown) }
            return try controller.capture(page, screenshot: screenshot)
        }
        captureServer.onOpen = { [weak controller] path in
            NSApp.activate()
            controller?.window?.makeKeyAndOrderFront(nil)
            controller?.workspace.open(OpenQuickly.target(for: path), inSplit: false)
        }
        captureServer.start()
        controller.showWindow(nil)
        sync.sync()
        Script.runIfRequested(controller)
    }

    private func chooseGraph(firstTime: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = "Open"
        panel.message = "Choose the folder your Reflect graph is checked out in."
        let home = FileManager.default.homeDirectoryForCurrentUser
        let usual = home.appendingPathComponent("reflect")
        panel.directoryURL = FileManager.default.fileExists(atPath: usual.path) ? usual : home
        guard panel.runModal() == .OK, let url = panel.url else {
            if firstTime { NSApp.terminate(nil) }
            return
        }
        UserDefaults.standard.set(url.path, forKey: Self.graphPathKey)
        open(url)
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func showConsole(_ sender: Any?) { ConsoleWindowController.shared.show() }

    @objc func openGraph(_ sender: Any?) {
        chooseGraph(firstTime: false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.showWindow(nil) }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        StallWatch.doing("coming forward: reading the notes on screen again")
        windowController?.reloadFromDisk()
        StallWatch.doing("coming forward: syncing")
        windowController?.sync.sync(becauseActivated: true)
        StallWatch.doing("idle")
    }

    func applicationDidResignActive(_ notification: Notification) {
        windowController?.workspace.saveAll()
        windowController?.recordState()
        SessionState.shared.writeNow()
    }

    /// Saves, and gives git a moment to commit and push what was saved, so a
    /// note written just before quitting is not left only on this disk.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = windowController else { return .terminateNow }
        controller.workspace.saveAll()
        controller.recordState()
        SessionState.shared.writeNow()
        guard controller.sync.git != nil else { return .terminateNow }
        Task {
            await controller.sync.finish()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
