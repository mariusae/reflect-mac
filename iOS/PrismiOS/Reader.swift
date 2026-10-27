import UIKit
import WebKit
import ReflectCore
import PrismCore

/// A link note's page, the whole screen: as the site has it — or, the
/// reader turned on, its words alone, set in Chronicle on the paper, the
/// site's chrome, its ads, its menus left behind — a band at the top saying
/// where it is from, gone as the page is read down. Read down to
/// anywhere, it opens there again, however the app was left. A passage
/// chosen and highlighted goes into the note, under its Highlights, and is
/// marked there each time the page is read again.
final class ReaderController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler {
    private let store: PrismStore
    /// The link note it is read from: its highlights go there.
    let notePath: String
    let url: URL
    private var web: ReaderWebView!
    private let band = UIVisualEffectView(effect: UIGlassEffect())
    private let icon = UIImageView()
    private let back = UIButton(type: .system)
    private let type = UIButton(type: .system)
    private let reader = UIButton(type: .system)
    private let source = UILabel()
    private let headline = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failure = UILabel()
    private var restored = false
    /// Its words alone, in the reader: else the page as the site has it.
    private var reading: Bool
    private var titleWatch: NSKeyValueObservation?
    private var offsetWatch: NSKeyValueObservation?
    private var bandHidden = false
    private var lastY: CGFloat = 0
    private var travel: CGFloat = 0

    init(store: PrismStore, notePath: String, url: URL) {
        self.store = store
        self.notePath = notePath
        self.url = url
        reading = ReaderPlace.reads(url)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Which link note has its page open in the reader: open again on coming back.
    static var openNote: String? {
        get { UserDefaults.standard.string(forKey: "Reader.openNote") }
        set { UserDefaults.standard.set(newValue, forKey: "Reader.openNote") }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Ink.paper
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController
        controller.add(WeakMessages(self), name: "scrolled")
        controller.addUserScript(ReaderPage.userScript)
        web = ReaderWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = Ink.paper
        web.scrollView.backgroundColor = Ink.paper
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.onHighlight = { [weak self] in self?.highlightSelection() }
        web.allowsBackForwardNavigationGestures = false
        titleWatch = web.observe(\.title) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.showSite() }
        }
        offsetWatch = web.scrollView.observe(\.contentOffset) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scrolled() }
        }
        view.addSubview(web)

        band.cornerConfiguration = .uniformCorners(radius: .fixed(22))
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 6
        icon.clipsToBounds = true
        icon.image = UIImage(systemName: "globe")
        icon.tintColor = Ink.secondary
        source.font = .systemFont(ofSize: 11, weight: .semibold)
        source.textColor = Ink.secondary
        headline.font = Typeface.current.body(14, weight: .medium)
        headline.textColor = Ink.text
        headline.lineBreakMode = .byTruncatingTail
        back.setImage(UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        back.tintColor = Ink.text
        back.accessibilityLabel = "Back to the Note"
        back.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        type.setImage(UIImage(systemName: "textformat.size", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)), for: .normal)
        type.tintColor = Ink.text
        type.accessibilityLabel = "Type"
        type.showsMenuAsPrimaryAction = true
        type.menu = typeMenu()
        reader.tintColor = Ink.text
        reader.addAction(UIAction { [weak self] _ in self?.toggleReading() }, for: .touchUpInside)
        for view in [back, icon, source, headline, reader, type] as [UIView] { band.contentView.addSubview(view) }
        view.addSubview(band)
        band.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tappedBand)))
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
        failure.numberOfLines = 0
        failure.textAlignment = .center
        failure.font = Typeface.current.body(16)
        failure.textColor = Ink.secondary
        failure.isHidden = true
        view.addSubview(failure)

        NotificationCenter.default.addObserver(self, selector: #selector(leaving), name: UIApplication.willResignActiveNotification, object: nil)
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The whole screen the page's: the app's bar away while it is read.
        NotificationCenter.default.post(name: .prismReader, object: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Self.openNote = notePath
    }

    private func close() {
        if let navigation = navigationController { navigation.popViewController(animated: true) } else { dismiss(animated: true) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        savePlace()
        NotificationCenter.default.post(name: .prismReader, object: false)
        // Gone back from: not open again on coming back.
        if isMovingFromParent || isBeingDismissed { Self.openNote = nil }
    }

    @objc private func leaving() { savePlace() }

    @objc private func tappedBand() {
        web.evaluateJavaScript("window.scrollTo({top: 0, behavior: 'smooth'})")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top
        web.frame = view.bounds
        let bandHeight: CGFloat = 52
        band.frame = CGRect(x: 12, y: top + 4, width: view.bounds.width - 24, height: bandHeight)
        back.frame = CGRect(x: 4, y: 0, width: 40, height: bandHeight)
        icon.frame = CGRect(x: back.frame.maxX, y: (bandHeight - 26) / 2, width: 26, height: 26)
        type.isHidden = !reading
        type.frame = CGRect(x: band.bounds.width - (reading ? 48 : 4), y: 0, width: reading ? 44 : 0, height: bandHeight)
        reader.frame = CGRect(x: type.frame.minX - 40, y: 0, width: 40, height: bandHeight)
        let textX = icon.frame.maxX + 10
        source.frame = CGRect(x: textX, y: 9, width: reader.frame.minX - textX - 4, height: 14)
        headline.frame = CGRect(x: textX, y: 24, width: reader.frame.minX - textX - 4, height: 19)
        // The words start under the band, and scroll up under it.
        let inset = band.frame.maxY + 12
        if web.scrollView.contentInset.top != inset {
            web.scrollView.contentInset = UIEdgeInsets(top: inset, left: 0, bottom: view.safeAreaInsets.bottom + 40, right: 0)
            web.scrollView.verticalScrollIndicatorInsets.top = inset
        }
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        failure.frame = CGRect(x: 32, y: view.bounds.midY - 60, width: view.bounds.width - 64, height: 120)
    }

    // MARK: The page, or its words

    private func load() {
        restored = false
        failure.isHidden = true
        reader.setImage(UIImage(systemName: reading ? "doc.plaintext.fill" : "doc.plaintext",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)), for: .normal)
        reader.accessibilityLabel = reading ? "The Page as the Site Has It" : "Reader"
        view.setNeedsLayout()
        showSite()
        setBandHidden(false)
        guard reading else {
            web.load(URLRequest(url: url))
            return
        }
        if let cached = ReaderArticle.cached(url) { return show(cached) }
        spinner.startAnimating()
        ReaderArticle.fetch(url) { [weak self] article in
            guard let self else { return }
            spinner.stopAnimating()
            guard reading else { return }
            guard let article else {
                failure.text = "This page could not be read.\n\(url.host() ?? "")"
                failure.isHidden = false
                return
            }
            show(article)
        }
    }

    /// The reader on, or off: the page set again, where it was read to in that.
    private func toggleReading() {
        savePlace()
        reading.toggle()
        ReaderPlace.setReads(reading, for: url)
        spinner.stopAnimating()
        load()
    }

    /// The band as the site has it: its address, its title.
    private func showSite() {
        guard !reading else { return }
        source.text = ((web.url ?? url).host() ?? "").replacingOccurrences(of: "www.", with: "").uppercased()
        headline.text = web.title.flatMap { $0.isEmpty ? nil : $0 } ?? SliceBlock.name(notePath, store: store)
    }

    /// Where its place is kept: in the reader, the note's page; else the page the site is on.
    private var placeURL: URL { reading ? url : web.url ?? url }

    // MARK: The band, out of the way

    /// Read down: the band gone; read back up, or at the top, back.
    private func scrolled() {
        let scroll = web.scrollView
        let y = scroll.contentOffset.y + scroll.adjustedContentInset.top
        let delta = y - lastY
        lastY = y
        if y <= 4 {
            travel = 0
            return setBandHidden(false)
        }
        // Read down by hand: not set there, where it was read to.
        guard scroll.isTracking || scroll.isDecelerating else { return }
        travel = (delta > 0) == (travel > 0) ? travel + delta : delta
        if travel > 24 { setBandHidden(true) } else if travel < -16 { setBandHidden(false) }
    }

    private func setBandHidden(_ hidden: Bool) {
        guard hidden != bandHidden else { return }
        bandHidden = hidden
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) { [self] in
            band.alpha = hidden ? 0 : 1
            band.transform = hidden ? CGAffineTransform(translationX: 0, y: -(band.frame.maxY + 8)) : .identity
        }
    }

    private func show(_ article: ReaderArticle) {
        headline.text = article.title.isEmpty ? headline.text : article.title
        source.text = "\(article.site.uppercased()) – \(article.minutes) MIN READ"
        icon.image = UIImage(systemName: "globe")
        if let address = article.icon, let iconURL = URL(string: address) {
            URLSession.shared.dataTask(with: iconURL) { [weak self] data, _, _ in
                guard let data, let image = UIImage(data: data) else { return }
                DispatchQueue.main.async { self?.icon.image = image }
            }.resume()
        }
        web.loadHTMLString(ReaderPage.html(article, style: .current), baseURL: url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The passages highlighted before, marked again; then where it was read to.
        if let marking = ReaderPage.marking(WebCapture.highlights(in: store.text(notePath))) { webView.evaluateJavaScript(marking) }
        if !reading { faviconFromPage() }
        // The first page in, where it was read to: not a link followed from it.
        guard !restored else { return }
        restored = true
        webView.evaluateJavaScript("prismRestore(\(ReaderPlace.saved(url, reading: reading)))")
    }

    /// The site's icon, as its page names it.
    private func faviconFromPage() {
        web.evaluateJavaScript("(function(){var l=document.querySelector('link[rel~=\"apple-touch-icon\"], link[rel~=\"icon\"]');return l?l.href:location.origin+'/favicon.ico';})()") { [weak self] value, _ in
            guard let address = value as? String, let iconURL = URL(string: address) else { return }
            URLSession.shared.dataTask(with: iconURL) { data, _, _ in
                guard let data, let image = UIImage(data: data) else { return }
                DispatchQueue.main.async { self?.icon.image = image }
            }.resume()
        }
    }

    /// A link in the reader: out to the browser. In the site's page, followed there.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if reading, action.navigationType == .linkActivated, let target = action.request.url {
            UIApplication.shared.open(target)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "scrolled", let fraction = message.body as? Double else { return }
        ReaderPlace.save(fraction, for: placeURL, reading: reading)
    }

    private func savePlace() {
        web?.evaluateJavaScript("prismPlace()") { [placeURL, reading] value, _ in
            if let fraction = value as? Double { ReaderPlace.save(fraction, for: placeURL, reading: reading) }
        }
    }

    // MARK: Type

    /// Aa: the size, the face, the spacing — kept, for every page read.
    private func typeMenu() -> UIMenu {
        UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            guard let self else { return done([]) }
            let style = ReaderStyle.current
            let sizes = UIMenu(options: .displayInline, children: [
                UIAction(title: "Smaller", image: UIImage(systemName: "textformat.size.smaller"), attributes: .keepsMenuPresented) { [weak self] _ in
                    self?.restyle { $0.step(-1) }
                },
                UIAction(title: "Larger", image: UIImage(systemName: "textformat.size.larger"), attributes: .keepsMenuPresented) { [weak self] _ in
                    self?.restyle { $0.step(1) }
                },
            ])
            let faces = UIMenu(title: "Typeface", options: .displayInline, children: ReaderStyle.Face.allCases.map { face in
                UIAction(title: face.title, state: style.face == face ? .on : .off) { [weak self] _ in self?.restyle { $0.face = face } }
            })
            let spacings = UIMenu(title: "Spacing", options: .displayInline, children: ReaderStyle.Spacing.allCases.map { spacing in
                UIAction(title: spacing.title, state: style.spacing == spacing ? .on : .off) { [weak self] _ in self?.restyle { $0.spacing = spacing } }
            })
            done([sizes, faces, spacings])
        }])
    }

    /// The type changed: kept, and the page set in it at once, where it was.
    private func restyle(_ change: (inout ReaderStyle) -> Void) {
        var style = ReaderStyle.current
        change(&style)
        ReaderStyle.current = style
        web.evaluateJavaScript(style.script)
    }

    // MARK: Highlighting

    /// The passage chosen: marked in the page, and written into the note, under its Highlights.
    private func highlightSelection() {
        web.evaluateJavaScript("prismHighlight()") { [weak self] value, _ in
            guard let self, let passage = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !passage.isEmpty else { return }
            let before = store.text(notePath)
            let after = WebCapture.highlighting(passage, in: before)
            guard after != before else { return }
            store.write(after, path: notePath)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}

/// The reader's page, its text chosen: Highlight first in the menu.
final class ReaderWebView: WKWebView {
    var onHighlight: (() -> Void)?

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        let highlight = UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in self?.onHighlight?() }
        builder.insertChild(UIMenu(options: .displayInline, children: [highlight]), atStartOfMenu: .standardEdit)
    }
}

extension ReaderController {
    /// A link note's page, in the reader: pushed on, from the right — or,
    /// with no stack to go on, over everything.
    @discardableResult
    static func open(notePath: String, store: PrismStore, from controller: UIViewController, animated: Bool = true) -> Bool {
        guard let address = WebCapture.url(in: store.text(notePath)), let url = URL(string: address) else { return false }
        let reader = ReaderController(store: store, notePath: notePath, url: url)
        if let navigation = controller.navigationController {
            navigation.pushViewController(reader, animated: animated)
        } else {
            reader.modalPresentationStyle = .fullScreen
            controller.present(reader, animated: animated)
        }
        return true
    }
}

extension Notification.Name {
    /// The reader shown — the app's bar away — or gone.
    static let prismReader = Notification.Name("PrismReader")
}
