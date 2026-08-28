// Runs in the PAGE's world at document_start on the Meta Ad Library.
// Wraps fetch/XHR and harvests video URLs from GraphQL responses, then
// hands them to the isolated content script via postMessage.
(() => {
  if (window.__snagIntercept) return;
  window.__snagIntercept = true;

  const seen = new Set();

  function harvest(text) {
    if (!text || (!text.includes("playable_url") && !text.includes("video_sd_url"))) return;
    const entries = [];

    // Pattern A: ad library snapshots — video_{sd,hd}_url + preview image
    const reA = /"video_sd_url":"([^"]*)","video_hd_url":"([^"]*)"(?:,"[^"]+":"[^"]*")*?,"video_preview_image_url":"([^"]*)"/g;
    let m;
    while ((m = reA.exec(text)) !== null) {
      entries.push({ sd: m[1], hd: m[2], poster: m[3] });
    }
    // Pattern A2: fields in other orders — do a loose pass
    if (entries.length === 0 && text.includes("video_preview_image_url")) {
      const sds = [...text.matchAll(/"video_sd_url":"([^"]*)"/g)].map((x) => x[1]);
      const hds = [...text.matchAll(/"video_hd_url":"([^"]*)"/g)].map((x) => x[1]);
      const posters = [...text.matchAll(/"video_preview_image_url":"([^"]*)"/g)].map((x) => x[1]);
      for (let i = 0; i < Math.max(sds.length, hds.length); i++) {
        entries.push({ sd: sds[i] || "", hd: hds[i] || "", poster: posters[i] || "" });
      }
    }
    // Pattern B: generic playable_url pairs
    const reB = /"playable_url":"([^"]*)"|"playable_url_quality_hd":"([^"]*)"/g;
    let last = null;
    while ((m = reB.exec(text)) !== null) {
      if (m[1]) {
        last = { sd: m[1], hd: "", poster: "" };
        entries.push(last);
      } else if (m[2] && last) {
        last.hd = m[2];
      }
    }

    const decoded = [];
    for (const e of entries) {
      try {
        const video = JSON.parse('"' + (e.hd || e.sd) + '"');
        if (!video || !video.startsWith("http") || seen.has(video)) continue;
        seen.add(video);
        decoded.push({
          video,
          poster: e.poster ? JSON.parse('"' + e.poster + '"') : "",
        });
      } catch (err) { /* skip malformed */ }
    }
    if (decoded.length) {
      window.postMessage({ __snagVideos: decoded }, "*");
    }
  }

  // initial server-rendered scripts
  addEventListener("DOMContentLoaded", () => {
    for (const s of document.querySelectorAll("script")) harvest(s.textContent);
  });

  const origFetch = window.fetch;
  window.fetch = async function (...args) {
    const res = await origFetch.apply(this, args);
    try {
      res.clone().text().then(harvest).catch(() => {});
    } catch (e) { /* opaque */ }
    return res;
  };

  const origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function (...args) {
    this.addEventListener("load", () => {
      try {
        if (typeof this.responseText === "string") harvest(this.responseText);
      } catch (e) { /* non-text */ }
    });
    return origSend.apply(this, args);
  };
})();
