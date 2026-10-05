// The key that highlights a selection, and the count of a page's
// highlights on the toolbar button.
const api = globalThis.browser ?? globalThis.chrome;

async function highlight(tabId) {
  try {
    await api.tabs.sendMessage(tabId, { type: "highlight" });
  } catch {
    // A page the extension cannot reach: the browser's own, or the store.
  }
}

api.commands.onCommand.addListener(async (command) => {
  if (command !== "highlight") return;
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  if (tab?.id) highlight(tab.id);
});

api.runtime.onMessage.addListener((message, sender) => {
  if (message.type === "highlights" && sender.tab?.id) {
    api.action.setBadgeText({ tabId: sender.tab.id, text: message.count ? String(message.count) : "" });
    api.action.setBadgeBackgroundColor?.({ tabId: sender.tab.id, color: "#2b2724" });
  }
});
