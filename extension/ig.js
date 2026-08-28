// Snag on Instagram: one floating save button that targets whichever video
// is most visible. It lives on <body> at fixed position with the maximum
// z-index — Instagram's player overlay sits above anything placed inside
// the post, which is why an in-place button only toggled play/pause.
(() => {
  if (window.__snagIg) return;
  window.__snagIg = true;

  const harvested = []; // {shortcode, url}
  window.addEventListener("message", (e) => {
    if (e.source !== window || !e.data || !e.data.__snagIgVideos) return;
    for (const entry of e.data.__snagIgVideos) {
      if (!harvested.some((h) => h.url === entry.url)) harvested.push(entry);
    }
  });

  function currentShortcode() {
    const m = location.pathname.match(/\/(?:reels?|p|tv)\/([A-Za-z0-9_-]+)/);
    return m ? m[1] : "";
  }

  function timedVideoURLs() {
    try {
      return performance.getEntriesByType("resource")
        .map((e) => e.name)
        .filter((n) => /\.mp4/.test(n) && /cdninstagram|fbcdn/.test(n));
    } catch (e) { return []; }
  }

  // The video occupying the most screen space right now.
  function currentVideo() {
    let best = null, bestArea = 0;
    for (const v of document.querySelectorAll("video")) {
      const r = v.getBoundingClientRect();
      if (r.width < 80 || r.height < 80) continue;
      const vis = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0))
                * Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0));
      if (vis > bestArea) { bestArea = vis; best = v; }
    }
    return best;
  }

  function resolveURL(video) {
    const direct = video && (video.currentSrc || video.src) || "";
    if (direct.startsWith("http")) return direct;

    // Match THIS reel by its shortcode — the feed preloads neighbours, so
    // any positional guess saves someone else's video.
    const code = currentShortcode();
    if (code) {
      const hit = harvested.find((h) => h.shortcode === code);
      if (hit) return hit.url;
    }
    // Single video on screen and only one candidate: unambiguous.
    const videos = Array.from(document.querySelectorAll("video"));
    const untagged = harvested.filter((h) => !h.shortcode);
    if (videos.length === 1 && harvested.length === 1) return harvested[0].url;
    if (videos.length === 1 && untagged.length === 1) return untagged[0].url;
    return null;
  }

  function permalink() {
    const m = location.pathname.match(/\/(reels?|p|tv)\/([A-Za-z0-9_-]+)/);
    return m ? `https://www.instagram.com/${m[1] === "reels" ? "reel" : m[1]}/${m[2]}/`
             : location.href.split("?")[0];
  }

  function itemName() {
    const code = (permalink().match(/\/([A-Za-z0-9_-]+)\/?$/) || [])[1] || "reel";
    const user = (location.pathname.match(/^\/([A-Za-z0-9._]+)\//) || [])[1];
    const handle = document.querySelector('header a[href^="/"]')?.getAttribute("href")?.replace(/\//g, "");
    const who = handle || (user && !["reel", "reels", "p", "tv"].includes(user) ? user : null);
    return who ? `${who} — ${code}` : `Instagram ${code}`;
  }

  // ---- the button ----------------------------------------------------------

  const btn = document.createElement("button");
  btn.textContent = "Save to Snag";
  Object.assign(btn.style, {
    position: "fixed", zIndex: "2147483647",
    background: "rgba(0,0,0,.78)", color: "#fff", border: "1px solid rgba(255,255,255,.18)",
    borderRadius: "9px", padding: "7px 12px", fontSize: "12px", fontWeight: "600",
    cursor: "pointer", backdropFilter: "blur(10px)", display: "none",
    fontFamily: "-apple-system, system-ui, sans-serif", lineHeight: "1",
    boxShadow: "0 4px 14px rgba(0,0,0,.35)", pointerEvents: "auto",
  });
  document.documentElement.appendChild(btn);

  // Beat Instagram's overlay: consume the event in the capture phase.
  for (const type of ["pointerdown", "mousedown", "mouseup", "click", "touchstart"]) {
    btn.addEventListener(type, (e) => {
      e.preventDefault();
      e.stopPropagation();
      e.stopImmediatePropagation();
      if (type === "click") save();
    }, true);
  }

  function place() {
    const v = currentVideo();
    if (!v) { btn.style.display = "none"; return; }
    const r = v.getBoundingClientRect();
    if (r.bottom < 0 || r.top > innerHeight) { btn.style.display = "none"; return; }
    btn.style.display = "block";
    btn.style.top = Math.max(8, r.top + 12) + "px";
    btn.style.left = Math.min(innerWidth - 130, r.right - 128) + "px";
  }

  let busy = false;
  async function save() {
    if (busy) return;
    const video = currentVideo();
    const url = resolveURL(video);
    if (!url) { flash("Scroll/replay, then retry", true); return; }
    busy = true;
    flash("Saving…");
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
        type: "save-bytes", dataBase64: btoa(bin), ext: "mp4",
        name: itemName(), sourceURL: url, pageURL: permalink(),
      });
      flash(reply && reply.duplicate ? "Already saved" : "Saved ✓");
    } catch (err) {
      try {
        const reply = await chrome.runtime.sendMessage({
          type: "save-url", url, pageURL: permalink(),
        });
        flash(reply && reply.ok ? "Saved ✓" : "Failed", !(reply && reply.ok));
      } catch (e2) {
        flash("Failed", true);
      }
    }
    busy = false;
  }

  function flash(text, bad) {
    btn.textContent = text;
    btn.style.background = bad ? "rgba(190,55,55,.92)"
                          : text === "Saving…" ? "rgba(63,110,247,.92)"
                          : "rgba(45,150,90,.92)";
    if (text !== "Saving…") {
      setTimeout(() => {
        btn.textContent = "Save to Snag";
        btn.style.background = "rgba(0,0,0,.78)";
      }, 1900);
    }
  }

  addEventListener("scroll", place, true);
  addEventListener("resize", place);
  setInterval(place, 400);
  place();
})();
