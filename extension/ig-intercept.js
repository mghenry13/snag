// Runs in the PAGE's world at document_start on Instagram.
// Reels play from blob: URLs; the real mp4 lives in GraphQL/JSON traffic
// (video_url, video_versions[].url, playback_url). Harvest and hand off.
(() => {
  if (window.__snagIgIntercept) return;
  window.__snagIgIntercept = true;

  const seen = new Set();

  function push(list) {
    const fresh = list.filter((u) => u && u.startsWith("http") && !seen.has(u));
    fresh.forEach((u) => seen.add(u));
    if (fresh.length) window.postMessage({ __snagIgVideos: fresh }, "*");
  }

  function harvest(text) {
    if (!text) return;
    if (!text.includes("video_url") && !text.includes("video_versions")
        && !text.includes("playback_url")) return;
    const out = [];
    const decode = (raw) => { try { return JSON.parse('"' + raw + '"'); } catch (e) { return null; } };

    for (const re of [
      /"video_url":"([^"]+)"/g,
      /"playback_url":"([^"]+)"/g,
      /"url":"((?:https:)?\\?\/\\?\/[^"]*?\.mp4[^"]*)"/g,
    ]) {
      let m;
      while ((m = re.exec(text)) !== null) {
        const u = decode(m[1]);
        if (u) out.push(u);
      }
    }
    push(out);
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
