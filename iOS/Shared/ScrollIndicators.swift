import UIKit
import WebKit
import ObjectiveC

/// Scroll bars that read on the page, whatever scrolls: dark on the light
/// paper, light on the dark — the system's own grey all but lost on the
/// dark. Every scroll view once it is on screen — but a web page's, which
/// WebKit sets by the page's own colour: a white page white in the dark.
extension UIScrollView {
    static func followPaper() {
        let original = #selector(UIView.didMoveToWindow)
        let replacement = #selector(UIScrollView.prism_didMoveToWindow)
        guard let theirs = class_getInstanceMethod(UIScrollView.self, original),
              let ours = class_getInstanceMethod(UIScrollView.self, replacement) else { return }
        // UIScrollView's own, made first when it only inherits UIView's: UIView's left alone.
        if class_addMethod(UIScrollView.self, original, method_getImplementation(ours), method_getTypeEncoding(ours)) {
            class_replaceMethod(UIScrollView.self, replacement, method_getImplementation(theirs), method_getTypeEncoding(theirs))
        } else {
            method_exchangeImplementations(theirs, ours)
        }
    }

    @objc private func prism_didMoveToWindow() {
        prism_didMoveToWindow()
        guard window != nil, !(superview is WKWebView) else { return }
        matchPaper()
        if objc_getAssociatedObject(self, &Self.watchingKey) == nil {
            objc_setAssociatedObject(self, &Self.watchingKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: UIScrollView, _) in view.matchPaper() }
        }
    }

    private func matchPaper() {
        let style: UIScrollView.IndicatorStyle = traitCollection.userInterfaceStyle == .dark ? .white : .black
        if indicatorStyle != style { indicatorStyle = style }
    }

    nonisolated(unsafe) private static var watchingKey: UInt8 = 0
}
