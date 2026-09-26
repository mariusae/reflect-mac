import AppKit

/// The sidebar, put away, peeking out: the pointer at the window's left edge
/// slides it out over the notes — which stay where they are — on Liquid
/// Glass, and it slides away when the pointer leaves it, a click falls
/// elsewhere, something is opened from it, or Escape is pressed.
@MainActor
final class PeekSidebar: NSObject {
    let sidebar: SidebarViewController
    private weak var host: NSView?
    private let isCollapsed: () -> Bool
    private let willShow: () -> Void

    private let edge = EdgeStrip()
    private let glass = NSGlassEffectView()
    private var shown = false
    private var pendingShow: DispatchWorkItem?
    private var pendingHide: DispatchWorkItem?
    private var clickMonitor: Any?
    private var keyMonitor: Any?

    static let width: CGFloat = 290
    /// How near the left edge the pointer brings it out.
    static let reach: CGFloat = 24
    /// How long the pointer rests there first.
    static let delay: TimeInterval = 0.05
    static let inset: CGFloat = 8

    init(sidebar: SidebarViewController, in host: NSView, isCollapsed: @escaping () -> Bool, willShow: @escaping () -> Void) {
        self.sidebar = sidebar
        self.host = host
        self.isCollapsed = isCollapsed
        self.willShow = willShow
        super.init()

        edge.translatesAutoresizingMaskIntoConstraints = false
        edge.onEnter = { [weak self] in self?.scheduleShow() }
        edge.onExit = { [weak self] in self?.pendingShow?.cancel() }
        host.addSubview(edge)

        glass.cornerRadius = 18
        glass.style = .regular
        glass.contentView = sidebar.view
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.isHidden = true
        glass.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            return shadow
        }()
        glass.wantsLayer = true
        host.addSubview(glass, positioned: .above, relativeTo: nil)
        let hover = HoverTracker()
        hover.onExit = { [weak self] in self?.scheduleHide() }
        hover.onEnter = { [weak self] in self?.pendingHide?.cancel() }
        hover.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(hover, positioned: .below, relativeTo: nil)

        let top = host.safeAreaLayoutGuide.topAnchor
        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            edge.topAnchor.constraint(equalTo: top),
            edge.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            // Near the edge, not on it: a band the pointer finds without aiming.
            edge.widthAnchor.constraint(equalToConstant: Self.reach),
            glass.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Self.inset),
            glass.topAnchor.constraint(equalTo: top, constant: Self.inset),
            glass.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Self.inset),
            glass.widthAnchor.constraint(equalToConstant: Self.width),
            hover.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            hover.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            hover.topAnchor.constraint(equalTo: glass.topAnchor),
            hover.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
    }

    var isShown: Bool { shown }

    private func scheduleShow() {
        guard isCollapsed(), !shown else { return }
        pendingShow?.cancel()
        // A moment's rest at the edge, not a pointer passing by.
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.show() } }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    private func scheduleHide() {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func show() {
        guard isCollapsed(), !shown, let host else { return }
        shown = true
        willShow()
        glass.isHidden = false
        glass.alphaValue = 0
        glass.layer?.transform = CATransform3DMakeTranslation(-(Self.width + Self.inset), 0, 0)
        host.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            glass.animator().alphaValue = 1
            glass.layer?.transform = CATransform3DIdentity
        }
        // A click elsewhere, or Escape, puts it away.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = host.window, event.window === window else { return event }
            let point = glass.convert(event.locationInWindow, from: nil)
            if !glass.bounds.contains(point) { hide() }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            hide()
            return nil
        }
    }

    func hide(animated: Bool = true) {
        pendingShow?.cancel()
        pendingHide?.cancel()
        guard shown else { return }
        shown = false
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
        // The keyboard back to the notes, if it was in here.
        if let responder = glass.window?.firstResponder as? NSView, responder.isDescendant(of: glass) {
            glass.window?.makeFirstResponder(nil)
        }
        guard animated else {
            glass.isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            glass.animator().alphaValue = 0
            glass.layer?.transform = CATransform3DMakeTranslation(-(Self.width + Self.inset), 0, 0)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shown else { return }
                self.glass.isHidden = true
            }
        })
    }
}

/// The strip along the window's left edge the pointer brings the sidebar
/// out from: seen by the pointer, never by a click.
private final class EdgeStrip: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Tells when the pointer comes into, and leaves, the peeking sidebar.
private final class HoverTracker: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
