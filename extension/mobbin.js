// Snag on Mobbin: a "Snag" button in the header of an open screen (next to
// the collaborator avatars, Comments and Copy link). It saves the screen at
// the biggest size Mobbin lists: the 1920px image, or the recording for
// screens with motion. Mobbin files everything as "file.webp"/"file.mp4", so
// the item is named after the app ("Cursor iOS Screen") and the flow it was
// found in, and its note links the screen and the flow.
//
// Mobbin's class names are Tailwind utilities, so the header is found by its
// "Copy link" button and the screen by being the biggest picture in the
// dialog.
(() => {
  if (window.__snagMobbin) return;
  window.__snagMobbin = true;

  const isLogo = (img) => /logo/i.test(img.alt || "") || /app_logos|\/static\/|dictionary/.test(img.src || "");

  const area = (el) => {
    const r = el.getBoundingClientRect();
    return r.width * r.height;
  };

  // The biggest copy an <img> lists in its srcset.
  function bestSrc(img) {
    let url = img.currentSrc || img.src, size = 0;
    for (const part of (img.srcset || "").split(",")) {
      const [u, d] = part.trim().split(/\s+/);
      const n = parseFloat(d) || 0;
      if (u && n > size) { size = n; url = new URL(u, location.href).href; }
    }
    return url;
  }

  // The screen on show: the largest image or video in the dialog. The
  // "See similar" screens further down are smaller.
  function screenOf(dialog) {
    let best = null, bestArea = 0;
    for (const v of dialog.querySelectorAll("video")) {
      const src = v.currentSrc || v.src || (v.querySelector("source") || {}).src;
      if (!src || !/^https?:/.test(src)) continue;
      const a = area(v);
      if (a > bestArea) { bestArea = a; best = { url: src, ext: "mp4" }; }
    }
    for (const img of dialog.querySelectorAll("img")) {
      if (isLogo(img) || !(img.currentSrc || img.src)) continue;
      const a = area(img);
      if (a > bestArea) { bestArea = a; best = { url: bestSrc(img), ext: "webp" }; }
    }
    return best;
  }

  function appOf(header) {
    const a = header.querySelector("a");
    return a ? (a.innerText || "").trim() : "";
  }

  // "Found in [Subscribing…]" in the dialog's footer: the flow this screen
  // is part of. Mobbin cuts long names short in the page itself ("Chatting
  // wi...") and keeps the rest in a hover tooltip, so a cut name is left out
  // and only the link kept.
  function flowOf(dialog) {
    const a = dialog.querySelector('a[href^="/flows/"]');
    if (!a) return { name: "", url: "" };
    const text = (a.innerText || "").trim().replace(/\s+/g, " ");
    return { name: /(\.\.\.|…)$/.test(text) ? "" : text, url: a.href };
  }

  // "Cursor iOS Screen | Mobbin" on a screen's own page.
  function titleOf(app) {
    const t = document.title.replace(/\s*\|\s*Mobbin\s*$/i, "").trim();
    return /screen/i.test(t) ? t : `${app || "Mobbin"} screen`;
  }

  function pageOf() {
    return /^\/screens\//.test(location.pathname) ? location.origin + location.pathname : location.href;
  }

  async function save(dialog, header, btn) {
    const media = screenOf(dialog);
    if (!media) { flash(btn, "Nothing to save", true); return; }
    const app = appOf(header);
    const flow = flowOf(dialog);
    const page = pageOf();
    const name = [titleOf(app), flow.name].filter(Boolean).join(" — ");
    const note = [`Mobbin: ${page}`, flow.url ? `Flow${flow.name ? ` (${flow.name})` : ""}: ${flow.url}` : ""]
      .filter(Boolean).join("\n");
    flash(btn, "Saving…");
    try {
      const reply = await chrome.runtime.sendMessage({
        type: "save-remote", pageURL: page, note,
        items: [{ url: media.url, ext: media.ext, name }],
      });
      if (!reply || !reply.ok) { flash(btn, "Failed", true); return; }
      flash(btn, reply.duplicate ? "Already saved" : "Saved ✓");
    } catch (e) {
      flash(btn, "Failed", true);
    }
  }

  function flash(btn, text, bad) {
    btn.textContent = text;
    btn.style.color = bad ? "#d92d20" : text === "Saving…" ? "inherit" : "#079455";
    if (text !== "Saving…") setTimeout(() => { btn.textContent = "Snag"; btn.style.color = "inherit"; }, 1900);
  }

  function addButton(copyLink) {
    const dialog = copyLink.closest('[role="dialog"]');
    const header = copyLink.closest("header");
    // The header's right-hand row: avatars | Comments, Copy link | close.
    // The button goes in front of the Comments/Copy link group, right after
    // the avatars.
    const row = copyLink.closest("header > div");
    if (!dialog || !header || !row || header.querySelector(".snag-mobbin-btn")) return;
    let before = copyLink;
    while (before.parentElement && before.parentElement !== row) before = before.parentElement;
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "snag-mobbin-btn";
    btn.textContent = "Snag";
    btn.title = "Save this screen to Snag";
    Object.assign(btn.style, {
      height: "36px", padding: "0 12px", borderRadius: "999px", border: "none",
      background: "transparent", cursor: "pointer", flex: "0 0 auto",
      font: "600 14px -apple-system, system-ui, sans-serif", color: "inherit",
      transition: "background-color .15s",
    });
    btn.addEventListener("mouseenter", () => { btn.style.backgroundColor = "rgba(128,128,128,.14)"; });
    btn.addEventListener("mouseleave", () => { btn.style.backgroundColor = "transparent"; });
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      save(dialog, header, btn);
    }, true);
    row.insertBefore(btn, before);
  }

  function scan() {
    for (const b of document.querySelectorAll('[role="dialog"] header button[aria-label="Copy link"]')) addButton(b);
  }

  new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
  setInterval(scan, 1500);
  scan();
})();
