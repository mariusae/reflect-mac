import AppKit
import WebKit

/// A link note's page, open beside it: the passages its note keeps marked
/// on it, as a highlighter would; and, chosen there, a passage highlighted —
/// kept in the note, under its Highlights.
final class WebPageView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    private let web: WKWebView
    /// The passages the note keeps, to mark.
    var highlights: [String] = [] { didSet { if highlights != oldValue { mark() } } }
    /// A passage chosen and highlighted on the page.
    var onHighlight: ((String) -> Void)?
    /// The page's headings — h1 to h3 — each where it is down the page, and
    /// the page's height: an outline to scrub by, when it has one.
    struct Outline: Equatable {
        struct Heading: Equatable {
            var title: String
            var level: Int
            var y: CGFloat
        }
        var headings: [Heading]
        var height: CGFloat
    }
    var onOutline: ((Outline) -> Void)?
    /// Scrolled: where the page's top is, and how much of it shows.
    var onScroll: ((_ top: CGFloat, _ visible: CGFloat) -> Void)?

    /// Scrolls the page so a point of it is at the top.
    func scroll(toY y: CGFloat, animated: Bool) {
        web.evaluateJavaScript("window.scrollTo({top: \(max(0, y - 12)), behavior: '\(animated ? "smooth" : "instant")'})")
    }
    private(set) var url: URL?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController = controller
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        // Weakly: a script handler holds what it calls.
        controller.add(WeakHandler(self), name: "prism")
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
        addSubview(web)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func load(_ url: URL) {
        guard url != self.url else { return }
        self.url = url
        web.load(URLRequest(url: url))
    }

    override func layout() {
        super.layout()
        web.frame = bounds
    }

    /// The passages marked on the page, and a passage chosen and highlighted
    /// as the button would: for a script's check.
    func checkForScript(choosing passage: String?, done: @escaping (String) -> Void) {
        let choose = passage.map { p in
            "(function(){const w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let n;while((n=w.nextNode())){const i=n.nodeValue.indexOf(\(String(reflecting: p)));if(i>=0){const r=document.createRange();r.setStart(n,i);r.setEnd(n,i+\(p.count));window.getSelection().removeAllRanges();window.getSelection().addRange(r);document.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));return true}}return false})();"
        } ?? ""
        web.evaluateJavaScript(choose) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let click = passage == nil ? "" : "document.getElementById('prism-hl-button') && document.getElementById('prism-hl-button').click();"
                self.web.evaluateJavaScript(click + "Array.from(document.querySelectorAll('mark.prism-hl')).map(m=>m.textContent).join(' | ')") { result, error in
                    done((result as? String) ?? "error: \(String(describing: error))")
                }
            }
        }
    }

    /// The passages marked, those not marked yet: now, and again a little
    /// later, for pages that fill in after they load.
    private func mark() {
        guard let data = try? JSONSerialization.data(withJSONObject: highlights),
              let list = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.prismMark && window.prismMark(\(list))")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        mark()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.mark() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.mark() }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let headings = body["outline"] as? [[String: Any]] {
            let found = headings.compactMap { heading -> Outline.Heading? in
                guard let title = heading["title"] as? String, let level = heading["level"] as? Int,
                      let y = (heading["y"] as? NSNumber)?.doubleValue else { return nil }
                return Outline.Heading(title: title, level: level, y: CGFloat(y))
            }
            onOutline?(Outline(headings: found, height: CGFloat((body["height"] as? NSNumber)?.doubleValue ?? 1)))
            return
        }
        if let top = (body["scroll"] as? NSNumber)?.doubleValue {
            onScroll?(CGFloat(top), CGFloat((body["visible"] as? NSNumber)?.doubleValue ?? 0))
            return
        }
        guard let text = body["highlight"] as? String else { return }
        let passage = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !passage.isEmpty else { return }
        highlights.append(passage)
        onHighlight?(passage)
    }

    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ target: WKScriptMessageHandler) { self.target = target }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(controller, didReceive: message)
        }
    }

    /// In the page: marking passages — found in its text, whitespace and
    /// case aside — and, on text chosen, a button that highlights it.
    private static let script = #"""
    (function () {
      if (window.prismMark) return;
      const style = document.createElement('style');
      style.textContent = `
        mark.prism-hl { background: rgba(255, 214, 10, 0.45); color: inherit; border-radius: 2px; padding: 0; }
        #prism-hl-button { position: absolute; z-index: 2147483647; font: 600 12px -apple-system, system-ui, sans-serif;
          background: #1f1f1f; color: #fff; border: 0; border-radius: 999px; padding: 6px 12px; cursor: pointer;
          box-shadow: 0 4px 14px rgba(0,0,0,0.25); }`;
      document.documentElement.appendChild(style);

      const skipped = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEXTAREA']);
      function textNodes(root) {
        return document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
          acceptNode(n) { return n.parentNode && skipped.has(n.parentNode.nodeName) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT; }
        });
      }
      function wrap(range) {
        const root = range.commonAncestorContainer.nodeType === 3 ? range.commonAncestorContainer.parentNode : range.commonAncestorContainer;
        const walker = textNodes(root), nodes = [];
        let n;
        while ((n = walker.nextNode())) if (range.intersectsNode(n)) nodes.push(n);
        for (const node of nodes) {
          const s = node === range.startContainer ? range.startOffset : 0;
          const e = node === range.endContainer ? range.endOffset : node.nodeValue.length;
          if (e <= s) continue;
          let piece = s > 0 ? node.splitText(s) : node;
          if (e - s < piece.nodeValue.length) piece.splitText(e - s);
          if (!piece.nodeValue.trim()) continue;
          const mark = document.createElement('mark');
          mark.className = 'prism-hl';
          piece.parentNode.insertBefore(mark, piece);
          mark.appendChild(piece);
        }
      }
      const marked = new Set();
      function norm(s) { return s.replace(/\s+/g, ' ').trim().toLowerCase(); }
      function markOne(passage) {
        const target = norm(passage);
        if (!target || marked.has(target) || !document.body) return;
        const walker = textNodes(document.body);
        let text = '', map = [], space = true, n;
        while ((n = walker.nextNode())) {
          const v = n.nodeValue;
          for (let i = 0; i < v.length; i++) {
            if (/\s/.test(v[i])) { if (!space) { text += ' '; map.push([n, i]); space = true; } }
            else { text += v[i].toLowerCase(); map.push([n, i]); space = false; }
          }
        }
        const at = text.indexOf(target);
        if (at < 0) return;
        const start = map[at], end = map[at + target.length - 1];
        const range = document.createRange();
        range.setStart(start[0], start[1]);
        range.setEnd(end[0], end[1] + 1);
        wrap(range);
        marked.add(target);
      }
      window.prismMark = function (passages) { for (const p of passages) { try { markOne(p); } catch (e) {} } };

      // Its outline: the headings people read it by, where each is; told
      // again as the page fills in or changes size, and where it is scrolled.
      let lastOutline = '';
      function outline() {
        const found = [];
        for (const h of document.querySelectorAll('h1, h2, h3')) {
          const title = (h.innerText || '').replace(/\s+/g, ' ').trim();
          const box = h.getBoundingClientRect();
          if (!title || title.length > 160 || box.height === 0) continue;
          found.push({ title, level: Number(h.tagName[1]), y: box.top + window.scrollY });
        }
        const height = document.documentElement.scrollHeight;
        const said = JSON.stringify([found, height]);
        if (said === lastOutline) return;
        lastOutline = said;
        window.webkit.messageHandlers.prism.postMessage({ outline: found, height });
      }
      function scrolled() {
        window.webkit.messageHandlers.prism.postMessage({ scroll: window.scrollY, visible: window.innerHeight });
      }
      outline();
      scrolled();
      setTimeout(outline, 1500);
      setTimeout(outline, 4000);
      window.addEventListener('load', outline);
      window.addEventListener('resize', () => { outline(); scrolled(); });
      window.addEventListener('scroll', scrolled, { passive: true });

      let button = null;
      function hide() { if (button) { button.remove(); button = null; } }
      document.addEventListener('mouseup', function (event) {
        if (button && event.target === button) return;
        setTimeout(function () {
          const selection = window.getSelection();
          const text = selection ? selection.toString() : '';
          hide();
          if (!text.trim() || selection.rangeCount === 0) return;
          const range = selection.getRangeAt(0);
          const rect = range.getBoundingClientRect();
          button = document.createElement('button');
          button.id = 'prism-hl-button';
          button.textContent = 'Highlight';
          button.style.left = (rect.left + window.scrollX + rect.width / 2 - 40) + 'px';
          button.style.top = (rect.bottom + window.scrollY + 8) + 'px';
          button.addEventListener('mousedown', function (e) { e.preventDefault(); e.stopPropagation(); });
          button.addEventListener('click', function (e) {
            e.preventDefault();
            const chosen = range.toString();
            try { wrap(range); } catch (err) {}
            marked.add(norm(chosen));
            window.getSelection().removeAllRanges();
            hide();
            window.webkit.messageHandlers.prism.postMessage({ highlight: chosen });
          });
          document.body.appendChild(button);
        }, 10);
      });
      document.addEventListener('mousedown', function (event) { if (event.target !== button) hide(); });
    })();
    """#
}
