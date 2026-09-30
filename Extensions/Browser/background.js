// The menu item and the key that highlight a selection, and the count of a
// page's highlights on the toolbar button.
const api = globalThis.browser ?? globalThis.chrome;

api.runtime.onInstalled.addListener(() => {
  api.contextMenus.create({ id: "reflect-highlight", title: "Highlight in Reflect", contexts: ["selection"] });
});

async function highlight(tabId) {
  try {
    await api.tabs.sendMessage(tabId, { type: "highlight" });
  } catch {
    // A page the extension cannot reach: the browser's own, or the store.
  }
}

api.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === "reflect-highlight" && tab?.id) highlight(tab.id);
});

api.commands.onCommand.addListener(async (command) => {
  if (command !== "highlight") return;
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  if (tab?.id) highlight(tab.id);
});

api.runtime.onMessage.addListener((message, sender) => {
  if (message.type === "highlights" && sender.tab?.id) {
    api.action.setBadgeText({ tabId: sender.tab.id, text: message.count ? String(message.count) : "" });
    api.action.setBadgeBackgroundColor?.({ tabId: sender.tab.id, color: "#5b53f5" });
  }
});
