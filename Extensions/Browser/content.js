// Highlights on the page, and what the page says of itself, for Reflect.
//
// A selection gets a small "Highlight" button; highlighted, a passage is
// drawn with the CSS Custom Highlight API — the page's own DOM is not
// touched — and kept, by the page's address, so it is there again when the
// page is, and in the capture.
(() => {
  if (window.__reflectCapture) return;
  window.__reflectCapture = true;

  const api = globalThis.browser ?? globalThis.chrome;
  const pageKey = () => "highlights:" + location.href.split("#")[0];
  const supportsHighlights = typeof Highlight !== "undefined" && CSS.highlights;

  /** The passages highlighted: their text, and their range when found. */
  let highlights = [];

  function redraw() {
    if (!supportsHighlights) return;
    const ranges = highlights.map((h) => h.range).filter(Boolean);
    CSS.highlights.set("reflect-capture", new Highlight(...ranges));
  }

  async function save() {
    await api.storage.local.set({ [pageKey()]: highlights.map((h) => h.text) });
    api.runtime.sendMessage({ type: "highlights", count: highlights.length }).catch(() => {});
  }

  // A passage's range, found again in the page's text: across elements,
  // its white space as loose as the page's layout makes it.
  function find(text) {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: (node) =>
        node.parentElement && !["SCRIPT", "STYLE", "NOSCRIPT"].includes(node.parentElement.tagName)
          ? NodeFilter.FILTER_ACCEPT
          : NodeFilter.FILTER_REJECT,
    });
    const nodes = [];
    let flat = "";
    // Each character of the flattened text, and where it came from.
    const origins = [];
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      nodes.push(node);
      const value = node.nodeValue;
      for (let i = 0; i < value.length; i++) {
        const ch = /\s/.test(value[i]) ? " " : value[i];
        if (ch === " " && flat.endsWith(" ")) continue;
        flat += ch;
        origins.push([node, i]);
      }
    }
    const wanted = text.replace(/\s+/g, " ").trim();
    const at = flat.indexOf(wanted);
    if (at < 0 || !wanted) return null;
    const [startNode, startOffset] = origins[at];
    const [endNode, endOffset] = origins[at + wanted.length - 1];
    const range = document.createRange();
    range.setStart(startNode, startOffset);
    range.setEnd(endNode, endOffset + 1);
    return range;
  }

  async function restore() {
    const stored = (await api.storage.local.get(pageKey()))[pageKey()] ?? [];
    highlights = stored.map((text) => ({ text, range: find(text) }));
    redraw();
    api.runtime.sendMessage({ type: "highlights", count: highlights.length }).catch(() => {});
  }

  function highlightSelection() {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed) return false;
    const text = selection.toString().trim();
    if (!text) return false;
    if (!highlights.some((h) => h.text === text)) {
      highlights.push({ text, range: selection.getRangeAt(0).cloneRange() });
      redraw();
      save();
    }
    selection.removeAllRanges();
    hideButton();
    return true;
  }

  // MARK: The button beside a selection

  let button = null;

  function hideButton() {
    button?.remove();
    button = null;
  }

  function showButton() {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || selection.toString().trim().length < 2) return hideButton();
    const rect = selection.getRangeAt(0).getBoundingClientRect();
    if (!rect.width && !rect.height) return hideButton();
    if (!button) {
      button = document.createElement("div");
      button.id = "reflect-capture-highlight-button";
      button.textContent = "Highlight";
      // Pressed before the selection is lost to the click.
      button.addEventListener("mousedown", (event) => {
        event.preventDefault();
        event.stopPropagation();
        highlightSelection();
      });
      document.documentElement.appendChild(button);
    }
    button.style.left = `${window.scrollX + rect.right - 40}px`;
    button.style.top = `${window.scrollY + rect.bottom + 8}px`;
  }

  document.addEventListener("mouseup", (event) => {
    if (button && event.target === button) return;
    setTimeout(showButton, 0);
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") hideButton();
  });
  document.addEventListener("selectionchange", () => {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed) hideButton();
  });

  // MARK: What the popup and the menu ask

  function describe() {
    const meta = (name) =>
      document.querySelector(`meta[property="${name}"], meta[name="${name}"]`)?.getAttribute("content")?.trim() ?? "";
    return {
      url: location.href,
      title: meta("og:title") || document.title || location.hostname,
      description: meta("og:description") || meta("description") || meta("twitter:description"),
      highlights: highlights.map((h) => h.text),
      selection: window.getSelection()?.toString().trim() ?? "",
    };
  }

  api.runtime.onMessage.addListener((message, _sender, reply) => {
    switch (message.type) {
      case "describe":
        reply(describe());
        break;
      case "highlight":
        reply({ highlighted: highlightSelection() });
        break;
      case "remove":
        highlights = highlights.filter((h) => h.text !== message.text);
        redraw();
        save().then(() => reply({ ok: true }));
        return true;
      case "clear":
        highlights = [];
        redraw();
        save().then(() => reply({ ok: true }));
        return true;
    }
    return false;
  });

  restore();
})();
