// The popup: what will be captured — its title, its address, the passages
// highlighted, the selection, a screenshot — and the button that sends it
// to Reflect Mac, which writes it into the notes.
const api = globalThis.browser ?? globalThis.chrome;
const server = "http://127.0.0.1:47811";
const $ = (id) => document.getElementById(id);

let tab = null;
let page = null;
let token = null;

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
  if (!response.ok) throw Object.assign(new Error(answer.error ?? `Reflect answered ${response.status}`), { status: response.status });
  return answer;
}

/** An address as a link shows it: its site, and the end of its path. */
function shorten(url) {
  try {
    const parsed = new URL(url);
    const parts = parsed.pathname.split("/").filter(Boolean);
    const host = parsed.hostname.replace(/^www\./, "");
    if (parts.length >= 3) return `${host}/${parts[0]}/…/${parts[parts.length - 1]}`;
    return host + (parts.length ? "/" + parts.join("/") : "");
  } catch {
    return url;
  }
}

function render() {
  $("title").value = page.title;
  $("url").textContent = shorten(page.url);
  $("url").title = page.url;
  const list = $("highlights");
  list.replaceChildren();
  for (const text of page.highlights) {
    const item = document.createElement("li");
    const words = document.createElement("span");
    words.textContent = text;
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
  $("count").textContent = page.highlights.length ? `· ${page.highlights.length}` : "";
  $("no-highlights").hidden = page.highlights.length > 0 || !!page.selection;
  const extra = page.selection && !page.highlights.includes(page.selection);
  $("selection").hidden = !extra;
  if (extra) $("selection").textContent = `The selected text will be included too.`;
}

async function load() {
  [tab] = await api.tabs.query({ active: true, currentWindow: true });
  token = (await api.storage.local.get("token")).token ?? null;
  const stored = await api.storage.local.get("screenshot");
  $("screenshot").checked = stored.screenshot ?? true;

  let ping;
  try {
    ping = await call("/ping", null, "GET");
  } catch {
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
    let screenshot = null;
    if ($("screenshot").checked) {
      screenshot = await api.tabs.captureVisibleTab(tab.windowId, { format: "png" }).catch(() => null);
    }
    const saved = await call("/capture", {
      url: page.url,
      title: $("title").value.trim() || page.title,
      description: page.description,
      highlights,
      screenshot,
    });
    button.textContent = "Saved";
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
    button.textContent = "Save to Reflect";
    $("status").textContent = error.message.includes("fetch") ? "Reflect Mac isn’t open." : error.message;
    $("status").className = "status error";
    $("status").hidden = false;
  }
}

async function pair() {
  const button = $("pair-button");
  button.disabled = true;
  $("pair-status").hidden = false;
  $("pair-status").className = "status";
  $("pair-status").textContent = "Answer Reflect Mac’s question…";
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
    $("pair-status").textContent = error.status === 403 ? "Not allowed." : "Reflect Mac isn’t open.";
  }
}

$("save").addEventListener("click", save);
$("pair-button").addEventListener("click", pair);
$("retry").addEventListener("click", load);
$("screenshot").addEventListener("change", (event) => api.storage.local.set({ screenshot: event.target.checked }));
document.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !$("capture").hidden && !$("save").disabled && document.activeElement?.id !== "title") save();
  if (event.key === "Enter" && document.activeElement?.id === "title") $("save").focus();
});

load();
