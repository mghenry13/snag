const API = "http://127.0.0.1:41777";
const status = document.getElementById("status");
const folderSel = document.getElementById("folder");

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
}

function setStatus(text, off = false) {
  status.textContent = text;
  status.className = off ? "off" : "";
}

// Parents first, children right under them.
function folderTree(folders) {
  const ids = new Set(folders.map((f) => f.id));
  const byParent = new Map();
  for (const f of folders) {
    const pid = f.parentId && ids.has(f.parentId) ? f.parentId : null;
    if (!byParent.has(pid)) byParent.set(pid, []);
    byParent.get(pid).push(f);
  }
  const out = [];
  const walk = (pid, depth) => {
    for (const f of byParent.get(pid) || []) { out.push({ f, depth }); walk(f.id, depth + 1); }
  };
  walk(null, 0);
  return out;
}

folderSel.addEventListener("change", () => {
  chrome.storage.local.set({ pageFolderId: folderSel.value });
});

// Populate folders + check the app is up
(async () => {
  try {
    // Ask the app directly. The folder list comes back empty when Snag is
    // closed, and the old check could never tell that apart from "no folders".
    const health = await fetch(`${API}/health`);
    if (!health.ok) throw new Error();
    const folders = (await chrome.runtime.sendMessage({ type: "get-folders" })) || [];
    for (const { f, depth } of folderTree(folders)) {
      const opt = document.createElement("option");
      opt.value = f.id;
      opt.textContent = "\u2003".repeat(depth) + f.name;
      folderSel.appendChild(opt);
    }
    // Reopen on the folder you used last; it is also where the page buttons
    // (Instagram, Ad Library) and Capture Area save.
    const { pageFolderId = "" } = await chrome.storage.local.get("pageFolderId");
    if ([...folderSel.options].some((o) => o.value === pageFolderId)) folderSel.value = pageFolderId;
    setStatus("Connected to Snag");
  } catch (e) {
    setStatus("Snag app is not running", true);
  }
})();

document.getElementById("save-url").addEventListener("click", async () => {
  const tab = await activeTab();
  await chrome.runtime.sendMessage({ type: "save-url", url: tab.url, pageURL: tab.url, folderId: folderSel.value || null });
  window.close();
});

// Chrome refuses to run scripts on chrome:// pages and the Web Store. Say so
// in the popup instead of leaving it sitting there doing nothing.
function cannotRunHere() {
  setStatus("Snag can't work on this page", true);
}

document.getElementById("batch-save").addEventListener("click", async () => {
  const tab = await activeTab();
  let urls;
  try {
  [{ result: urls }] = await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    func: () => {
      const seen = new Set();
      const out = [];
      for (const img of document.querySelectorAll("img")) {
        const src = img.currentSrc || img.src;
        if (!src || seen.has(src)) continue;
        if (img.naturalWidth >= 200 && img.naturalHeight >= 200) {
          seen.add(src);
          out.push(src);
        }
      }
      return out;
    },
  });
  } catch (e) { cannotRunHere(); return; }
  setStatus(`Saving ${urls.length} images…`);
  await chrome.runtime.sendMessage({ type: "batch-save", urls, pageURL: tab.url, folderId: folderSel.value || null });
  window.close();
});

document.getElementById("capture-visible").addEventListener("click", async () => {
  const tab = await activeTab();
  const r = await chrome.runtime.sendMessage({ type: "capture-visible", name: tab.title || "Capture", pageURL: tab.url, folderId: folderSel.value || null });
  if (r && r.ok === false) { cannotRunHere(); return; }
  window.close();
});

document.getElementById("capture-area").addEventListener("click", async () => {
  const tab = await activeTab();
  try {
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["capture-area.js"] });
  } catch (e) { cannotRunHere(); return; }
  window.close();
});

// This button used to ping the app and close, which opened nothing.
document.getElementById("open-app").addEventListener("click", async () => {
  try {
    const r = await fetch(`${API}/show`, { method: "POST" });
    if (!r.ok) throw new Error();
    window.close();
  } catch (e) {
    setStatus("Snag isn't running. Open it from Applications.", true);
  }
});
