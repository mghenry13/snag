const API = "http://127.0.0.1:41777";
const folderSel = document.getElementById("folder");
const folderValue = document.getElementById("folder-value");

function setStatus(text, state) {
  document.getElementById("status-text").textContent = text;
  document.getElementById("status").className = "status " + (state || "");
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

function showFolder() {
  const opt = folderSel.options[folderSel.selectedIndex];
  folderValue.textContent = opt ? opt.textContent.trim() : "Uncategorized";
}

folderSel.addEventListener("change", () => {
  showFolder();
  chrome.storage.local.set({ pageFolderId: folderSel.value });
});

// Folders, and whether the app is up.
(async () => {
  try {
    // Ask the app directly: the folder list is empty both when Snag is closed
    // and when it has no folders, and only this tells them apart.
    const health = await fetch(`${API}/health`);
    if (!health.ok) throw new Error();
    const folders = (await chrome.runtime.sendMessage({ type: "get-folders" })) || [];
    for (const { f, depth } of folderTree(folders)) {
      const opt = document.createElement("option");
      opt.value = f.id;
      opt.textContent = " ".repeat(depth) + f.name;
      folderSel.appendChild(opt);
    }
    // Reopen on the folder used last; the page buttons on Instagram, X,
    // LinkedIn, Facebook and the Ad Library save there too.
    const { pageFolderId = "" } = await chrome.storage.local.get("pageFolderId");
    if ([...folderSel.options].some((o) => o.value === pageFolderId)) folderSel.value = pageFolderId;
    showFolder();
    setStatus("Connected to Snag", "ok");
  } catch (e) {
    setStatus("Snag isn't running", "off");
  }
})();

// The keys the browser actually assigned (a clash with another extension
// leaves one unassigned), drawn as ⌥ ⇧ 1 chips.
(async () => {
  const glyph = { Alt: "⌥", Option: "⌥", Shift: "⇧", Ctrl: "⌃", Control: "⌃", Command: "⌘", MacCtrl: "⌃", Cmd: "⌘" };
  const commands = await chrome.commands.getAll();
  for (const c of commands) {
    const slot = document.querySelector(`.kbd[data-command="${c.name}"]`);
    if (!slot || !c.shortcut) continue;
    // Chrome reports "⌥⇧1" on a Mac and "Alt+Shift+1" elsewhere.
    const keys = c.shortcut.includes("+") ? c.shortcut.split("+").map((k) => glyph[k] || k) : [...c.shortcut];
    for (const k of keys) {
      const span = document.createElement("span");
      span.textContent = k;
      slot.appendChild(span);
    }
  }
})();

async function run(action) {
  const reply = await chrome.runtime.sendMessage({ type: "run", action, folderId: folderSel.value || null });
  if (reply && reply.ok === false) { setStatus("Snag can't work on this page", "off"); return; }
  window.close();
}

const actions = {
  "save-url": () => run("save-page"),
  "batch-save": () => run("batch-save"),
  "capture-area": () => run("capture-area"),
  "capture-visible": () => run("capture-visible"),
  "open-app": async () => {
    try {
      const r = await fetch(`${API}/show`, { method: "POST" });
      if (!r.ok) throw new Error();
      window.close();
    } catch (e) {
      setStatus("Snag isn't running. Open it from Applications.", "off");
    }
  },
};

for (const [id, fn] of Object.entries(actions)) {
  const row = document.getElementById(id);
  row.addEventListener("click", fn);
  row.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); fn(); } });
}

document.getElementById("shortcuts").addEventListener("click", () => {
  chrome.tabs.create({ url: "chrome://extensions/shortcuts" });
  window.close();
});
