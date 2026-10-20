const API = "http://127.0.0.1:41777";

// ---------- Folders ----------

let folderCache = [];

async function fetchFolders() {
  try {
    const res = await fetch(`${API}/folders`);
    folderCache = await res.json();
  } catch (e) {
    folderCache = [];
  }
  return folderCache;
}

function folderName(id) {
  const f = folderCache.find((x) => x.id === id);
  return f ? f.name : null;
}

// Parents first with their children right under them, so nesting reads in a
// menu. A folder whose parent is gone shows at the top level.
function folderTree(folders) {
  const ids = new Set(folders.map((f) => f.id));
  const byParent = new Map();
  for (const f of folders) {
    const p = f.parentId && ids.has(f.parentId) ? f.parentId : null;
    if (!byParent.has(p)) byParent.set(p, []);
    byParent.get(p).push(f);
  }
  const out = [];
  const walk = (parent, depth) => {
    for (const f of byParent.get(parent) || []) {
      out.push({ f, depth });
      walk(f.id, depth + 1);
    }
  };
  walk(null, 0);
  return out;
}

// Menus trim ordinary spaces, so nesting is indented with em spaces.
const INDENT = " ";

// The folders you saved into most recently, newest first, shown at the top
// of every Save to Snag menu.
// Never let a storage failure take the menus down with it: without the
// "storage" permission this threw, and no Save to Snag menu was built at all.
async function recentFolders() {
  try {
    const { recentFolders = [] } = await chrome.storage.local.get("recentFolders");
    return recentFolders;
  } catch (e) { return []; }
}
async function rememberFolder(id) {
  if (!id) return;
  const recent = (await recentFolders()).filter((x) => x !== id);
  recent.unshift(id);
  try { await chrome.storage.local.set({ recentFolders: recent.slice(0, 3) }); } catch (e) {}
}

// The folder picked in the popup. The page buttons (Instagram, Ad Library)
// and Capture Area save there too.
async function pageFolderId() {
  try {
    const { pageFolderId = null } = await chrome.storage.local.get("pageFolderId");
    return pageFolderId || null;
  } catch (e) { return null; }
}

// ---------- Context menus ----------

const MENUS = [
  { id: "save-image", title: "Save to Snag", context: "image" },
  { id: "save-video", title: "Save to Snag", context: "video" },
  { id: "save-link", title: "Save to Snag", context: "link" },
  { id: "save-page", title: "Save Page to Snag", context: "page" },
];

async function buildMenus() {
  await chrome.contextMenus.removeAll();
  const folders = await fetchFolders();
  const ids = new Set(folders.map((f) => f.id));
  const recent = (await recentFolders()).filter((id) => ids.has(id));
  const tree = folderTree(folders);

  for (const m of MENUS) {
    chrome.contextMenus.create({ id: m.id, title: m.title, contexts: [m.context] });
    const add = (id, title, type) =>
      chrome.contextMenus.create({ id, parentId: m.id, title, type, contexts: [m.context] });
    if (recent.length) {
      for (const id of recent) add(`${m.id}-r-${id}`, folderName(id));
      add(`${m.id}-sep-r`, undefined, "separator");
    }
    add(`${m.id}-none`, "Uncategorized");
    if (tree.length) add(`${m.id}-sep`, undefined, "separator");
    for (const { f, depth } of tree) add(`${m.id}-f-${f.id}`, INDENT.repeat(depth) + f.name);
  }
  chrome.contextMenus.create({ id: "refresh-folders", title: "↻ Refresh Folders", contexts: ["action"] });
}

// Rebuilds can overlap (wake, timer, after a save). Overlapping removeAll and
// create calls fail on duplicate ids, so run them one after another.
let menuQueue = Promise.resolve();
function rebuildMenus() {
  menuQueue = menuQueue.then(buildMenus).catch(() => {});
  return menuQueue;
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

  const m = String(info.menuItemId)
    .match(/^(save-image|save-video|save-link|save-page)(?:-(?:f|r)-(.+)|-none)?$/);
  if (!m) return;
  const kind = m[1];
  const folderId = m[2] || null;
  const src = kind === "save-link" ? info.linkUrl
            : kind === "save-page" ? pageURL
            : info.srcUrl;
  if (!src) return;
  await saveURL(src, pageURL, folderId);
});

// ---------- Save helpers ----------

// The one way to hand Snag an item. A failed save used to read as "Saved":
// any JSON reply counted as success, including {"error": ...} with a 500
// from an expired CDN link.
async function postItem(body) {
  let res;
  try {
    res = await fetch(`${API}/items`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch (e) {
    return { ok: false, reason: "offline" };
  }
  let json = {};
  try { json = await res.json(); } catch (e) { /* empty body */ }
  if (!res.ok) return { ok: false, reason: json.error || `HTTP ${res.status}` };
  return { ok: true, json };
}

function failNotice(r) {
  return r.reason === "offline" ? "Snag app is not running" : `Snag could not save it: ${r.reason}`;
}

// A save into a folder moves it to the top of the menus' recent list.
async function afterSave(folderId) {
  if (!folderId) return;
  await rememberFolder(folderId);
  rebuildMenus();
}

function savedNotice(json, folderId) {
  if (json.duplicate) return "Already in Snag";
  const where = folderId && folderName(folderId);
  return where ? `Saved to ${where}` : `Saved: ${json.name || "item"}`;
}

async function saveURL(url, pageURL, folderId) {
  const r = await postItem({ url, pageURL, folderId });
  if (!r.ok) { notify(failNotice(r)); return null; }
  notify(savedNotice(r.json, folderId));
  await afterSave(folderId);
  return r.json;
}

async function saveCapture(dataUrl, name, pageURL, rect, folderId) {
  let base64 = dataUrl.split(",")[1];
  if (rect) {
    const cropped = await cropDataURL(dataUrl, rect);
    base64 = cropped.split(",")[1];
  }
  const r = await postItem({ dataBase64: base64, ext: "png", name, pageURL, sourceURL: pageURL, folderId });
  if (!r.ok) { notify(failNotice(r)); return false; }
  const where = folderId && folderName(folderId);
  notify(r.json.duplicate ? "Already in Snag" : (where ? `Capture saved to ${where}` : "Capture saved to Snag"));
  await afterSave(folderId);
  return true;
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
    if (!folderCache.length) await fetchFolders();
    // The popup always says where to save. The page buttons and Capture Area
    // don't, so they use the folder last picked in the popup.
    const folderId = "folderId" in msg ? (msg.folderId || null) : await pageFolderId();
    if (msg.type === "save-bytes") {
      // Content scripts hand over already-downloaded bytes (Instagram CDN
      // URLs expire and are refused outside the page's session).
      const r = await postItem({
        dataBase64: msg.dataBase64, ext: msg.ext || "mp4",
        name: msg.name, sourceURL: msg.sourceURL, pageURL: msg.pageURL,
        folderId,
      });
      if (!r.ok) { notify(failNotice(r)); sendResponse({ ok: false }); return; }
      notify(savedNotice(r.json, folderId));
      await afterSave(folderId);
      sendResponse({ ok: true, duplicate: !!r.json.duplicate, folderName: folderId && folderName(folderId) });
    } else if (msg.type === "save-url") {
      const r = await saveURL(msg.url, msg.pageURL, folderId);
      sendResponse({ ok: !!r, duplicate: !!(r && r.duplicate), folderName: folderId && folderName(folderId) });
    } else if (msg.type === "batch-save") {
      let saved = 0, dups = 0, failed = 0;
      for (const u of msg.urls) {
        const r = await saveURL_silent(u, msg.pageURL, folderId);
        if (!r) failed++;
        else if (r.duplicate) dups++;
        else saved++;
      }
      if (saved) await afterSave(folderId);
      notify(`Batch: ${saved} saved` +
             (dups ? `, ${dups} already in Snag` : "") +
             (failed ? `, ${failed} failed` : ""));
      sendResponse({ ok: failed === 0, saved, dups, failed });
    } else if (msg.type === "capture-visible" || msg.type === "capture-area") {
      // captureVisibleTab throws on chrome:// pages, the Web Store, and past
      // Chrome's two-per-second limit. Uncaught, it left the popup waiting
      // forever with no message.
      try {
        const dataUrl = await chrome.tabs.captureVisibleTab(null, { format: "png" });
        let rect = null;
        if (msg.type === "capture-area") {
          // rect comes in CSS pixels; scale by devicePixelRatio
          const s = msg.scale || 1;
          rect = { x: msg.rect.x * s, y: msg.rect.y * s, w: msg.rect.w * s, h: msg.rect.h * s };
        }
        const name = msg.name || (rect ? "Area Capture" : "Capture");
        sendResponse({ ok: await saveCapture(dataUrl, name, msg.pageURL, rect, folderId) });
      } catch (e) {
        notify("Snag can't capture this page");
        sendResponse({ ok: false, error: String(e && e.message || e) });
      }
    } else if (msg.type === "get-folders") {
      sendResponse(await fetchFolders());
    }
  })().catch((e) => {
    // Never leave a sender waiting on a reply that will not come.
    try { sendResponse({ ok: false, error: String(e && e.message || e) }); } catch (_) {}
  });
  return true; // async response
});

async function saveURL_silent(url, pageURL, folderId) {
  const r = await postItem({ url, pageURL, folderId });
  return r.ok ? r.json : null;
}
