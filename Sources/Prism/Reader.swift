import AppKit
import WebKit
import PDFKit
import ReflectCore
import ReflectUI
import PrismCore

/// What a note links to, in a column at the note's right — its own page,
/// a link note's, or any page it links to, or a PDF it holds, ‹ › from one
/// to the next: a page as the site has
/// it — or, the reader turned on, its words alone, set in Chronicle on the
/// paper, the site's chrome, its ads, its menus left behind — its controls
/// floating over the top as a note's do, gone as it is read down: where it
/// is from, the reader, the type, and ×. Read down to
/// anywhere, it opens there again, however the app was left. A passage
/// chosen and highlighted goes into the note, under its Highlights, and is
/// marked there each time the page is read again.
final class ReaderPane: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    let session: Session
    /// The note it is read from: its highlights go there.
    let notePath: String
    /// Everything in the note to read, and which is read.
    private(set) var sources: [ReaderSource]
    private(set) var index: Int
    var source: ReaderSource { sources[index] }
    var url: URL { source.url }

    /// Its × clicked.
    var onClose: ((ReaderPane) -> Void)?

    private let web: ReaderWebView
    private let pdf = ReaderPDFView()
    /// The passages highlighted before, marked on the PDF.
    private var pdfMarks: [(PDFPage, PDFAnnotation)] = []
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

    init(session: Session, notePath: String, sources: [ReaderSource]) {
        self.session = session
        self.notePath = notePath
        self.sources = sources
        index = ReaderPlace.chosen(in: sources, for: notePath)
        reading = ReaderPlace.reads(sources[index].url)
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
        pdf.autoScales = true
        pdf.displayMode = .singlePageContinuous
        pdf.backgroundColor = Ink.paper
        pdf.isHidden = true
        pdf.onHighlight = { [weak self] in self?.highlightSelection() }
        addSubview(pdf)
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
        chrome.onStep = { [weak self] by in self?.turn(by) }
        chrome.onTop = { [weak self] in
            guard let self else { return }
            if source.isPDF { pdf.document?.page(at: 0).map(pdf.go(to:)) } else { web.evaluateJavaScript("window.scrollTo({top: 0, behavior: 'smooth'})") }
        }
        titleWatch = web.observe(\.title) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.showSite() }
        }
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// What a note has to read: none, when it links to nothing.
    static func sources(of path: String, session: Session) -> [ReaderSource] {
        guard let text = session.graph.read(path: path) else { return [] }
        return ReaderSource.all(in: text, root: session.graph.root)
    }

    func focus() { window?.makeFirstResponder(source.isPDF ? pdf : web) }

    /// The note's sources again, changed: where it is read kept, if it is still there.
    func refresh(_ sources: [ReaderSource]) {
        guard !sources.isEmpty, sources != self.sources else { return }
        let address = source.address
        self.sources = sources
        if let same = sources.firstIndex(where: { $0.address == address }) {
            index = same
            chrome.position = (index, sources.count)
        } else {
            index = 0
            open()
        }
    }

    /// The next of the note's sources, or the one before.
    func turn(_ by: Int) {
        let next = index + by
        guard sources.indices.contains(next) else { return NSSound.beep() }
        savePlace()
        index = next
        ReaderPlace.choose(source, for: notePath, first: index == 0)
        open()
    }

    private func open() {
        reading = ReaderPlace.reads(url)
        spinner.stopAnimation(nil)
        chrome.icon = nil
        lastY = 0
        setTucked(false)
        load()
    }

    /// Back, or forward, through the pages followed in it: false, none that way.
    func step(_ by: Int) -> Bool {
        guard !source.isPDF else { return false }
        if by < 0, web.canGoBack { web.goBack(); return true }
        if by > 0, web.canGoForward { web.goForward(); return true }
        return false
    }

    // MARK: The page, or its words

    private func load() {
        restored = false
        failure.isHidden = true
        chrome.position = (index, sources.count)
        chrome.isPDF = source.isPDF
        web.isHidden = source.isPDF
        pdf.isHidden = !source.isPDF
        if source.isPDF { return showPDF() }
        pdf.document = nil
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
        guard !reading, !source.isPDF else { return }
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
        if let marking = ReaderPage.marking(highlights) { web.evaluateJavaScript(marking) }
    }

    /// The passages highlighted on what is read, as the note has them.
    private var highlights: [String] {
        WebCapture.highlights(in: session.graph.read(path: notePath) ?? "", of: source.address)
    }

    // MARK: A PDF

    private func showPDF() {
        web.stopLoading()
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            pdf.document = nil
            chrome.show(source: "PDF", title: source.name, metrics: session.metrics)
            failure.stringValue = "This PDF could not be read."
            failure.isHidden = false
            return
        }
        pdf.document = document
        pdfMarks = []
        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
        chrome.show(source: "PDF – \(document.pageCount) \(document.pageCount == 1 ? "PAGE" : "PAGES")", title: title ?? source.name,
                    metrics: session.metrics)
        chrome.icon = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
        let page = min(document.pageCount - 1, Int(ReaderPlace.saved(url, reading: false) * Double(document.pageCount)))
        if page > 0, let at = document.page(at: page) { pdf.go(to: at) }
        markPDF()
    }

    /// The passages highlighted before, marked on the PDF's pages: not written into it.
    private func markPDF() {
        guard let document = pdf.document else { return }
        for (page, mark) in pdfMarks { page.removeAnnotation(mark) }
        pdfMarks = []
        for passage in highlights {
            var found = document.findString(passage, withOptions: .caseInsensitive)
            if found.isEmpty {
                found = document.findString(passage.replacingOccurrences(of: "\n", with: " "), withOptions: .caseInsensitive)
            }
            for line in found.flatMap({ $0.selectionsByLine() }) {
                for page in line.pages {
                    let mark = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                    mark.color = NSColor.systemYellow.withAlphaComponent(0.45)
                    page.addAnnotation(mark)
                    pdfMarks.append((page, mark))
                }
            }
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
        if source.isPDF {
            // The page it is at, as a part of the way through: its middle, to come back to it.
            if let document = pdf.document, let page = pdf.currentPage, document.pageCount > 0 {
                ReaderPlace.save((Double(document.index(for: page)) + 0.5) / Double(document.pageCount), for: url, reading: false)
            }
            return
        }
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
        pdf.frame = NSRect(x: 0, y: PaneChrome.height, width: bounds.width, height: max(0, bounds.height - PaneChrome.height))
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

    /// Scripts': the PDF's pages in sight drawn into a picture of the window
    /// — its own drawing in layers a picture of the view leaves out.
    func drawPDFForScript(in view: NSView) {
        guard source.isPDF, !pdf.isHidden else { return }
        NSGraphicsContext.saveGraphicsState()
        let clip = pdf.convert(pdf.bounds, to: view)
        NSBezierPath(rect: NSRect(x: clip.minX, y: view.bounds.height - clip.maxY, width: clip.width, height: clip.height)).addClip()
        for page in pdf.visiblePages {
            let box = pdf.convert(pdf.convert(page.bounds(for: pdf.displayBox), from: page), to: view)
            let rect = NSRect(x: box.minX, y: view.bounds.height - box.maxY, width: box.width, height: box.height)
            page.thumbnail(of: NSSize(width: rect.width * 2, height: rect.height * 2), for: pdf.displayBox).draw(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Highlighting

    /// Scripts': the words found in the page, chosen, and highlighted.
    func highlightForScript(_ words: String) {
        if source.isPDF {
            guard let found = pdf.document?.findString(words, withOptions: .caseInsensitive).first else { return }
            pdf.setCurrentSelection(found, animate: false)
            return highlightSelection()
        }
        guard let data = try? JSONEncoder().encode(words), let quoted = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.find(\(quoted))") { [weak self] _, _ in self?.highlightSelection() }
    }

    /// The passage chosen: marked in the page, and written into the note —
    /// under its Highlights, or under the row linking to what is read.
    func highlightSelection() {
        if source.isPDF {
            let passage = pdf.currentSelection?.string ?? ""
            write(passage)
            pdf.clearSelection()
            return markPDF()
        }
        web.evaluateJavaScript("prismHighlight()") { [weak self] value, _ in
            self?.write(value as? String ?? "")
        }
    }

    private func write(_ passage: String) {
        let passage = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !passage.isEmpty else { return NSSound.beep() }
        let address = source.address
        session.change(notePath) { source in
            let after = WebCapture.highlighting(passage, in: source, of: address)
            return after == source ? nil : after
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

/// A PDF read: Highlight in its menu, a passage chosen, and ⇧⌘H.
final class ReaderPDFView: PDFView {
    var onHighlight: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard currentSelection?.string?.isEmpty == false else { return menu }
        let highlight = NSMenuItem(title: "Highlight", action: #selector(highlight), keyEquivalent: "")
        highlight.target = self
        highlight.image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: nil)
        menu.insertItem(highlight, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func highlight() { onHighlight?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "h",
           window?.firstResponder.map({ ($0 as? NSView)?.isDescendant(of: self) == true }) == true {
            onHighlight?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The reader's controls, floating on glass over its top: at the left, the
/// page's icon, its site and how long it takes, its title — clicked, back
/// to the top; at the right, ‹ › through what the note has to read, when
/// it has more than one, the reader, the type, and ×.
final class ReaderChrome: NSView {
    var onClose: (() -> Void)?
    var onType: ((NSView) -> Void)?
    var onTop: (() -> Void)?
    var onReader: (() -> Void)?
    var onStep: ((Int) -> Void)?

    private let band = GlassCapsule()
    private let right = GlassCapsule()
    private let iconView = NSImageView()
    private let source = NSTextField(labelWithString: "")
    private let headline = NSTextField(labelWithString: "")
    private let previous = CloseButton(symbol: "chevron.left", pointSize: 11, toolTip: "What the Note Links to Before (⌥⌘←)")
    private let next = CloseButton(symbol: "chevron.right", pointSize: 11, toolTip: "What the Note Links to Next (⌥⌘→)")
    private let count = NSTextField(labelWithString: "")
    private let divider = RuleView()
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

    /// Which of the note's sources is read, of how many: ‹ › for more than one.
    var position = (0, 1) {
        didSet {
            count.stringValue = "\(position.0 + 1) of \(position.1)"
            previous.isEnabled = position.0 > 0
            next.isEnabled = position.0 < position.1 - 1
            previous.alphaValue = previous.isEnabled ? 1 : 0.35
            next.alphaValue = next.isEnabled ? 1 : 0.35
            needsLayout = true
        }
    }

    /// A PDF: no reader, no type, of its own.
    var isPDF = false { didSet { needsLayout = true } }

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
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        count.textColor = Ink.secondary
        count.alignment = .center
        right.content.addSubview(count)
        right.content.addSubview(divider)
        for (button, action) in [(previous, #selector(previousClicked)), (next, #selector(nextClicked)), (reader, #selector(readerClicked)),
                                 (type, #selector(typeClicked)), (close, #selector(closeClicked))] {
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
    @objc private func previousClicked() { onStep?(-1) }
    @objc private func nextClicked() { onStep?(1) }
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
        // ‹ 2 of 3 ›, a rule, then what the page is read in.
        let many = position.1 > 1
        for view in [previous, next, count, divider] as [NSView] { view.isHidden = !many }
        previous.frame = NSRect(x: 4, y: 4, width: many ? 24 : 0, height: side - 8)
        let countWidth = many ? ceil(count.intrinsicContentSize.width) + 4 : 0
        count.frame = NSRect(x: previous.frame.maxX, y: (side - 15) / 2, width: countWidth, height: 15)
        next.frame = NSRect(x: count.frame.maxX, y: 4, width: many ? 24 : 0, height: side - 8)
        divider.frame = NSRect(x: next.frame.maxX + 4, y: 9, width: 1, height: side - 18)
        var x = many ? divider.frame.maxX + 4 : 4
        reader.isHidden = isPDF
        reader.frame = NSRect(x: x, y: 4, width: isPDF ? 0 : 28, height: side - 8)
        x = reader.frame.maxX
        type.isHidden = !reading || isPDF
        type.frame = NSRect(x: x, y: 4, width: type.isHidden ? 0 : 28, height: side - 8)
        close.frame = NSRect(x: type.frame.maxX, y: 4, width: 26, height: side - 8)
        right.frame = NSRect(x: bounds.width - 12 - (close.frame.maxX + 4), y: y, width: close.frame.maxX + 4, height: side)
        // The band: as wide as what it says, as far as the room goes.
        // What they say, measured: a truncating label's own size is what it was last given.
        let words = ceil(max(source.attributedStringValue.size().width, headline.attributedStringValue.size().width)) + 4
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
