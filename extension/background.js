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
chrome.alarms.create("snag-avatars", { delayInMinutes: 1, periodInMinutes: 15 });
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === "snag-folders") rebuildMenus();
  if (a.name === "snag-avatars") fillInstagramPictures();
});

// ---------- Profile pictures ----------

// Phone shares reach Snag as a link; yt-dlp names the author but not their
// picture, and Instagram shows profile pictures only to signed-in visitors.
// While the browser is open, look up the ones Snag is missing with the
// user's own login: a profile page's og:image is its picture (a "-19/" path
// on Instagram's CDN). The same lookup also runs from an open Instagram tab
// (ig.js), for browsers that keep the login away from extensions.
let fillingPictures = false;
async function fillInstagramPictures() {
  if (fillingPictures) return;
  fillingPictures = true;
  try {
    const res = await fetch(`${API}/profiles/missing?platform=instagram`);
    if (!res.ok) return;
    const missing = (await res.json()).slice(0, 25);
    for (const p of missing) {
      try {
        const page = await fetch(`https://www.instagram.com/${encodeURIComponent(p.handle)}/`, { credentials: "include" });
        const html = await page.text();
        const m = html.match(/<meta[^>]+property="og:image"[^>]+content="([^"]+)"/)
          || html.match(/<meta[^>]+content="([^"]+)"[^>]+property="og:image"/);
        const pic = m && m[1].replace(/&amp;/g, "&");
        if (pic && /-19\//.test(pic)) {
          await fetch(`${API}/profiles/avatar`, {
            method: "POST", headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ id: p.id, avatar: pic }),
          });
        }
      } catch (e) { /* next one */ }
      await new Promise((r) => setTimeout(r, 2000)); // one profile at a time, gently
    }
  } catch (e) {
    // Snag isn't running; try again next time.
  } finally {
    fillingPictures = false;
  }
}
chrome.runtime.onStartup.addListener(() => setTimeout(fillInstagramPictures, 20000));

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const pageURL = tab?.url || info.pageUrl;
  if (info.menuItemId === "refresh-folders") { rebuildMenus(); return; }

  const m = String(info.menuItemId)
    .match(/^(save-image|save-video|save-link|save-page)(?:-(?:f|r)-(.+)|-none)?$/);
  if (!m) return;
  const kind = m[1];
  const folderId = m[2] || null;
  let src = kind === "save-link" ? info.linkUrl
          : kind === "save-page" ? pageURL
          : info.srcUrl;
  // YouTube, Instagram and most video sites stream from blob: addresses
  // that mean nothing outside the tab. Hand Snag the page instead; it
  // downloads the video itself.
  if (kind === "save-video" && !/^https?:/.test(src || "")) src = pageURL;
  if (!src) return;
  // An image: take the biggest copy the page lists, and on Mobbin the
  // screen's app name and link.
  let name = null, savePageURL = pageURL;
  if (kind === "save-image" && /^https?:/.test(src) && tab && tab.id != null) {
    const hit = await bestImage(tab.id, info.frameId, src);
    if (hit) {
      src = hit.src || src;
      name = hit.name || null;
      savePageURL = hit.page || pageURL;
    }
  }
  // Saving the page itself: keep a picture of it as it looks right now.
  const screenshot = kind === "save-page" ? await captureTab(tab && tab.windowId, tab && tab.id) : null;
  const saved = await saveURL(src, savePageURL, folderId, screenshot);
  if (saved && name) await addMeta(saved, null, null, name);
  if (saved && screenshot) playPop();
});

// Chrome hands over the copy the page chose to show (currentSrc), which on
// Mobbin is a 360px thumbnail; the 1920px screen is in the same img's srcset.
// Mobbin also files every screen as "file.webp", so its alt ("Cursor screen")
// and link (/screens/<id>) name it.
async function bestImage(tabId, frameId, srcUrl) {
  try {
    const [res] = await chrome.scripting.executeScript({
      target: frameId ? { tabId, frameIds: [frameId] } : { tabId },
      args: [srcUrl],
      func: (srcUrl) => {
        const img = [...document.images].find(i => i.currentSrc === srcUrl || i.src === srcUrl);
        if (!img) return null;
        let src = srcUrl, size = 0;
        for (const part of (img.srcset || "").split(",")) {
          const [u, d] = part.trim().split(/\s+/);
          const n = parseFloat(d) || 0;
          if (u && n > size) { size = n; src = new URL(u, location.href).href; }
        }
        const out = { src };
        if (/(^|\.)mobbin\.com$/.test(location.hostname)) {
          if (img.alt) out.name = img.alt;
          const a = img.closest('a[href*="/screens/"]');
          if (a) out.page = a.href;
        }
        return out;
      },
    });
    return res && res.result;
  } catch (e) {
    return null; // chrome:// pages and the like; save what Chrome gave us
  }
}

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

// The visible part of the tab, as JPEG base64, for a saved page's picture.
// Chrome refuses on its own pages and the Web Store; the save goes ahead
// without one.
async function captureTab(windowId, tabId) {
  try {
    const dataUrl = await chrome.tabs.captureVisibleTab(windowId ?? null, { format: "jpeg", quality: 88 });
    flashTab(tabId);
    return dataUrl.split(",")[1] || null;
  } catch (e) { return null; }
}

// ---------- Screenshot feedback ----------

// A camera flash over the page, drawn AFTER the capture so it is never in
// the picture.
async function flashTab(tabId) {
  if (tabId == null) {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    tabId = tab && tab.id;
  }
  if (tabId == null) return;
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      func: () => {
        const el = document.createElement("div");
        el.style.cssText = "position:fixed;inset:0;z-index:2147483647;pointer-events:none;"
          + "background:#fff;opacity:.85;transition:opacity 380ms ease-out;";
        document.documentElement.appendChild(el);
        requestAnimationFrame(() => requestAnimationFrame(() => { el.style.opacity = "0"; }));
        setTimeout(() => el.remove(), 450);
      },
    });
  } catch (e) { /* chrome:// pages and the Web Store refuse scripts */ }
}

// The "done" pop, once Snag has the screenshot. Played from an offscreen
// document (offscreen.html): the worker itself cannot play audio.
async function playPop() {
  try {
    if (!(await chrome.offscreen.hasDocument())) {
      await chrome.offscreen.createDocument({
        url: "offscreen.html",
        reasons: ["AUDIO_PLAYBACK"],
        justification: "Play a short sound when a screenshot is saved to Snag",
      });
    }
    await chrome.runtime.sendMessage({ target: "offscreen", type: "play-pop" });
  } catch (e) { /* a sound is a nicety; the save already happened */ }
}

async function saveURL(url, pageURL, folderId, screenshotBase64) {
  const body = { url, pageURL, folderId };
  if (screenshotBase64) body.screenshotBase64 = screenshotBase64;
  const r = await postItem(body);
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

// ---------- Popup actions and keyboard shortcuts ----------

// One implementation for each popup row, so its keyboard shortcut does
// exactly the same thing.
async function runAction(action, tab, folderId) {
  if (!tab || !tab.id) return;
  if (!folderCache.length) await fetchFolders();
  if (action === "save-page") {
    const shot = await captureTab(tab.windowId, tab.id);
    const saved = await saveURL(tab.url, tab.url, folderId, shot);
    if (saved && shot) playPop();
  } else if (action === "batch-save") {
    let urls;
    try {
      [{ result: urls }] = await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        func: () => {
          const seen = new Set(), out = [];
          for (const img of document.querySelectorAll("img")) {
            const src = img.currentSrc || img.src;
            if (!src || seen.has(src)) continue;
            if (img.naturalWidth >= 200 && img.naturalHeight >= 200) { seen.add(src); out.push(src); }
          }
          return out;
        },
      });
    } catch (e) { notify("Snag can't work on this page"); return; }
    await batchSave(urls || [], tab.url, folderId);
  } else if (action === "capture-visible") {
    try {
      const dataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, { format: "png" });
      flashTab(tab.id);
      if (await saveCapture(dataUrl, tab.title || "Capture", tab.url, null, folderId)) playPop();
    } catch (e) { notify("Snag can't capture this page"); }
  } else if (action === "capture-area") {
    try {
      await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["capture-area.js"] });
    } catch (e) { notify("Snag can't work on this page"); }
  }
}

async function batchSave(urls, pageURL, folderId) {
  let saved = 0, dups = 0, failed = 0;
  for (const u of urls) {
    const r = await saveURL_silent(u, pageURL, folderId);
    if (!r) failed++;
    else if (r.duplicate) dups++;
    else saved++;
  }
  if (saved) await afterSave(folderId);
  notify(`Batch: ${saved} saved` +
         (dups ? `, ${dups} already in Snag` : "") +
         (failed ? `, ${failed} failed` : ""));
  return { ok: failed === 0, saved, dups, failed };
}

chrome.commands.onCommand.addListener(async (command, tab) => {
  if (!tab) [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  await runAction(command, tab, await pageFolderId());
});

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
      await addMeta(r.json, msg.note, msg.account);
      notify(savedNotice(r.json, folderId));
      await afterSave(folderId);
      sendResponse({ ok: true, duplicate: !!r.json.duplicate, folderName: folderId && folderName(folderId) });
    } else if (msg.type === "save-remote") {
      // Files a content script found but cannot fetch itself (the page's CORS
      // rules apply to it; this worker's host permissions do not). Download
      // here and hand Snag the bytes, so each item keeps its proper name
      // instead of the CDN's random file id.
      let saved = 0, dups = 0, failed = 0;
      // Several files from one post are a carousel: Snag keeps them as one
      // group, shown as a stack, in slide order.
      const items = msg.items || [];
      const groupId = items.length > 1 && msg.group !== false ? crypto.randomUUID() : null;
      for (const [index, item] of items.entries()) {
        try {
          const res = await fetch(item.url, { credentials: "omit" });
          if (!res.ok) throw new Error("HTTP " + res.status);
          const r = await postItem({
            dataBase64: toBase64(await res.arrayBuffer()), ext: extFromType(res.headers.get("content-type")) || item.ext,
            name: item.name, sourceURL: item.url, pageURL: msg.pageURL, folderId,
            ...(groupId ? { groupId, groupIndex: index } : {}),
          });
          if (!r.ok) throw new Error(r.reason);
          if (r.json.duplicate) dups++; else saved++;
          await addMeta(r.json, msg.note, msg.account);
        } catch (e) {
          failed++;
        }
      }
      if (saved) await afterSave(folderId);
      const where = folderId && folderName(folderId);
      notify(failed && !saved && !dups ? "Snag could not save it"
             : saved ? `Saved ${saved > 1 ? saved + " items" : "1 item"}${where ? " to " + where : ""}`
               + (failed ? `, ${failed} failed` : "")
             : "Already in Snag");
      sendResponse({ ok: failed === 0 || saved > 0, duplicate: !saved && dups > 0,
                     saved, dups, failed, folderName: where });
    } else if (msg.type === "save-url") {
      // The popup's Save URL asks for a picture of the page it is saving.
      const shot = msg.screenshot ? await captureTab(sender.tab ? sender.tab.windowId : null, sender.tab && sender.tab.id) : null;
      const r = await saveURL(msg.url, msg.pageURL, folderId, shot);
      if (r && shot) playPop();
      if (r) await addMeta(r, msg.note, msg.account, msg.name);
      sendResponse({ ok: !!r, duplicate: !!(r && r.duplicate), folderName: folderId && folderName(folderId) });
    } else if (msg.type === "run") {
      // A popup row: the same action its keyboard shortcut runs.
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      await runAction(msg.action, tab, folderId);
      sendResponse({ ok: true });
    } else if (msg.type === "batch-save") {
      sendResponse(await batchSave(msg.urls, msg.pageURL, folderId));
    } else if (msg.type === "capture-visible" || msg.type === "capture-area") {
      // captureVisibleTab throws on chrome:// pages, the Web Store, and past
      // Chrome's two-per-second limit. Uncaught, it left the popup waiting
      // forever with no message.
      try {
        const dataUrl = await chrome.tabs.captureVisibleTab(null, { format: "png" });
        flashTab(sender.tab && sender.tab.id);
        let rect = null;
        if (msg.type === "capture-area") {
          // rect comes in CSS pixels; scale by devicePixelRatio
          const s = msg.scale || 1;
          rect = { x: msg.rect.x * s, y: msg.rect.y * s, w: msg.rect.w * s, h: msg.rect.h * s };
        }
        const name = msg.name || (rect ? "Area Capture" : "Capture");
        const ok = await saveCapture(dataUrl, name, msg.pageURL, rect, folderId);
        if (ok) playPop();
        sendResponse({ ok });
      } catch (e) {
        notify("Snag can't capture this page");
        sendResponse({ ok: false, error: String(e && e.message || e) });
      }
    } else if (msg.type === "missing-avatars") {
      // Profiles Snag has no picture for, so a page script on that platform,
      // where the user is signed in, can look them up.
      try {
        const res = await fetch(`${API}/profiles/missing?platform=${encodeURIComponent(msg.platform)}`);
        sendResponse(res.ok ? await res.json() : []);
      } catch (e) { sendResponse([]); }
    } else if (msg.type === "set-avatar") {
      try {
        await fetch(`${API}/profiles/avatar`, {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ id: msg.id, avatar: msg.avatar }),
        });
      } catch (e) {}
      sendResponse({ ok: true });
    } else if (msg.type === "get-folders") {
      sendResponse(await fetchFolders());
    }
  })().catch((e) => {
    // Never leave a sender waiting on a reply that will not come.
    try { sendResponse({ ok: false, error: String(e && e.message || e) }); } catch (_) {}
  });
  return true; // async response
});

// The post's words and link travel with the media as its note, and its author
// as its account. The note only goes on a fresh item, so re-saving never
// replaces a note written since; the account goes on every save, so items
// saved before accounts existed pick theirs up.
async function addMeta(json, note, account, name) {
  if (!json || !json.id) return;
  const body = {};
  if (note && !json.duplicate) body.note = note;
  // A file saved by its address is named after it (a CDN's random id).
  if (name && !json.duplicate) body.name = name;
  if (account && account.platform && (account.handle || account.name)) body.account = account;
  if (!Object.keys(body).length) return;
  try {
    await fetch(`${API}/items/${json.id}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch (e) { /* the media is saved; the rest is a bonus */ }
}

// What the server says it sent beats the address: Facebook serves JPEGs from
// paths ending in .png.
function extFromType(type) {
  const t = (type || "").split(";")[0].trim().toLowerCase();
  return {
    "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif",
    "image/heic": "heic", "image/avif": "avif", "video/mp4": "mp4", "video/quicktime": "mov",
    "video/webm": "webm",
  }[t] || null;
}

function toBase64(buf) {
  const bytes = new Uint8Array(buf);
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(bin);
}

async function saveURL_silent(url, pageURL, folderId) {
  const r = await postItem({ url, pageURL, folderId });
  return r.ok ? r.json : null;
}
