// Snag on Meta Ad Library: overlay a save button on every ad video.
// Facebook serves many ad videos through blob: URLs; the real mp4 lives in
// JSON embedded in the page (playable_url / playable_url_quality_hd).
(() => {
  if (window.__snagFbAds) return;
  window.__snagFbAds = true;

  const BTN_CLASS = "__snag-save-btn";

  // Videos harvested by fb-ads-intercept.js (page world) from GraphQL traffic.
  const harvested = []; // {video, poster}
  window.addEventListener("message", (e) => {
    if (e.source !== window || !e.data || !e.data.__snagVideos) return;
    for (const v of e.data.__snagVideos) harvested.push(v);
  });

  // ---- mp4 URL recovery ----------------------------------------------------

  function decodeJsonUrl(raw) {
    try { return JSON.parse('"' + raw + '"'); } catch (e) { return null; }
  }

  // All playable video URLs in page order, HD preferred per entry.
  function collectPlayableUrls() {
    const urls = [];
    const seen = new Set();
    const re = /"playable_url(?:_quality_hd)?":"((?:https:)?\\\/\\\/[^"]+)"/g;
    const hdMap = new Map(); // sd url index -> hd url

    for (const script of document.querySelectorAll("script")) {
      const text = script.textContent;
      if (!text || !text.includes("playable_url")) continue;
      // Walk entries in order; each ad object usually has sd then hd.
      let m;
      const localRe = /"playable_url":"([^"]+)"|"playable_url_quality_hd":"([^"]+)"/g;
      while ((m = localRe.exec(text)) !== null) {
        const sd = m[1] && decodeJsonUrl(m[1]);
        const hd = m[2] && decodeJsonUrl(m[2]);
        if (sd) {
          if (!seen.has(sd)) { seen.add(sd); urls.push({ sd, hd: null }); }
        } else if (hd && urls.length > 0 && !urls[urls.length - 1].hd) {
          urls[urls.length - 1].hd = hd;
        }
      }
    }
    return urls.map((u) => u.hd || u.sd);
  }

  function videoIndex(video) {
    return Array.from(document.querySelectorAll("video")).indexOf(video);
  }

  function normalize(u) {
    try { return new URL(u).origin + new URL(u).pathname; } catch (e) { return u; }
  }

  function resolveVideoURL(video) {
    const direct = video.currentSrc || video.src;
    if (direct && direct.startsWith("http")) return direct;

    // blob: — exact pairing via the poster image from GraphQL data
    const poster = video.poster || video.getAttribute("poster") || "";
    if (poster) {
      const key = normalize(poster);
      const hit = harvested.find((v) => v.poster && normalize(v.poster) === key);
      if (hit) return hit.video;
    }
    // fall back to DOM-order pairing against harvested + embedded lists
    const pool = harvested.map((v) => v.video).concat(collectPlayableUrls());
    const idx = videoIndex(video);
    if (idx >= 0 && idx < pool.length) return pool[idx];
    return pool.length >= 1 ? pool[pool.length - 1] : null;
  }

  // ---- save button ---------------------------------------------------------

  function makeButton(video) {
    const btn = document.createElement("div");
    btn.className = BTN_CLASS;
    btn.textContent = "Save to Snag";
    Object.assign(btn.style, {
      position: "absolute",
      top: "8px",
      right: "8px",
      zIndex: "999999",
      padding: "6px 10px",
      borderRadius: "7px",
      background: "rgba(23, 26, 37, 0.92)",
      color: "#fff",
      font: "600 12px -apple-system, BlinkMacSystemFont, sans-serif",
      cursor: "pointer",
      userSelect: "none",
      boxShadow: "0 2px 8px rgba(0,0,0,0.35)",
    });

    btn.addEventListener("click", async (e) => {
      e.preventDefault();
      e.stopPropagation();
      const url = resolveVideoURL(video);
      if (!url) {
        flash(btn, "No video URL found", "#B3403C");
        return;
      }
      flash(btn, "Saving…", null);
      chrome.runtime.sendMessage(
        { type: "save-url", url, pageURL: location.href },
        (resp) => {
          if (chrome.runtime.lastError || !resp) {
            flash(btn, "Snag not running", "#B3403C");
          } else {
            flash(btn, "Saved ✓", "#2E7D4F");
          }
        }
      );
    });
    return btn;
  }

  function flash(btn, text, color) {
    btn.textContent = text;
    if (color) btn.style.background = color;
    setTimeout(() => {
      btn.textContent = "Save to Snag";
      btn.style.background = "rgba(23, 26, 37, 0.92)";
    }, 1800);
  }

  function attach(video) {
    if (video.__snagButton) return;
    const host = video.parentElement;
    if (!host) return;
    if (getComputedStyle(host).position === "static") {
      host.style.position = "relative";
    }
    const btn = makeButton(video);
    host.appendChild(btn);
    video.__snagButton = btn;
  }

  function sweep() {
    for (const v of document.querySelectorAll("video")) attach(v);
  }

  sweep();
  new MutationObserver(() => sweep()).observe(document.body, {
    childList: true,
    subtree: true,
  });
})();
