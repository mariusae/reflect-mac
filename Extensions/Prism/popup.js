// The popup: the page as Prism will show it — a card, its site and when,
// a screenshot, its title, what it says of itself, the passages highlighted
// — and the button that sends it to Prism, which writes it into the notes.
const api = globalThis.browser ?? globalThis.chrome;
const server = "http://127.0.0.1:47821";
const $ = (id) => document.getElementById(id);

let tab = null;
let page = null;
let token = null;
/** The screenshot, taken as the popup opens: shown, and sent. */
let shot = null;

function show(id) {
  for (const section of ["capture", "pair", "offline"]) $(section).hidden = section !== id;
}

async function call(path, body, method = "POST") {
  const response = await fetch(server + path, {
    method,
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const answer = await response.json().catch(() => ({}));
  if (!response.ok) throw Object.assign(new Error(answer.error ?? `Prism answered ${response.status}`), { status: response.status });
  return answer;
}

/** A page's site, as a card is headed by it. */
function site(url) {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return url;
  }
}

/** The title's field as tall as its words. */
function fit() {
  const title = $("title");
  title.style.height = "auto";
  title.style.height = title.scrollHeight + "px";
}

function render() {
  $("site").textContent = site(page.url);
  $("site").title = page.url;
  $("title").value = page.title;
  fit();
  $("description").textContent = page.description;
  $("description").hidden = !page.description;
  $("thumb").hidden = !(shot && $("screenshot").checked);
  if (shot) $("thumb").src = shot;
  const list = $("highlights");
  list.replaceChildren();
  for (const text of page.highlights) {
    const item = document.createElement("li");
    const words = document.createElement("span");
    const mark = document.createElement("mark");
    mark.textContent = text;
    words.append(mark);
    const remove = document.createElement("button");
    remove.textContent = "×";
    remove.title = "Remove this highlight";
    remove.addEventListener("click", async () => {
      await api.tabs.sendMessage(tab.id, { type: "remove", text }).catch(() => {});
      page.highlights = page.highlights.filter((h) => h !== text);
      render();
    });
    item.append(words, remove);
    list.append(item);
  }
  $("no-highlights").hidden = page.highlights.length > 0 || !!page.selection;
  const extra = page.selection && !page.highlights.includes(page.selection);
  $("selection").hidden = !extra;
  if (extra) $("selection").textContent = "The selected text will be included too.";
}

async function takeScreenshot() {
  if (shot || !$("screenshot").checked) return;
  shot = await api.tabs.captureVisibleTab(tab.windowId, { format: "png" }).catch(() => null);
}

async function load() {
  [tab] = await api.tabs.query({ active: true, currentWindow: true });
  token = (await api.storage.local.get("token")).token ?? null;
  const stored = await api.storage.local.get("screenshot");
  $("screenshot").checked = stored.screenshot ?? true;

  let ping;
  try {
    ping = await call("/ping", null, "GET");
  } catch (error) {
    // Not there at all, or there and saying no: which, it says.
    $("offline-title").textContent = error.status ? "Prism didn’t answer" : "Prism isn’t open";
    $("offline-message").textContent = error.status
      ? `Prism said: ${error.message}`
      : "Open Prism, then try again: pages are saved through it, into your notes.";
    show("offline");
    return;
  }
  if (!token || !ping.paired) {
    show("pair");
    return;
  }
  try {
    page = await api.tabs.sendMessage(tab.id, { type: "describe" });
  } catch {
    // A page the extension cannot read into: its address and title only.
    page = null;
  }
  page ??= { url: tab.url, title: tab.title ?? "", description: "", highlights: [], selection: "" };
  await takeScreenshot();
  show("capture");
  render();
  $("save").focus();
}

async function save() {
  const button = $("save");
  button.disabled = true;
  button.textContent = "Saving…";
  $("status").hidden = true;
  try {
    const highlights = [...page.highlights];
    if (page.selection && !highlights.includes(page.selection)) highlights.push(page.selection);
    const saved = await call("/capture", {
      url: page.url,
      title: $("title").value.trim() || page.title,
      description: page.description,
      highlights,
      screenshot: $("screenshot").checked ? shot : null,
    });
    button.textContent = "Saved";
    $("when").textContent = "Saved";
    $("status").textContent = `In your notes as “${saved.title}”, and linked from today.`;
    $("status").className = "status";
    $("status").hidden = false;
    $("open").hidden = false;
    $("open").onclick = async () => {
      await call("/open", { path: saved.path }).catch(() => {});
      window.close();
    };
  } catch (error) {
    if (error.status === 401) {
      await api.storage.local.remove("token");
      token = null;
      show("pair");
      return;
    }
    button.disabled = false;
    button.textContent = "Save to Prism";
    $("status").textContent = error.message.includes("fetch") ? "Prism isn’t open." : error.message;
    $("status").className = "status error";
    $("status").hidden = false;
  }
}

async function pair() {
  const button = $("pair-button");
  button.disabled = true;
  $("pair-status").hidden = false;
  $("pair-status").className = "status";
  $("pair-status").textContent = "Answer Prism’s question…";
  const browser = navigator.userAgent.includes("Edg/") ? "Edge"
    : navigator.userAgent.includes("Chrome/") ? "Chrome"
    : navigator.userAgent.includes("Safari/") ? "Safari" : "This browser";
  try {
    const answer = await call("/pair", { browser });
    token = answer.token;
    await api.storage.local.set({ token });
    await load();
  } catch (error) {
    button.disabled = false;
    $("pair-status").className = "status error";
    $("pair-status").textContent = error.status === 403 ? "Not allowed." : "Prism isn’t open.";
  }
}

$("save").addEventListener("click", save);
$("pair-button").addEventListener("click", pair);
$("retry").addEventListener("click", load);
$("title").addEventListener("input", fit);
$("screenshot").addEventListener("change", async (event) => {
  api.storage.local.set({ screenshot: event.target.checked });
  await takeScreenshot();
  render();
});
document.addEventListener("keydown", (event) => {
  if (event.key !== "Enter" || $("capture").hidden) return;
  if (document.activeElement?.id === "title") {
    // A title is one line: Return moves on to saving.
    event.preventDefault();
    $("save").focus();
  } else if (!$("save").disabled) {
    save();
  }
});

load();
