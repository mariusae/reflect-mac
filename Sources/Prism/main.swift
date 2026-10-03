import AppKit

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { PrismApp() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
