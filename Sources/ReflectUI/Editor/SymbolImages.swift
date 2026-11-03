import AppKit

/// Symbols drawn among the words — a pill's icon, a task's box — made
/// once for each look and kept: looked up and configured for each one
/// as it is drawn, they took more than the drawing.
package enum SymbolImages {
    /// Drawn on the main thread; the lock for any that is not.
    nonisolated(unsafe) private static var made: [String: NSImage] = [:]
    private static let lock = NSLock()

    package static func image(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, colors: [NSColor],
                              description: String? = nil) -> NSImage? {
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(colors.map(\.description).joined(separator: ","))"
        lock.lock()
        defer { lock.unlock() }
        if let known = made[key] { return known }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight).applying(.init(paletteColors: colors))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?.withSymbolConfiguration(configuration) else { return nil }
        made[key] = image
        return image
    }
}
