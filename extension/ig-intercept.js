// Runs in the PAGE's world at document_start on Instagram.
// Reels play from blob: URLs, so the real mp4 must come from Instagram's own
// JSON traffic. Every harvested URL is tagged with ITS shortcode — the feed
// preloads neighbouring reels, so an untagged list saves the wrong video.
(() => {
  if (window.__snagIgIntercept) return;
  window.__snagIgIntercept = true;

  const sent = new Set();

  function emit(entries) {
    const fresh = entries.filter((e) => e.url && !sent.has(e.shortcode + e.url));
    fresh.forEach((e) => sent.add(e.shortcode + e.url));
    if (fresh.length) window.postMessage({ __snagIgVideos: fresh }, "*");
  }

  // Best-quality mp4 on a media node.
  function pickURL(node) {
    if (Array.isArray(node.video_versions) && node.video_versions.length) {
      const best = [...node.video_versions].sort(
        (a, b) => (b.width || 0) - (a.width || 0)
      )[0];
      if (best && best.url) return best.url;
    }
    if (typeof node.video_url === "string") return node.video_url;
    if (typeof node.playback_url === "string") return node.playback_url;
    return null;
  }

  // Walk a parsed response, pairing each video with the shortcode it belongs to.
  function walk(node, inheritedCode, out, depth) {
    if (!node || typeof node !== "object" || depth > 12) return;
    if (Array.isArray(node)) {
      for (const child of node) walk(child, inheritedCode, out, depth + 1);
      return;
    }
    const code = node.code || node.shortcode || inheritedCode;
    const url = pickURL(node);
    if (url && code) out.push({ shortcode: code, url });
    else if (url) out.push({ shortcode: "", url });
    for (const key of Object.keys(node)) {
      const v = node[key];
      if (v && typeof v === "object") walk(v, code, out, depth + 1);
    }
  }

  function harvest(text) {
    if (!text) return;
    if (!text.includes("video_versions") && !text.includes("video_url")
        && !text.includes("playback_url")) return;
    const out = [];
    try {
      walk(JSON.parse(text), "", out, 0);
    } catch (e) {
      // Not pure JSON (inline script blob) — fall back to regex, still trying
      // to keep a nearby shortcode with each URL.
      const re = /"code"\s*:\s*"([A-Za-z0-9_-]+)"|"(?:video_url|playback_url)"\s*:\s*"([^"]+)"/g;
      let m, lastCode = "";
      while ((m = re.exec(text)) !== null) {
        if (m[1]) lastCode = m[1];
        else if (m[2]) {
          try { out.push({ shortcode: lastCode, url: JSON.parse('"' + m[2] + '"') }); }
          catch (err) { /* skip */ }
        }
      }
    }
    emit(out.filter((e) => e.url && e.url.startsWith("http")));
  }

  addEventListener("DOMContentLoaded", () => {
    for (const s of document.querySelectorAll("script")) harvest(s.textContent);
  });

  const origFetch = window.fetch;
  window.fetch = async function (...args) {
    const res = await origFetch.apply(this, args);
    try { res.clone().text().then(harvest).catch(() => {}); } catch (e) {}
    return res;
  };

  const origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function (...args) {
    this.addEventListener("load", () => {
      try { if (typeof this.responseText === "string") harvest(this.responseText); } catch (e) {}
    });
    return origSend.apply(this, args);
  };
})();
