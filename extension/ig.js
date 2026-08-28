// Snag on Instagram: a save button on every reel / video post.
// The mp4 is fetched HERE (extension context keeps the CDN's signed URL
// valid) and handed to Snag as bytes, so nothing depends on the app being
// able to re-request an expiring Instagram URL.
(() => {
  if (window.__snagIg) return;
  window.__snagIg = true;

  const BTN = "__snag-ig-btn";
  const harvested = [];
  window.addEventListener("message", (e) => {
    if (e.source !== window || !e.data || !e.data.__snagIgVideos) return;
    for (const u of e.data.__snagIgVideos) if (!harvested.includes(u)) harvested.push(u);
  });

  // Resource timing also reveals the mp4s the player actually loaded.
  function timedVideoURLs() {
    try {
      return performance.getEntriesByType("resource")
        .map((e) => e.name)
        .filter((n) => /\.mp4/.test(n) && /cdninstagram|fbcdn/.test(n));
    } catch (e) { return []; }
  }

  function resolveURL(video) {
    const direct = video.currentSrc || video.src || "";
    if (direct.startsWith("http")) return direct;
    const all = [...harvested, ...timedVideoURLs()];
    if (!all.length) return null;
    // Match this video to a harvested URL by its position on the page.
    const idx = Array.from(document.querySelectorAll("video")).indexOf(video);
    return all[Math.min(idx, all.length - 1)] || all[all.length - 1];
  }

  function permalink() {
    const m = location.pathname.match(/\/(reels?|p|tv)\/([A-Za-z0-9_-]+)/);
    return m ? `https://www.instagram.com/${m[1] === "reels" ? "reel" : m[1]}/${m[2]}/`
             : location.href.split("?")[0];
  }

  function itemName() {
    const user = document.querySelector('a[href^="/"][role="link"] span')?.textContent?.trim();
    const shortcode = (permalink().match(/\/([A-Za-z0-9_-]+)\/?$/) || [])[1] || "reel";
    return user ? `${user} — ${shortcode}` : `Instagram ${shortcode}`;
  }

  async function save(video, btn) {
    const url = resolveURL(video);
    if (!url) { flash(btn, "No video found", true); return; }
    flash(btn, "Saving…");
    try {
      const res = await fetch(url, { credentials: "include" });
      if (!res.ok) throw new Error("HTTP " + res.status);
      const buf = await res.arrayBuffer();
      if (buf.byteLength > 80 * 1024 * 1024) throw new Error("too large");
      let bin = "";
      const bytes = new Uint8Array(buf);
      for (let i = 0; i < bytes.length; i += 0x8000) {
        bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
      }
      const reply = await chrome.runtime.sendMessage({
        type: "save-bytes",
        dataBase64: btoa(bin),
        ext: "mp4",
        name: itemName(),
        sourceURL: url,
        pageURL: permalink(),
      });
      flash(btn, reply && reply.duplicate ? "Already saved" : "Saved ✓");
    } catch (err) {
      // Fall back to letting the app download it.
      try {
        const reply = await chrome.runtime.sendMessage({
          type: "save-url", url, pageURL: permalink(),
        });
        flash(btn, reply && reply.ok ? "Saved ✓" : "Failed", !(reply && reply.ok));
      } catch (e2) {
        flash(btn, "Failed", true);
      }
    }
  }

  function flash(btn, text, bad) {
    btn.textContent = text;
    btn.style.background = bad ? "rgba(200,60,60,.92)" : "rgba(63,110,247,.92)";
    if (text !== "Saving…") {
      setTimeout(() => {
        btn.textContent = "Save to Snag";
        btn.style.background = "rgba(0,0,0,.72)";
      }, 1800);
    }
  }

  function addButton(video) {
    const host = video.closest("article, div[role='button'], div") || video.parentElement;
    if (!host || host.querySelector("." + BTN)) return;
    if (getComputedStyle(host).position === "static") host.style.position = "relative";

    const btn = document.createElement("button");
    btn.className = BTN;
    btn.textContent = "Save to Snag";
    Object.assign(btn.style, {
      position: "absolute", top: "12px", right: "12px", zIndex: "9999",
      background: "rgba(0,0,0,.72)", color: "#fff", border: "0",
      borderRadius: "8px", padding: "6px 10px", fontSize: "12px",
      fontWeight: "600", cursor: "pointer", backdropFilter: "blur(8px)",
      fontFamily: "-apple-system, system-ui, sans-serif",
    });
    btn.addEventListener("click", (e) => {
      e.preventDefault(); e.stopPropagation();
      save(video, btn);
    }, true);
    host.appendChild(btn);
  }

  function scan() {
    for (const v of document.querySelectorAll("video")) addButton(v);
  }

  scan();
  new MutationObserver(() => scan()).observe(document.documentElement, {
    childList: true, subtree: true,
  });
  setInterval(scan, 1500); // reels mount lazily as you scroll
})();
