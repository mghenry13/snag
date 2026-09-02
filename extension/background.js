const API = "http://127.0.0.1:41777";

// ---------- Context menus ----------

async function fetchFolders() {
  try {
    const res = await fetch(`${API}/folders`);
    return await res.json();
  } catch (e) {
    return [];
  }
}

async function rebuildMenus() {
  await chrome.contextMenus.removeAll();
  chrome.contextMenus.create({ id: "save-image", title: "Save to Snag", contexts: ["image"] });
  chrome.contextMenus.create({ id: "save-video", title: "Save to Snag", contexts: ["video"] });
  chrome.contextMenus.create({ id: "save-link", title: "Save to Snag", contexts: ["link"] });
  chrome.contextMenus.create({ id: "save-page", title: "Save Page to Snag", contexts: ["page"] });

  const folders = await fetchFolders();
  for (const ctx of [["image", "save-image"], ["video", "save-video"]]) {
    const [context, parent] = ctx;
    if (folders.length) {
      chrome.contextMenus.create({ id: `${parent}-sep`, parentId: parent, type: "separator", contexts: [context] });
    }
    chrome.contextMenus.create({ id: `${parent}-none`, parentId: parent, title: "Uncategorized", contexts: [context] });
    for (const f of folders) {
      chrome.contextMenus.create({
        id: `${parent}-f-${f.id}`, parentId: parent,
        title: f.parentId ? `   ${f.name}` : f.name,
        contexts: [context],
      });
    }
  }
  chrome.contextMenus.create({ id: "refresh-folders", title: "↻ Refresh Folders", contexts: ["action"] });
}

chrome.runtime.onInstalled.addListener(rebuildMenus);
chrome.runtime.onStartup.addListener(rebuildMenus);

// The folder list comes from the Snag app, so a menu built while Snag was
// closed shows nothing but "Uncategorized" — and folders created later never
// appeared at all. Rebuild whenever this worker wakes, and on a timer so new
// folders show up on their own.
rebuildMenus();
chrome.alarms.create("snag-folders", { periodInMinutes: 2 });
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === "snag-folders") rebuildMenus();
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const pageURL = tab?.url || info.pageUrl;
  if (info.menuItemId === "refresh-folders") { rebuildMenus(); return; }
  setTimeout(rebuildMenus, 1500);

  let folderId = null;
  let src = null;

  const id = String(info.menuItemId);
  if (id.startsWith("save-image") || id.startsWith("save-video")) {
    src = info.srcUrl;
    const m = id.match(/-f-(.+)$/);
    if (m) folderId = m[1];
  } else if (id === "save-link") {
    src = info.linkUrl;
  } else if (id === "save-page") {
    src = pageURL;
  }
  if (!src) return;
  await saveURL(src, pageURL, folderId);
});

// ---------- Save helpers ----------

async function saveURL(url, pageURL, folderId) {
  try {
    const res = await fetch(`${API}/items`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url, pageURL, folderId }),
    });
    const json = await res.json();
    notify(json.duplicate ? "Already in Snag" : `Saved: ${json.name || "item"}`);
    return json;
  } catch (e) {
    notify("Snag app is not running");
    return null;
  }
}

async function saveCapture(dataUrl, name, pageURL, rect) {
  let base64 = dataUrl.split(",")[1];
  if (rect) {
    const cropped = await cropDataURL(dataUrl, rect);
    base64 = cropped.split(",")[1];
  }
  try {
    const res = await fetch(`${API}/items`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ dataBase64: base64, ext: "png", name, pageURL, sourceURL: pageURL }),
    });
    const json = await res.json();
    notify(json.duplicate ? "Already in Snag" : "Capture saved to Snag");
  } catch (e) {
    notify("Snag app is not running");
  }
}

async function cropDataURL(dataUrl, rect) {
  const blob = await (await fetch(dataUrl)).blob();
  const bitmap = await createImageBitmap(blob);
  const canvas = new OffscreenCanvas(rect.w, rect.h);
  const ctx = canvas.getContext("2d");
  ctx.drawImage(bitmap, rect.x, rect.y, rect.w, rect.h, 0, 0, rect.w, rect.h);
  const out = await canvas.convertToBlob({ type: "image/png" });
  return await new Promise((resolve) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.readAsDataURL(out);
  });
}

function notify(message) {
  chrome.notifications.create({
    type: "basic",
    iconUrl: "icons/icon128.png",
    title: "Snag",
    message,
  });
}

// ---------- Messages from popup / content scripts ----------

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  (async () => {
    if (msg.type === "save-bytes") {
      // Content scripts hand over already-downloaded bytes (Instagram CDN
      // URLs expire and are refused outside the page's session).
      try {
        const res = await fetch(`${API}/items`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            dataBase64: msg.dataBase64, ext: msg.ext || "mp4",
            name: msg.name, sourceURL: msg.sourceURL, pageURL: msg.pageURL,
            folderId: msg.folderId || null,
          }),
        });
        const json = await res.json();
        notify(json.duplicate ? "Already in Snag" : `Saved: ${json.name || "video"}`);
        sendResponse({ ok: true, duplicate: !!json.duplicate });
      } catch (e) {
        notify("Snag app is not running");
        sendResponse({ ok: false });
      }
    } else if (msg.type === "save-url") {
      const r = await saveURL(msg.url, msg.pageURL, msg.folderId || null);
      sendResponse({ ok: !!r, duplicate: !!(r && r.duplicate) });
    } else if (msg.type === "batch-save") {
      let saved = 0, dups = 0;
      for (const u of msg.urls) {
        const r = await saveURL_silent(u, msg.pageURL, msg.folderId || null);
        if (r) r.duplicate ? dups++ : saved++;
      }
      notify(`Batch: ${saved} saved${dups ? `, ${dups} already in Snag` : ""}`);
      sendResponse({ ok: true, saved, dups });
    } else if (msg.type === "capture-visible") {
      const dataUrl = await chrome.tabs.captureVisibleTab(null, { format: "png" });
      await saveCapture(dataUrl, msg.name || "Capture", msg.pageURL, null);
      sendResponse({ ok: true });
    } else if (msg.type === "capture-area") {
      // rect comes in CSS pixels; scale by devicePixelRatio
      const dataUrl = await chrome.tabs.captureVisibleTab(null, { format: "png" });
      const s = msg.scale || 1;
      const rect = { x: msg.rect.x * s, y: msg.rect.y * s, w: msg.rect.w * s, h: msg.rect.h * s };
      await saveCapture(dataUrl, msg.name || "Area Capture", msg.pageURL, rect);
      sendResponse({ ok: true });
    } else if (msg.type === "get-folders") {
      sendResponse(await fetchFolders());
    }
  })();
  return true; // async response
});

async function saveURL_silent(url, pageURL, folderId) {
  try {
    const res = await fetch(`${API}/items`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url, pageURL, folderId }),
    });
    return await res.json();
  } catch (e) {
    return null;
  }
}
