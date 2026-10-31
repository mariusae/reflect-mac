import Foundation
import WebKit
import CryptoKit

// The reader's, whatever it is shown on: a page's words taken out of it,
// kept, set as a page to read — where it was read to, and in what type.

/// A message handler not keeping its controller: the web view's user content keeps it.
public final class WeakMessages: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    public init(_ target: WKScriptMessageHandler) { self.target = target }
    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

// MARK: - Where it was read to

/// How far down each page was read, by its address: kept across launches.
/// How far down each page was read, by its address — as the site sets
/// it, and as the reader does — and which it was read in: kept across launches.
public enum ReaderPlace {
    private static func key(_ url: URL, reading: Bool) -> String { (reading ? "Reader.place." : "Reader.webPlace.") + url.absoluteString }

    public static func saved(_ url: URL, reading: Bool) -> Double { UserDefaults.standard.double(forKey: key(url, reading: reading)) }

    public static func save(_ fraction: Double, for url: URL, reading: Bool) {
        UserDefaults.standard.set(max(0, min(1, fraction)), forKey: key(url, reading: reading))
    }

    /// Read in the reader, its words alone, when last read — else the page as the site has it.
    public static func reads(_ url: URL) -> Bool { UserDefaults.standard.bool(forKey: "Reader.reads." + url.absoluteString) }

    public static func setReads(_ reads: Bool, for url: URL) {
        UserDefaults.standard.set(reads ? true : nil, forKey: "Reader.reads." + url.absoluteString)
    }
}

// MARK: - The article

/// A page's words, taken out of the page: its title, its site, its icon,
/// its body as plain HTML — kept on the phone, to read again at once.
public struct ReaderArticle: Codable {
    public var title: String
    public var site: String
    public var byline: String?
    public var icon: String?
    public var html: String
    public var words: Int

    /// How long it takes to read, at a reader's pace.
    public var minutes: Int { max(1, Int((Double(words) / 230).rounded())) }

    private static var folder: URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Prism/Reader", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func file(_ url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(String(digest.prefix(32)) + ".json")
    }

    public static func cached(_ url: URL) -> ReaderArticle? {
        guard let data = try? Data(contentsOf: file(url)) else { return nil }
        return try? JSONDecoder().decode(ReaderArticle.self, from: data)
    }

    private func keep(for url: URL) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.file(url), options: .atomic) }
    }

    /// The page loaded, out of sight, as a browser would — its scripts run,
    /// for pages made by them — and its words taken out.
    @MainActor
    public static func fetch(_ url: URL, done: @escaping (ReaderArticle?) -> Void) {
        let loader = ReaderLoader(url: url) { article in
            article?.keep(for: url)
            done(article)
        }
        loader.start()
    }
}

// MARK: - A PDF on the web

/// A PDF a note links to, fetched to read as the graph's own are — kept on
/// the device, to read again at once, offline too.
public enum ReaderPDF {
    private static var folder: URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Prism/Reader PDFs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func file(_ url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(String(digest.prefix(32)) + ".pdf")
    }

    /// Fetched before: its file.
    public static func cached(_ url: URL) -> URL? {
        let file = file(url)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Fetched, and kept: its file — nil, not to be had, or not a PDF after
    /// all, a page asking to sign in, say.
    public static func fetch(_ url: URL, done: @escaping @MainActor (URL?) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("application/pdf,*/*;q=0.8", forHTTPHeaderField: "Accept")
        URLSession.shared.downloadTask(with: request) { downloaded, response, _ in
            var kept: URL?
            if let downloaded, (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
               let handle = try? FileHandle(forReadingFrom: downloaded) {
                // A PDF says so in its first bytes.
                let head = (try? handle.read(upToCount: 1024)) ?? Data()
                try? handle.close()
                if head.range(of: Data("%PDF".utf8)) != nil {
                    let file = file(url)
                    try? FileManager.default.removeItem(at: file)
                    if (try? FileManager.default.moveItem(at: downloaded, to: file)) != nil { kept = file }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(kept) } }
        }.resume()
    }
}

/// A page loaded in a web view no one sees, its words taken out once it
/// has loaded — or given up on after a while.
@MainActor
private final class ReaderLoader: NSObject, WKNavigationDelegate {
    private let url: URL
    private var done: ((ReaderArticle?) -> Void)?
    private let web: WKWebView
    private var finished = false
    /// Kept till done: nothing else holds it.
    private static var loading: Set<ReaderLoader> = []

    init(url: URL, done: @escaping (ReaderArticle?) -> Void) {
        self.url = url
        self.done = done
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        super.init()
        web.navigationDelegate = self
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    }

    func start() {
        Self.loading.insert(self)
        web.load(URLRequest(url: url, timeoutInterval: 30))
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.extract() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A moment for what its scripts put in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.extract() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }

    private func extract() {
        guard !finished else { return }
        web.evaluateJavaScript(ReaderPage.extraction) { [weak self] value, _ in
            guard let self else { return }
            guard let json = value as? String, let data = json.data(using: .utf8),
                  let article = try? JSONDecoder().decode(ReaderArticle.self, from: data), article.words > 30 else { return finish(nil) }
            finish(article)
        }
    }

    private func finish(_ article: ReaderArticle?) {
        guard !finished else { return }
        finished = true
        done?(article)
        done = nil
        web.stopLoading()
        Self.loading.remove(self)
    }
}

// MARK: - The page, as read

public enum ReaderPage {
    /// The passages highlighted before, marked again in the page shown.
    public static func marking(_ passages: [String]) -> String? {
        guard !passages.isEmpty, let data = try? JSONEncoder().encode(passages), let list = String(data: data, encoding: .utf8) else { return nil }
        return "prismMarkAll(\(list))"
    }

    /// Takes a page's words out of it: the element with the most paragraph
    /// text in it — an article, the main part, else the body — its scripts,
    /// menus, forms and asides let go, only the plain marks of text kept.
    static let extraction = #"""
    (function() {
      function textOf(el) { return (el.innerText || '').replace(/\s+/g, ' ').trim(); }
      var candidates = Array.from(document.querySelectorAll('article, main, [role=main], .post, .entry-content, .article-body, .post-content, #content, .content'));
      candidates.push(document.body);
      var best = document.body, bestScore = 0;
      var pScore = function(el) { return Array.from(el.querySelectorAll('p')).reduce(function(n, p) { return n + textOf(p).length; }, 0); };
      // Any element holding many paragraphs, too: the closest such.
      Array.from(document.querySelectorAll('div, section')).forEach(function(el) {
        var direct = Array.from(el.children).filter(function(c) { return c.tagName === 'P'; }).length;
        if (direct >= 3) candidates.push(el);
      });
      candidates.forEach(function(el) {
        var score = pScore(el);
        // The tightest: a little less for a bigger box.
        score -= textOf(el).length * 0.05;
        if (score > bestScore) { bestScore = score; best = el; }
      });
      var root = best.cloneNode(true);
      root.querySelectorAll('script, style, noscript, nav, aside, footer, header, form, button, iframe, svg, input, select, textarea, [role=navigation], [aria-hidden=true], .share, .social, .newsletter, .subscribe, .related, .comments').forEach(function(el) { el.remove(); });
      var keep = {A:1, P:1, H1:1, H2:1, H3:1, H4:1, H5:1, H6:1, UL:1, OL:1, LI:1, BLOCKQUOTE:1, EM:1, I:1, STRONG:1, B:1, CODE:1, PRE:1, IMG:1, FIGURE:1, FIGCAPTION:1, BR:1, HR:1, SUP:1, SUB:1, TABLE:1, TR:1, TD:1, TH:1, TBODY:1, THEAD:1};
      function clean(el) {
        Array.from(el.children).forEach(function(child) {
          clean(child);
          if (!keep[child.tagName]) {
            while (child.firstChild) el.insertBefore(child.firstChild, child);
            child.remove();
            return;
          }
          var href = child.getAttribute('href'), src = child.getAttribute('src') || child.getAttribute('data-src'), alt = child.getAttribute('alt');
          Array.from(child.attributes).forEach(function(a) { child.removeAttribute(a.name); });
          if (child.tagName === 'A' && href) child.setAttribute('href', new URL(href, location.href).href);
          if (child.tagName === 'IMG') {
            if (!src) { child.remove(); return; }
            child.setAttribute('src', new URL(src, location.href).href);
            if (alt) child.setAttribute('alt', alt);
          }
        });
      }
      clean(root);
      // Its title, as the page says it; drop it from the body, if it begins with it.
      var meta = function(name) { var el = document.querySelector('meta[property="' + name + '"], meta[name="' + name + '"]'); return el ? el.getAttribute('content') : null; };
      var title = meta('og:title') || (document.querySelector('h1') ? textOf(document.querySelector('h1')) : document.title) || '';
      var first = root.querySelector('h1');
      if (first && textOf(first) === title.trim()) first.remove();
      var site = meta('og:site_name') || location.hostname.replace(/^www\./, '');
      var icon = document.querySelector('link[rel~="apple-touch-icon"], link[rel~="icon"]');
      var words = textOf(root).split(' ').length;
      return JSON.stringify({ title: title.trim(), site: site, byline: meta('author'), icon: icon ? new URL(icon.getAttribute('href'), location.href).href : null, html: root.innerHTML, words: words });
    })();
    """#

    /// Chronicle, and Ideal Sans, in the page itself: no file of the app's to fetch.
    @MainActor private static let faces: String = {
        // The app's fonts — or, run from the package, Frameworks/'s.
        let places = [Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
                      URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                          .deletingLastPathComponent().appendingPathComponent("Frameworks/hoefler")].compactMap { $0 }
        let faces: [(family: String, file: String, weight: Int, style: String)] = [
            ("Chronicle", "ChronicleSSm-Book.otf", 400, "normal"), ("Chronicle", "ChronicleSSm-BookItalic.otf", 400, "italic"),
            ("Chronicle", "ChronicleSSm-Medium.otf", 500, "normal"), ("Chronicle", "ChronicleSSm-Bold.otf", 700, "normal"),
            ("Chronicle", "ChronicleSSm-BoldItalic.otf", 700, "italic"),
            ("Ideal", "IdealSansSSm-Book-Pro.otf", 400, "normal"), ("Ideal", "IdealSansSSm-BookItalic-Pro.otf", 400, "italic"),
            ("Ideal", "IdealSansSSm-Semibold-Pro.otf", 700, "normal"), ("Ideal", "IdealSansSSm-SemiboldItalic-Pro.otf", 700, "italic"),
        ]
        return faces.compactMap { face in
            guard let data = places.lazy.compactMap({ try? Data(contentsOf: $0.appendingPathComponent(face.file)) }).first else { return nil }
            return "@font-face { font-family: \(face.family); src: url(data:font/otf;base64,\(data.base64EncodedString())) format('opentype'); "
                + "font-weight: \(face.weight); font-style: \(face.style); }"
        }.joined(separator: "\n")
    }()

    /// Where it was read to, a passage highlighted, those before marked:
    /// in every page the view loads, the reader's own or the site's.
    public static let script = #"""
var prismTimer = null;
// Highlights' yellow, the page's own or the reader's.
(function() {
  var style = document.createElement('style');
  style.textContent = 'mark.prism { background: rgba(255, 214, 10, .45); color: inherit; border-radius: 2px; } '
    + '@media (prefers-color-scheme: dark) { mark.prism { background: rgba(217, 179, 51, .40); } }';
  (document.head || document.documentElement).appendChild(style);
})();
function prismPlace() {
  var max = document.documentElement.scrollHeight - window.innerHeight;
  return max > 0 ? Math.max(0, Math.min(1, window.scrollY / max)) : 0;
}
// Whether the page pins something along its top — a header kept in
// sight as it is read — told to whoever listens, when it changes.
var prismPinnedLast = null;
function prismPinned() {
  for (var el = document.elementFromPoint(window.innerWidth / 2, 1); el && el !== document.body && el !== document.documentElement; el = el.parentElement) {
    var position = getComputedStyle(el).position;
    if (position === 'fixed' || position === 'sticky') return true;
  }
  return false;
}
function prismTellPinned() {
  var pinned = window.webkit.messageHandlers.pinned;
  if (!pinned) return;
  var now = prismPinned();
  if (now !== prismPinnedLast) { prismPinnedLast = now; pinned.postMessage(now); }
}
window.addEventListener('load', function() { prismTellPinned(); setTimeout(prismTellPinned, 1000); });
window.addEventListener('scroll', function() {
  var moved = window.webkit.messageHandlers.moved;
  if (moved) moved.postMessage(window.scrollY);
  prismTellPinned();
  clearTimeout(prismTimer);
  prismTimer = setTimeout(function() { window.webkit.messageHandlers.scrolled.postMessage(prismPlace()); }, 250);
}, { passive: true });
function prismRestore(fraction) {
  var go = function() {
    var max = document.documentElement.scrollHeight - window.innerHeight;
    window.scrollTo(0, fraction * max);
  };
  go();
  // Again once its pictures are in, and the page longer.
  window.addEventListener('load', go);
  setTimeout(go, 400);
  setTimeout(go, 1500);
}
function prismWrap(range) {
  var nodes = [];
  var walker = document.createTreeWalker(range.commonAncestorContainer, NodeFilter.SHOW_TEXT, null);
  if (range.commonAncestorContainer.nodeType === Node.TEXT_NODE) nodes.push(range.commonAncestorContainer);
  while (walker.nextNode()) { if (range.intersectsNode(walker.currentNode)) nodes.push(walker.currentNode); }
  nodes.forEach(function(node) {
    var start = node === range.startContainer ? range.startOffset : 0;
    var end = node === range.endContainer ? range.endOffset : node.data.length;
    if (end <= start || !node.data.slice(start, end).trim()) return;
    var piece = node.splitText(start);
    piece.splitText(end - start);
    var mark = document.createElement('mark');
    mark.className = 'prism';
    piece.parentNode.insertBefore(mark, piece);
    mark.appendChild(piece);
  });
}
function prismStyle(face, size, leading) {
  var place = prismPlace();
  var root = document.documentElement.style;
  root.setProperty('--face', face);
  root.setProperty('--size', size + 'px');
  root.setProperty('--leading', leading);
  var max = document.documentElement.scrollHeight - window.innerHeight;
  window.scrollTo(0, place * max);
}
function prismHighlight() {
  var selection = window.getSelection();
  if (!selection.rangeCount) return '';
  var text = selection.toString();
  prismWrap(selection.getRangeAt(0));
  selection.removeAllRanges();
  return text;
}
function prismMarkAll(passages) {
  passages.forEach(function(passage) {
    var words = passage.replace(/\s+/g, ' ').trim();
    if (!words) return;
    window.getSelection().removeAllRanges();
    if (window.find(words, false, false, false, false, false, false)) {
      var selection = window.getSelection();
      if (selection.rangeCount) prismWrap(selection.getRangeAt(0));
    }
  });
  window.getSelection().removeAllRanges();
  window.scrollTo(0, window.scrollY);
}
"""#

    @MainActor
    public static var userScript: WKUserScript {
        WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    /// The page's paper and ink, light and dark: the app's own.
    public struct Paper: Sendable {
        public var paper: (light: String, dark: String)
        public var ink: (light: String, dark: String)
        public var soft: (light: String, dark: String)

        public init(paper: (String, String), ink: (String, String), soft: (String, String)) {
            self.paper = paper
            self.ink = ink
            self.soft = soft
        }

        /// The phone's: white, and near black.
        public static let white = Paper(paper: ("#ffffff", "#101010"), ink: ("#26231f", "#ece8e1"), soft: ("#6f6a63", "#a19b92"))
    }

    /// `top`: room left over the title, for what floats over the page's top.
    @MainActor
    public static func html(_ article: ReaderArticle, style: ReaderStyle, paper: Paper = .white, top: Int = 0) -> String {
        let title = article.title.replacingOccurrences(of: "<", with: "&lt;")
        let byline = article.byline.map { "<p class=\"byline\">" + $0.replacingOccurrences(of: "<", with: "&lt;") + "</p>" } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>
        \(faces)
        :root { \(style.css) }
        :root { --paper: \(paper.paper.light); --ink: \(paper.ink.light); --soft: \(paper.soft.light); --rule: rgba(0,0,0,.12); --mark: rgba(255, 214, 10, .45); color-scheme: light dark; }
        @media (prefers-color-scheme: dark) { :root { --paper: \(paper.paper.dark); --ink: \(paper.ink.dark); --soft: \(paper.soft.dark); --rule: rgba(255,255,255,.14); --mark: rgba(217, 179, 51, .40); } }
        html { -webkit-text-size-adjust: 100%; }
        body { margin: 0; padding: \(top)px 24px 80px; background: var(--paper); color: var(--ink);
               font-family: var(--face); font-weight: 400; font-size: var(--size); line-height: var(--leading); font-feature-settings: "onum" 1, "kern" 1; hanging-punctuation: first;
               -webkit-hyphens: auto; hyphens: auto; word-wrap: break-word; }
        h1.title { font-family: var(--face); font-weight: 700; font-size: calc(var(--size) * 1.5); line-height: 1.15; margin: 8px 0 6px; letter-spacing: -0.01em; }
        .byline { color: var(--soft); font-size: 15px; margin: 0 0 28px; font-feature-settings: "smcp" 1; letter-spacing: .04em; }
        h2, h3, h4 { font-weight: 700; line-height: 1.25; margin: 1.6em 0 .5em; }
        h2 { font-size: 24px; } h3 { font-size: 21px; } h4 { font-size: 19px; }
        p { margin: 0 0 1em; }
        a { color: inherit; text-decoration-color: var(--soft); text-decoration-thickness: 1px; text-underline-offset: 3px; }
        img { max-width: 100%; height: auto; display: block; margin: 1.2em auto; border-radius: 6px; }
        figure { margin: 1.4em 0; } figcaption { color: var(--soft); font-size: 15px; line-height: 1.4; }
        blockquote { margin: 1.2em 0; padding-left: 18px; border-left: 2px solid var(--rule); color: var(--soft); font-style: italic; }
        pre, code { font-family: ui-monospace, Menlo, monospace; font-size: 15px; }
        pre { overflow-x: auto; padding: 12px; background: var(--rule); border-radius: 6px; }
        hr { border: 0; border-top: 1px solid var(--rule); margin: 2em 0; }
        ul, ol { padding-left: 1.2em; } li { margin: .3em 0; }
        table { border-collapse: collapse; font-size: 16px; } td, th { border: 1px solid var(--rule); padding: 4px 8px; }
        #prism-column { max-width: 36em; margin: 0 auto; }
        </style></head><body>
        <div id="prism-column"><h1 class="title">\(title)</h1>\(byline)
        <div id="prism-article">\(article.html)</div></div>
        </body></html>
        """
    }
}

/// How the reader sets a page: its face, its size, how far apart its lines.
public struct ReaderStyle: Codable, Equatable {
    public enum Face: String, Codable, CaseIterable {
        case chronicle, ideal, system
        public var title: String {
            switch self {
            case .chronicle: "Chronicle"
            case .ideal: "Ideal Sans"
            case .system: "System"
            }
        }
    }

    public enum Spacing: String, Codable, CaseIterable {
        case tight, normal, loose
        public var title: String { rawValue.capitalized }
        public var leading: Double {
            switch self {
            case .tight: 1.35
            case .normal: 1.55
            case .loose: 1.8
            }
        }
    }

    public var face: Face = .chronicle
    public var size: Double = ReaderStyle.sizes.standard
    public var spacing: Spacing = .normal

    public init() {}

    /// The sizes it is set in: the phone's larger, held nearer.
    #if os(iOS)
    public static let sizes = (smallest: 14.0, standard: 17.0, largest: 30.0)
    #else
    public static let sizes = (smallest: 13.0, standard: 18.0, largest: 28.0)
    #endif

    /// Smaller, or larger: a point, as far as it goes.
    public mutating func step(_ by: Double) { size = max(Self.sizes.smallest, min(Self.sizes.largest, size + by)) }

    public var faceCSS: String {
        switch face {
        case .chronicle: "Chronicle, Georgia, serif"
        case .ideal: "Ideal, -apple-system, sans-serif"
        case .system: "-apple-system, system-ui, sans-serif"
        }
    }

    /// The page shown set in it at once, where it was read to.
    public var script: String { "prismStyle(\"\(faceCSS)\", \(Int(size)), \(spacing.leading))" }

    /// As CSS's own: the page's to start with.
    public var css: String { "--face: \(faceCSS); --size: \(Int(size))px; --leading: \(spacing.leading);" }

    public static var current: ReaderStyle {
        get { UserDefaults.standard.data(forKey: "Reader.style").flatMap { try? JSONDecoder().decode(ReaderStyle.self, from: $0) } ?? ReaderStyle() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "Reader.style") }
    }
}
