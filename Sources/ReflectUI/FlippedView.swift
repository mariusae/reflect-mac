import AppKit

/// A view whose origin is at the top, as a document's is.
package final class FlippedView: NSView {
    package override var isFlipped: Bool { true }
}
