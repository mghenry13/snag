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

  // ---- ad context ----------------------------------------------------------

  // The ad card an element sits in: the nearest ancestor carrying "Library ID".
  // Facebook's DOM is deep, so the walk allows plenty of levels.
  function cardOf(el) {
    let n = el;
    for (let i = 0; i < 30 && n; i++, n = n.parentElement) {
      if (n.textContent && n.textContent.includes("Library ID")) return n;
    }
    return null;
  }

  function libraryId(card) {
    const m = card && card.textContent.match(/Library ID:\s*(\d+)/);
    return m ? m[1] : null;
  }

  // The advertiser is the line right above "Sponsored" on the card.
  function advertiser(card) {
    if (!card) return null;
    const lines = card.innerText.split("\n").map((t) => t.trim()).filter(Boolean);
    const i = lines.indexOf("Sponsored");
    return i > 0 ? lines[i - 1] : null;
  }

  // Link each save to the exact ad, not to the whole search results page.
  function adURL(el) {
    const id = libraryId(cardOf(el));
    return id ? `https://www.facebook.com/ads/library/?id=${id}` : location.href;
  }

  function adName(el, fallback) {
    const card = cardOf(el);
    const id = libraryId(card);
    const who = advertiser(card);
    return [who, id ? `ad ${id}` : null].filter(Boolean).join(" · ") || fallback;
  }

  // ---- button --------------------------------------------------------------

  function makeButton(onClick) {
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
    // Keep the page from opening the ad or a lightbox under the button.
    for (const type of ["pointerdown", "mousedown", "mouseup"]) {
      btn.addEventListener(type, (e) => { e.preventDefault(); e.stopPropagation(); }, true);
    }
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      onClick(btn);
    }, true);
    return btn;
  }

  function flash(btn, text, color) {
    btn.textContent = text;
    if (color) btn.style.background = color;
    if (text === "Saving…") return;
    setTimeout(() => {
      btn.textContent = "Save to Snag";
      btn.style.background = "rgba(23, 26, 37, 0.92)";
    }, 1800);
  }

  // ---- video ads -----------------------------------------------------------

  function saveVideo(video, btn) {
    const url = resolveVideoURL(video);
    if (!url) {
      flash(btn, "No video URL found", "#B3403C");
      return;
    }
    flash(btn, "Saving…", null);
    chrome.runtime.sendMessage(
      { type: "save-url", url, pageURL: adURL(video) },
      (resp) => {
        if (chrome.runtime.lastError || !resp) {
          flash(btn, "Snag not running", "#B3403C");
        } else {
          flash(btn, "Saved ✓", "#2E7D4F");
        }
      }
    );
  }

  // ---- image ads -----------------------------------------------------------

  // Full-size originals, keyed by the path of the 600px preview on the card.
  const originals = new Map();
  function pathOf(u) { try { return new URL(u).pathname; } catch (e) { return ""; } }
  function addPairs(pairs) {
    for (const p of pairs) { const k = pathOf(p.rez); if (k) originals.set(k, p.orig); }
  }
  window.addEventListener("message", (e) => {
    if (e.source !== window || !e.data || !e.data.__snagImages) return;
    addPairs(e.data.__snagImages);
  });

  // The first page of results arrives server-rendered inside a <script>, so
  // read it directly as well as relying on the network hooks.
  function scanScriptsForImages() {
    const dec = (r) => { try { return JSON.parse('"' + r + '"'); } catch (e) { return null; } };
    for (const script of document.querySelectorAll("script")) {
      const t = script.textContent;
      if (!t || !t.includes("original_image_url")) continue;
      const pairs = [];
      for (const m of t.matchAll(/\{[^{}]*"original_image_url":"[^"]+"[^{}]*\}/g)) {
        const o = m[0];
        const orig = dec((o.match(/"original_image_url":"([^"]+)"/) || [])[1] || "");
        const rez = dec((o.match(/"resized_image_url":"([^"]+)"/) || [])[1] || "");
        if (orig && rez) pairs.push({ orig, rez });
      }
      addPairs(pairs);
    }
  }
  scanScriptsForImages();

  // Prefer the full-size original; otherwise the widest size the page offers.
  function bestImageURL(img) {
    const shown = img.currentSrc || img.src || "";
    let original = originals.get(pathOf(shown));
    if (!original) { scanScriptsForImages(); original = originals.get(pathOf(shown)); }
    if (original) return original;
    let best = shown, bestW = 0;
    for (const part of (img.getAttribute("srcset") || "").split(",")) {
      const [u, w] = part.trim().split(/\s+/);
      const width = parseInt(w || "0", 10);
      if (u && width > bestW) { bestW = width; best = u; }
    }
    return best;
  }

  function isAdImage(img) {
    const src = img.currentSrc || img.src || "";
    if (!/fbcdn|scontent/.test(src)) { img.__snagChecked = true; return false; }
    const r = img.getBoundingClientRect();
    if (r.width < 120 || r.height < 120) {
      // A loaded image that renders small is a logo, avatar or icon for good.
      if (img.complete && img.naturalWidth > 0 && r.width > 0) img.__snagChecked = true;
      return false;
    }
    const card = cardOf(img);
    if (!card) return false;
    // On a video ad the still frame is not the asset; the video button covers it.
    if (card.querySelector("video")) return false;
    return true;
  }

  async function saveImage(img, btn) {
    const url = bestImageURL(img);
    if (!url) { flash(btn, "No image found", "#B3403C"); return; }
    flash(btn, "Saving…", null);
    const m = url.split("?")[0].match(/\.(jpe?g|png|webp|gif)$/i);
    const ext = m ? (m[1].toLowerCase() === "jpeg" ? "jpg" : m[1].toLowerCase()) : "jpg";
    const pageURL = adURL(img);
    try {
      // Fetch here, in the page's session, then hand Snag the bytes.
      const res = await fetch(url);
      if (!res.ok) throw new Error("HTTP " + res.status);
      const bytes = new Uint8Array(await res.arrayBuffer());
      let bin = "";
      for (let i = 0; i < bytes.length; i += 0x8000) {
        bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
      }
      const reply = await chrome.runtime.sendMessage({
        type: "save-bytes", dataBase64: btoa(bin), ext,
        name: adName(img, "Ad Library image"), sourceURL: url, pageURL,
      });
      if (!reply || !reply.ok) throw new Error("save-bytes failed");
      flash(btn, reply.duplicate ? "Already saved" : "Saved ✓", "#2E7D4F");
    } catch (e) {
      // Fall back to letting the app download it.
      chrome.runtime.sendMessage({ type: "save-url", url, pageURL }, (resp) => {
        if (chrome.runtime.lastError || !resp || !resp.ok) {
          flash(btn, "Snag not running", "#B3403C");
        } else {
          flash(btn, "Saved ✓", "#2E7D4F");
        }
      });
    }
  }

  // ---- attaching -----------------------------------------------------------

  function hostFor(el) {
    let host = el.parentElement;
    if (host && getComputedStyle(host).display === "inline") host = host.parentElement;
    if (!host) return null;
    if (getComputedStyle(host).position === "static") host.style.position = "relative";
    return host;
  }

  function attachVideo(video) {
    if (video.__snagButton) return;
    const host = hostFor(video);
    if (!host) return;
    const btn = makeButton((b) => saveVideo(video, b));
    host.appendChild(btn);
    video.__snagButton = btn;
  }

  function attachImage(img) {
    if (img.__snagButton || img.__snagChecked) return;
    if (!isAdImage(img)) return;
    const host = hostFor(img);
    if (!host) return;
    const btn = makeButton((b) => saveImage(img, b));
    host.appendChild(btn);
    img.__snagButton = btn;
  }

  function sweep() {
    for (const v of document.querySelectorAll("video")) attachVideo(v);
    for (const i of document.querySelectorAll("img")) attachImage(i);
  }

  // The library mutates constantly while it lazy-loads; batch the sweeps.
  let queued = false;
  function queueSweep() {
    if (queued) return;
    queued = true;
    setTimeout(() => { queued = false; sweep(); }, 250);
  }

  sweep();
  new MutationObserver(queueSweep).observe(document.body, { childList: true, subtree: true });
  addEventListener("scroll", queueSweep, { passive: true, capture: true });
  setInterval(queueSweep, 2000); // images that finish loading after the last mutation
})();
