import AppKit
import WebKit
import ReflectCore
import ReflectUI
import PrismCore

/// A link note's page, in a column at the note's right: as the site has
/// it — or, the reader turned on, its words alone, set in Chronicle on the
/// paper, the site's chrome, its ads, its menus left behind — its controls
/// floating over the top as a note's do, gone as it is read down: where it
/// is from, the reader, the type, and ×. Read down to
/// anywhere, it opens there again, however the app was left. A passage
/// chosen and highlighted goes into the note, under its Highlights, and is
/// marked there each time the page is read again.
final class ReaderPane: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    let session: Session
    /// The link note it is read from: its highlights go there.
    let notePath: String
    let url: URL

    /// Its × clicked.
    var onClose: ((ReaderPane) -> Void)?

    private let web: ReaderWebView
    private let chrome = ReaderChrome()
    private let edge = EdgeFade()
    private let leftRule = RuleView()
    private let spinner = NSProgressIndicator()
    private let failure = NSTextField(wrappingLabelWithString: "")
    private var restored = false
    /// Its words alone, in the reader: else the page as the site has it.
    private(set) var reading: Bool
    private var titleWatch: NSKeyValueObservation?
    private var lastY: CGFloat = 0
    private var travel: CGFloat = 0

    override var isFlipped: Bool { true }

    init(session: Session, notePath: String, url: URL) {
        self.session = session
        self.notePath = notePath
        self.url = url
        reading = ReaderPlace.reads(url)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(ReaderPage.userScript)
        web = ReaderWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        configuration.userContentController.add(WeakMessages(self), name: "scrolled")
        configuration.userContentController.add(WeakMessages(self), name: "moved")
        web.navigationDelegate = self
        web.underPageBackgroundColor = Ink.paper
        web.obscuredContentInsets = NSEdgeInsets(top: PaneChrome.height, left: 0, bottom: 0, right: 0)
        web.allowsBackForwardNavigationGestures = true
        web.onHighlight = { [weak self] in self?.highlightSelection() }
        web.onType = { [weak self] by in self?.restyle { $0.step(by) } }
        addSubview(web)
        edge.isHidden = true
        addSubview(edge)
        addSubview(chrome)
        addSubview(leftRule)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        failure.alignment = .center
        failure.textColor = Ink.secondary
        failure.isHidden = true
        addSubview(failure)

        chrome.onClose = { [weak self] in
            guard let self else { return }
            onClose?(self)
        }
        chrome.onType = { [weak self] view in self?.showTypeMenu(from: view) }
        chrome.onReader = { [weak self] in self?.toggleReading() }
        chrome.onTop = { [weak self] in self?.web.evaluateJavaScript("window.scrollTo({top: 0, behavior: 'smooth'})") }
        titleWatch = web.observe(\.title) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.showSite() }
        }
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A link note's page, to read: nothing, when the note has no address.
    static func url(of path: String, session: Session) -> URL? {
        guard let source = session.graph.read(path: path), let address = WebCapture.url(in: source) else { return nil }
        return URL(string: address)
    }

    func focus() { window?.makeFirstResponder(web) }

    // MARK: The page, or its words

    private func load() {
        restored = false
        failure.isHidden = true
        chrome.reading = reading
        // The page's own paper, as the site has it; the app's, in the reader.
        web.setValue(!reading, forKey: "drawsBackground")
        edge.isHidden = true
        showSite()
        guard reading else {
            web.load(URLRequest(url: url))
            return
        }
        if let cached = ReaderArticle.cached(url) { return show(cached) }
        spinner.startAnimation(nil)
        ReaderArticle.fetch(url) { [weak self] article in
            guard let self else { return }
            spinner.stopAnimation(nil)
            guard reading else { return }
            guard let article else {
                failure.stringValue = "This page could not be read.\n\(url.host() ?? "")"
                failure.isHidden = false
                return
            }
            show(article)
        }
    }

    /// The reader on, or off: the page set again, where it was read to in that.
    func toggleReading() {
        savePlace()
        reading.toggle()
        ReaderPlace.setReads(reading, for: url)
        spinner.stopAnimation(nil)
        load()
    }

    /// The band as the site has it: its address, its title.
    private func showSite() {
        guard !reading else { return }
        let host = (web.url ?? url).host ?? ""
        let title = web.title.flatMap { $0.isEmpty ? nil : $0 } ?? session.name(of: notePath).title
        chrome.show(source: host.replacingOccurrences(of: "www.", with: "").uppercased(), title: title, metrics: session.metrics)
    }

    /// Where its place is kept: in the reader, the note's page; else the page the site is on.
    private var placeURL: URL { reading ? url : web.url ?? url }

    private func show(_ article: ReaderArticle) {
        chrome.show(source: "\(article.site.uppercased()) – \(article.minutes) MIN READ",
                    title: article.title.isEmpty ? session.name(of: notePath).title : article.title, metrics: session.metrics)
        if let address = article.icon, let iconURL = URL(string: address) {
            URLSession.shared.dataTask(with: iconURL) { [weak self] data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async { self?.chrome.icon = image }
            }.resume()
        }
        web.loadHTMLString(ReaderPage.html(article, style: .current, paper: Self.paper, top: 8), baseURL: url)
    }

    /// Prism's own paper and ink.
    private static let paper = ReaderPage.Paper(paper: ("#faf7f2", "#1d1b18"), ink: ("#2b2724", "#ece6dc"), soft: ("#6f665d", "#a79e92"))

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The passages highlighted before, marked again; then where it was read to.
        markHighlights()
        // The first page in, where it was read to: not a link followed from it.
        if !restored {
            restored = true
            webView.evaluateJavaScript("prismRestore(\(ReaderPlace.saved(url, reading: reading)))")
        }
        if !reading { faviconFromPage() }
    }

    private func markHighlights() {
        if let marking = ReaderPage.marking(WebCapture.highlights(in: session.graph.read(path: notePath) ?? "")) {
            web.evaluateJavaScript(marking)
        }
    }

    /// The site's icon, as its page names it.
    private func faviconFromPage() {
        web.evaluateJavaScript("(function(){var l=document.querySelector('link[rel~=\"apple-touch-icon\"], link[rel~=\"icon\"]');return l?l.href:location.origin+'/favicon.ico';})()") { [weak self] value, _ in
            guard let address = value as? String, let iconURL = URL(string: address) else { return }
            URLSession.shared.dataTask(with: iconURL) { data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async { self?.chrome.icon = image }
            }.resume()
        }
    }

    /// A link in the reader: out to the browser. In the site's page, followed there.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if reading, action.navigationType == .linkActivated, let target = action.request.url {
            NSWorkspace.shared.open(target)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "scrolled":
            if let fraction = message.body as? Double { ReaderPlace.save(fraction, for: placeURL, reading: reading) }
        case "moved":
            if let y = message.body as? Double { scrolled(to: CGFloat(y)) }
        default: break
        }
    }

    /// Where it was read to, kept: closed, or the app quit.
    func savePlace() {
        web.evaluateJavaScript("prismPlace()") { [placeURL, reading] value, _ in
            if let fraction = value as? Double { ReaderPlace.save(fraction, for: placeURL, reading: reading) }
        }
    }

    // MARK: Out of the way

    /// Read down: the controls tucked away; read back up, or at the top, back.
    private func scrolled(to y: CGFloat) {
        let delta = y - lastY
        lastY = y
        if y <= 2 {
            travel = 0
            return setTucked(false)
        }
        travel = (delta > 0) == (travel > 0) ? travel + delta : delta
        if travel > 24 { setTucked(true) } else if travel < -12 { setTucked(false) } else { edge.isHidden = !reading || chrome.isTucked }
    }

    /// Out of the way, read down into the page; back, read up. The fade
    /// under them the reader's only: a site's page has its own colours.
    private func setTucked(_ tucked: Bool) {
        chrome.setTucked(tucked)
        edge.isHidden = !reading || lastY <= 2 || tucked
    }

    /// The pointer up to the top: the controls back.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if chrome.isTucked, convert(event.locationInWindow, from: nil).y < PaneChrome.height + 16 { setTucked(false) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func layout() {
        super.layout()
        web.frame = bounds
        chrome.frame = NSRect(x: 0, y: 0, width: bounds.width, height: PaneChrome.height)
        edge.frame = NSRect(x: 0, y: 0, width: bounds.width, height: PaneChrome.height + 18)
        leftRule.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height)
        spinner.frame = NSRect(x: bounds.midX - 10, y: bounds.midY - 10, width: 20, height: 20)
        failure.frame = NSRect(x: 32, y: bounds.midY - 30, width: max(0, bounds.width - 64), height: 60)
    }

    // MARK: Type

    /// Aa: the size, the face, the spacing — kept, for every page read.
    private func showTypeMenu(from view: NSView) {
        let style = ReaderStyle.current
        let menu = NSMenu()
        let smaller = NSMenuItem(title: "Smaller", action: #selector(smaller), keyEquivalent: "-")
        let larger = NSMenuItem(title: "Larger", action: #selector(larger), keyEquivalent: "+")
        smaller.image = NSImage(systemSymbolName: "textformat.size.smaller", accessibilityDescription: nil)
        larger.image = NSImage(systemSymbolName: "textformat.size.larger", accessibilityDescription: nil)
        for item in [smaller, larger] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Typeface"))
        for (i, face) in ReaderStyle.Face.allCases.enumerated() {
            let item = NSMenuItem(title: face.title, action: #selector(choseFace(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = style.face == face ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Spacing"))
        for (i, spacing) in ReaderStyle.Spacing.allCases.enumerated() {
            let item = NSMenuItem(title: spacing.title, action: #selector(choseSpacing(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = style.spacing == spacing ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    @objc private func smaller() { restyle { $0.step(-1) } }
    @objc private func larger() { restyle { $0.step(1) } }
    @objc private func choseFace(_ item: NSMenuItem) { restyle { $0.face = ReaderStyle.Face.allCases[item.tag] } }
    @objc private func choseSpacing(_ item: NSMenuItem) { restyle { $0.spacing = ReaderStyle.Spacing.allCases[item.tag] } }

    /// The type changed: kept, and the page set in it at once, where it was.
    private func restyle(_ change: (inout ReaderStyle) -> Void) {
        var style = ReaderStyle.current
        change(&style)
        ReaderStyle.current = style
        web.evaluateJavaScript(style.script)
    }

    // MARK: Highlighting

    /// Scripts': the words found in the page, chosen, and highlighted.
    func highlightForScript(_ words: String) {
        guard let data = try? JSONEncoder().encode(words), let quoted = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.find(\(quoted))") { [weak self] _, _ in self?.highlightSelection() }
    }

    /// The passage chosen: marked in the page, and written into the note, under its Highlights.
    func highlightSelection() {
        web.evaluateJavaScript("prismHighlight()") { [weak self] value, _ in
            guard let self, let passage = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !passage.isEmpty else {
                return NSSound.beep()
            }
            session.change(notePath) { source in
                let after = WebCapture.highlighting(passage, in: source)
                return after == source ? nil : after
            }
        }
    }
}

/// The reader's page: Highlight first in its menu, a passage chosen, and ⇧⌘H; ⌘- and ⌘+ the type.
final class ReaderWebView: WKWebView {
    var onHighlight: (() -> Void)?
    var onType: ((Double) -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // Text chosen: the menu has Copy.
        guard menu.items.contains(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }) else { return }
        let highlight = NSMenuItem(title: "Highlight", action: #selector(highlight), keyEquivalent: "")
        highlight.target = self
        highlight.image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: nil)
        menu.insertItem(highlight, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    @objc private func highlight() { onHighlight?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self || window?.firstResponder.map({ ($0 as? NSView)?.isDescendant(of: self) == true }) == true
        else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⇧⌘H: highlighted here — before the menus, whose Format ▸ Highlight is the notes'.
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "h" {
            onHighlight?()
            return true
        }
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "-": onType?(-1); return true
        case "+", "=": onType?(1); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

/// The reader's controls, floating on glass over its top: at the left, the
/// page's icon, its site and how long it takes, its title — clicked, back
/// to the top; at the right, the type, and ×.
final class ReaderChrome: NSView {
    var onClose: (() -> Void)?
    var onType: ((NSView) -> Void)?
    var onTop: (() -> Void)?
    var onReader: (() -> Void)?

    private let band = GlassCapsule()
    private let right = GlassCapsule()
    private let iconView = NSImageView()
    private let source = NSTextField(labelWithString: "")
    private let headline = NSTextField(labelWithString: "")
    private let reader = CloseButton(symbol: "doc.plaintext", pointSize: 13, toolTip: "Reader: the Words Alone (⇧⌘E)")
    private let type = CloseButton(symbol: "textformat.size", pointSize: 13, toolTip: "Type (⌘- ⌘+)")
    private let close = CloseButton(symbol: "xmark", pointSize: 11, toolTip: "Close the Page (⇧⌘R)")
    private(set) var isTucked = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// The reader on: lit, and the type to set.
    var reading = false {
        didSet {
            reader.image = NSImage(systemSymbolName: reading ? "doc.plaintext.fill" : "doc.plaintext", accessibilityDescription: "Reader")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            reader.toolTip = reading ? "The Page as the Site Has It (⇧⌘E)" : "Reader: the Words Alone (⇧⌘E)"
            needsLayout = true
        }
    }

    var icon: NSImage? {
        didSet { iconView.image = icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil) }
    }

    init() {
        super.init(frame: .zero)
        addSubview(band)
        addSubview(right)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 4
        iconView.layer?.masksToBounds = true
        iconView.contentTintColor = Ink.secondary
        iconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        source.font = .systemFont(ofSize: 9.5, weight: .semibold)
        source.textColor = Ink.secondary
        headline.textColor = Ink.text
        for label in [source, headline] {
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
        }
        for view in [iconView, source, headline] as [NSView] { band.content.addSubview(view) }
        band.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(topClicked)))
        for (button, action) in [(reader, #selector(readerClicked)), (type, #selector(typeClicked)), (close, #selector(closeClicked))] {
            button.contentTintColor = Ink.text
            button.target = self
            button.action = action
            right.content.addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(source text: String, title: String, metrics: OutlineMetrics) {
        source.stringValue = text
        headline.stringValue = title
        headline.font = metrics.typography.headingFont(size: 13, weight: .bold)
        needsLayout = true
    }

    @objc private func typeClicked() { onType?(type) }
    @objc private func readerClicked() { onReader?() }
    @objc private func closeClicked() { onClose?() }
    @objc private func topClicked() { onTop?() }

    func setTucked(_ tucked: Bool) {
        guard tucked != isTucked else { return }
        isTucked = tucked
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            for capsule in [band, right] { capsule.animator().alphaValue = tucked ? 0 : 1 }
        }
    }

    override func layout() {
        super.layout()
        let side: CGFloat = 34
        let y = ((PaneChrome.height - side) / 2).rounded()
        reader.frame = NSRect(x: 4, y: 4, width: 28, height: side - 8)
        type.isHidden = !reading
        type.frame = NSRect(x: reader.frame.maxX, y: 4, width: reading ? 28 : 0, height: side - 8)
        close.frame = NSRect(x: type.frame.maxX, y: 4, width: 26, height: side - 8)
        right.frame = NSRect(x: bounds.width - 12 - (close.frame.maxX + 4), y: y, width: close.frame.maxX + 4, height: side)
        // The band: as wide as what it says, as far as the room goes.
        let words = max(source.intrinsicContentSize.width, headline.intrinsicContentSize.width)
        let width = max(0, min(12 + 20 + 8 + words + 14, right.frame.minX - 10 - 12, 520))
        band.isHidden = width < 80
        band.frame = NSRect(x: 12, y: y, width: width, height: side)
        iconView.frame = NSRect(x: 12, y: (side - 18) / 2, width: 18, height: 18)
        let textX = iconView.frame.maxX + 8
        let textWidth = max(0, width - textX - 14)
        source.frame = NSRect(x: textX, y: 4, width: textWidth, height: 12)
        headline.frame = NSRect(x: textX, y: 15, width: textWidth, height: 16)
    }

    /// Only the capsules are its own, to the pointer — none, tucked away.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isTucked else { return nil }
        let local = convert(point, from: superview)
        guard [band, right].contains(where: { !$0.isHidden && $0.frame.contains(local) }) else { return nil }
        return super.hitTest(point)
    }
}
